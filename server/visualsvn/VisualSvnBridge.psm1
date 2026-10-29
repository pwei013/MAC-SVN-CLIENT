#requires -Version 4.0
# Importing this module never starts a listener or changes VisualSVN.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-VsbField {
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $taskProperty = $Object.PSObject.Properties[$Name]
    if ($null -eq $taskProperty) { return $Default }
    return $taskProperty.Value
}

function Get-VsbHash {
    param([string] $Text)
    $taskHash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($taskHash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $taskHash.Dispose() }
}

function ConvertTo-VsbJson {
    param($Value)
    return ConvertTo-Json -InputObject $Value -Depth 15 -Compress
}

function Get-VsbCanonicalURL {
    param([string] $Value)
    $taskUri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$taskUri)) { throw 'INVALID_REPOSITORY_URL' }
    if (@('http', 'https') -notcontains $taskUri.Scheme -or $taskUri.UserInfo -or $taskUri.Query -or $taskUri.Fragment) { throw 'INVALID_REPOSITORY_URL' }
    # Reject ambiguous separators, dot segments and malformed escapes before URI normalization.
    if ($Value -match '\\|%(?:2f|5c|00)|%(?![0-9a-f]{2})' -or $Value -match '[\x00-\x1f\x7f]') { throw 'INVALID_REPOSITORY_URL' }
    $taskAuthorityEnd = $Value.IndexOf('/', $Value.IndexOf('://') + 3)
    $taskRawPath = '/'
    if ($taskAuthorityEnd -ge 0) { $taskRawPath = $Value.Substring($taskAuthorityEnd) }
    foreach ($taskPart in $taskRawPath.Split('/')) {
        $taskDecoded = [Uri]::UnescapeDataString($taskPart)
        if (@('.', '..') -contains $taskDecoded -or $taskDecoded -match '[\x00-\x1f\x7f\\/]') { throw 'INVALID_REPOSITORY_URL' }
    }
    $taskPath = [Uri]::UnescapeDataString($taskUri.AbsolutePath).TrimEnd('/')
    if (-not $taskPath) { $taskPath = '/' }
    return [pscustomobject]@{ origin = $taskUri.GetLeftPart([UriPartial]::Authority).ToLowerInvariant(); path = $taskPath }
}

function Resolve-VsbTarget {
    param($Config, [string] $RepositoryURL)
    $taskTarget = Get-VsbCanonicalURL $RepositoryURL
    $taskMatches = @()
    foreach ($taskAllowed in @($Config.repositories)) {
        $taskRoot = Get-VsbCanonicalURL ([string]$taskAllowed.url)
        $taskPrefix = $taskRoot.path.TrimEnd('/')
        if ($taskRoot.origin -ceq $taskTarget.origin -and ($taskTarget.path -ceq $taskRoot.path -or $taskTarget.path.StartsWith($taskPrefix + '/', [StringComparison]::Ordinal))) {
            $taskRelative = $taskTarget.path.Substring($taskPrefix.Length)
            if (-not $taskRelative) { $taskRelative = '/' }
            $taskPermitted = $false
            foreach ($taskScope in @($taskAllowed.paths)) {
                $taskScopePrefix = ([string]$taskScope).TrimEnd('/')
                if ($taskRelative -ceq $taskScope -or $taskRelative.StartsWith($taskScopePrefix + '/', [StringComparison]::Ordinal)) { $taskPermitted = $true }
            }
            if ($taskPermitted) { $taskMatches += [pscustomobject]@{ repositoryName = [string]$taskAllowed.name; path = $taskRelative; repositoryURL = $RepositoryURL; rootURL = [string]$taskAllowed.url; expectedUUID = [string](Get-VsbField $taskAllowed 'uuid' '') } }
        }
    }
    if ($taskMatches.Count -ne 1) { throw 'REPOSITORY_NOT_ALLOWED' }
    return $taskMatches[0]
}

function Get-VsbAncestorPaths {
    param([string] $Path)
    $taskResult = @('/')
    $taskCurrent = ''
    foreach ($taskPart in $Path.Trim('/').Split('/')) {
        if (-not $taskPart) { continue }
        $taskCurrent += '/' + $taskPart
        $taskResult += $taskCurrent
    }
    if ($taskResult.Count -gt 64) { throw 'PATH_DEPTH_LIMIT' }
    return $taskResult
}

function Assert-VsbPrivatePath {
    param([string] $Path, [switch] $Directory)
    if (-not (Test-Path -LiteralPath $Path)) { throw 'PRIVATE_PATH_MISSING' }
    $taskItem = Get-Item -LiteralPath $Path -Force
    if (($taskItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $taskItem.PSIsContainer -ne [bool]$Directory) { throw 'PRIVATE_PATH_INVALID' }
    $taskAllowed = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $taskAcl = Get-Acl -LiteralPath $Path
    foreach ($taskRule in $taskAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if (($taskRule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        if ($taskRule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $taskAllowed -notcontains $taskRule.IdentityReference.Value) { throw 'PRIVATE_PATH_ACL_TOO_BROAD' }
    }
    $taskOwner = $taskAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($taskAllowed -notcontains $taskOwner) { throw 'PRIVATE_PATH_OWNER_INVALID' }
    # Existing parent directories cannot be replaceable through a writable parent,
    # a junction, untrusted ownership or DeleteChild / WRITE_DAC / WRITE_OWNER.
    # Ancestor CreateFiles/CreateDirectories alone does not replace an existing child.
    $taskParent = $null
    if ($Directory) { $taskParent = $taskItem.Parent }
    else { $taskParent = $taskItem.Directory }
    $taskDangerous = [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    while ($null -ne $taskParent) {
        if (($taskParent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PRIVATE_PATH_PARENT_REPARSE_POINT' }
        $taskParentAcl = Get-Acl -LiteralPath $taskParent.FullName
        if ($taskAllowed -notcontains $taskParentAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { throw 'PRIVATE_PATH_PARENT_OWNER_INVALID' }
        foreach ($taskRule in $taskParentAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if (($taskRule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
            if ($taskRule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $taskAllowed -notcontains $taskRule.IdentityReference.Value -and ($taskRule.FileSystemRights -band $taskDangerous) -ne 0) { throw 'PRIVATE_PATH_PARENT_WRITABLE' }
        }
        $taskParent = $taskParent.Parent
    }
}

function Write-VsbNewJsonFile {
    param([string] $Path, $Value)
    $taskBytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-VsbJson $Value))
    $taskFileAcl = New-Object Security.AccessControl.FileSecurity
    $taskFileAcl.SetAccessRuleProtection($true, $false)
    $taskOwner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $taskFileAcl.SetOwner($taskOwner)
    foreach ($taskSid in @($taskOwner.Value, 'S-1-5-18', 'S-1-5-32-544')) {
        $taskIdentity = New-Object Security.Principal.SecurityIdentifier($taskSid)
        $taskFileAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($taskIdentity, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)))
    }
    # Set security at creation. Never replace or share an existing receipt.
    $taskStream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough, $taskFileAcl)
    try { $taskStream.Write($taskBytes, 0, $taskBytes.Length); $taskStream.Flush($true) }
    finally { $taskStream.Dispose() }
}

function Get-VsbEnum {
    param($Class, [string] $Property, [string] $Label)
    $taskDeclaration = $Class.Properties[$Property]
    $taskValues = @()
    $taskMap = $null
    # System.Management throws for an absent qualifier; optional ValueMap must
    # be discovered by enumeration. Values without ValueMap use zero-based IDs.
    foreach ($taskQualifier in $taskDeclaration.Qualifiers) {
        if ($taskQualifier.Name -ieq 'Values') { $taskValues = @($taskQualifier.Value) }
        if ($taskQualifier.Name -ieq 'ValueMap') { $taskMap = $taskQualifier }
    }
    for ($taskIndex = 0; $taskIndex -lt $taskValues.Count; $taskIndex++) {
        if ([string]$taskValues[$taskIndex] -ceq $Label) {
            if ($null -ne $taskMap) { return [uint32]$taskMap.Value[$taskIndex] }
            return [uint32]$taskIndex
        }
    }
    throw 'WMI_SCHEMA_UNSUPPORTED'
}

function Get-VsbClass {
    param([string] $Name)
    # Fixed class names only; caller data never enters WQL or executable text.
    return New-Object System.Management.ManagementClass('root\VisualSVN', $Name, $null)
}

function Get-VsbContext {
    param($Config, $Target)
    $taskRepositories = @(Get-WmiObject -Namespace 'root\VisualSVN' -Class 'VisualSVN_Repository' -ErrorAction Stop | Where-Object { [string]$_.Name -ceq $Target.repositoryName })
    if ($taskRepositories.Count -ne 1) { throw 'REPOSITORY_UNAVAILABLE' }
    $taskRepository = $taskRepositories[0]
    if ([string]$taskRepository.UUID -ine $Target.expectedUUID) { throw 'REPOSITORY_IDENTITY_MISMATCH' }
    $taskClass = Get-VsbClass 'VisualSVN_Repository'
    $taskAuthorization = Get-VsbEnum $taskClass 'ActiveAuthorizationSet' 'Subversion'
    if ([uint32]$taskRepository.ActiveAuthorizationSet -ne $taskAuthorization) { throw 'AUTHENTICATION_MODE_UNSUPPORTED' }
    $taskPermissionClass = Get-VsbClass 'VisualSVN_PermissionEntry'
    $taskAccessMap = @{
        none = Get-VsbEnum $taskPermissionClass 'AccessLevel' 'No Access'
        read = Get-VsbEnum $taskPermissionClass 'AccessLevel' 'Read Only'
        write = Get-VsbEnum $taskPermissionClass 'AccessLevel' 'Read Write'
    }
    $taskVersions = @(Get-WmiObject -Namespace 'root\VisualSVN' -Class 'VisualSVN_VersionInfo' -ErrorAction Stop)
    if ($taskVersions.Count -ne 1) { throw 'VERSION_UNAVAILABLE' }
    $taskVersionText = [string]$taskVersions[0].Version
    $taskVersion = $null
    if (-not [version]::TryParse($taskVersionText, [ref]$taskVersion)) { throw 'VERSION_UNSUPPORTED' }
    if ($taskVersion.Major -ne 4 -or $taskVersion.Minor -ne 0 -or $taskVersion.Build -ne 1) { throw 'VERSION_UNSUPPORTED' }
    return [pscustomobject]@{ repository = $taskRepository; authorization = $taskAuthorization; accessMap = $taskAccessMap; serverVersion = $taskVersionText }
}

function ConvertFrom-VsbPermission {
    param($Entry, $Context, [string] $Path, [string] $RequestedPath)
    $taskClass = [string]$Entry.Account.SystemProperties['__CLASS'].Value
    $taskKind = switch -CaseSensitive ($taskClass) {
        'VisualSVN_User' { 'user' }
        'VisualSVN_Group' { 'group' }
        'VisualSVN_Everyone' { 'everyone' }
        default { throw 'ACCOUNT_SCHEMA_UNSUPPORTED' }
    }
    $taskAccess = $null
    foreach ($taskKey in @('none', 'read', 'write')) { if ([uint32]$Entry.AccessLevel -eq $Context.accessMap[$taskKey]) { $taskAccess = $taskKey } }
    if ($null -eq $taskAccess) { throw 'ACCESS_LEVEL_UNSUPPORTED' }
    return [pscustomobject]@{ accountKind = $taskKind; accountName = [string]$Entry.Account.Name; access = $taskAccess; sourcePath = $Path; isInherited = ($Path -cne $RequestedPath) }
}

function Read-VsbSecurity {
    param($Context, [string] $Path)
    $taskInput = $Context.repository.GetMethodParameters('GetSecurity')
    $taskInput['AuthorizationSet'] = [uint32]$Context.authorization
    $taskInput['Path'] = $Path
    $taskOutput = $Context.repository.InvokeMethod('GetSecurity', $taskInput, $null)
    if ($null -eq $taskOutput -or -not [bool]$taskOutput['ReturnValue']) { throw 'SECURITY_READ_FAILED' }
    if ($null -eq $taskOutput['Permissions']) { return }
    return $taskOutput['Permissions']
}

function Get-VsbInspection {
    param($Config, [string] $RepositoryURL)
    $taskTarget = Resolve-VsbTarget $Config $RepositoryURL
    $taskContext = Get-VsbContext $Config $taskTarget
    $taskRules = @()
    $taskCurrentEntries = @()
    foreach ($taskPath in @(Get-VsbAncestorPaths $taskTarget.path)) {
        $taskEntries = @(Read-VsbSecurity $taskContext $taskPath)
        if ($taskPath -ceq $taskTarget.path) { $taskCurrentEntries = $taskEntries }
        foreach ($taskEntry in $taskEntries) { $taskRules += ConvertFrom-VsbPermission $taskEntry $taskContext $taskPath $taskTarget.path }
    }
    $taskAccounts = @()
    foreach ($taskKind in @('user', 'group')) {
        $taskClassName = 'VisualSVN_User'
        if ($taskKind -ceq 'group') { $taskClassName = 'VisualSVN_Group' }
        foreach ($taskAccount in @(Get-WmiObject -Namespace 'root\VisualSVN' -Class $taskClassName -ErrorAction Stop)) {
            $taskAccounts += [pscustomobject]@{ kind = $taskKind; name = [string]$taskAccount.Name }
        }
    }
    if ($taskAccounts.Count -gt 5000 -or $taskRules.Count -gt 10000) { throw 'RESULT_LIMIT' }
    $taskAccounts = @($taskAccounts | Sort-Object kind, name -CaseSensitive)
    $taskRules = @($taskRules | Sort-Object sourcePath, accountKind, accountName -CaseSensitive)
    # Fingerprint the complete ancestor/target ACL and account identities, not just the edited account.
    $taskVersion = Get-VsbHash (ConvertTo-VsbJson ([ordered]@{ repository = $taskTarget.repositoryName; uuid = [string]$taskContext.repository.UUID; path = $taskTarget.path; rules = $taskRules; accounts = $taskAccounts; authorization = $taskContext.authorization }))
    $taskEnabled = (Get-VsbField $Config 'enableWrites' $false)
    if ($taskEnabled -isnot [bool]) { throw 'CONFIG_BOOLEAN_REQUIRED' }
    $taskReason = $null
    if (-not $taskEnabled) { $taskReason = 'LEGACY_ADAPTER_REQUIRES_SERVER_VALIDATION' }
    return [pscustomobject]@{
        public = [ordered]@{ schemaVersion = 1; repositoryURL = $RepositoryURL; repositoryName = $taskTarget.repositoryName; path = $taskTarget.path; serverVersion = $taskContext.serverVersion; version = $taskVersion; writesEnabled = $taskEnabled; writeDisabledReason = $taskReason; accounts = $taskAccounts; rules = $taskRules; scopeDescription = 'This path and descendants; descendant explicit rules are preserved. Group and Everyone rules may also grant access.' }
        target = $taskTarget; context = $taskContext; currentEntries = $taskCurrentEntries
    }
}

function Get-VsbUpdatedRules {
    param($Rules, [string] $Kind, [string] $Name, [string] $Access)
    if (@('user', 'group') -cnotcontains $Kind -or @('none', 'read', 'write', 'removeExplicit') -cnotcontains $Access -or [string]::IsNullOrWhiteSpace($Name)) { throw 'INVALID_CHANGE' }
    $taskResult = @()
    $taskFound = 0
    foreach ($taskRule in @($Rules)) {
        if ($taskRule.accountKind -ceq $Kind -and $taskRule.accountName -ceq $Name) { $taskFound++; continue }
        $taskResult += $taskRule
    }
    if ($taskFound -gt 1) { throw 'DUPLICATE_ACCOUNT_RULE' }
    if ($Access -ceq 'removeExplicit' -and $taskFound -eq 0) { throw 'NO_EXPLICIT_RULE' }
    if ($Access -cne 'removeExplicit') { $taskResult += [pscustomobject]@{ accountKind = $Kind; accountName = $Name; access = $Access } }
    return ,@($taskResult | Sort-Object accountKind, accountName -CaseSensitive)
}

function New-VsbReview {
    param($State, $Request)
    $taskInspection = Get-VsbInspection $State.config ([string]$Request.repositoryURL)
    if (-not $taskInspection.public.writesEnabled) { throw 'WRITES_DISABLED' }
    if ([string]$Request.expectedVersion -cne $taskInspection.public.version) { throw 'STATE_CHANGED' }
    $taskKind = [string]$Request.accountKind
    $taskName = [string]$Request.accountName
    $taskAccess = [string]$Request.access
    $taskAccounts = @($taskInspection.public.accounts | Where-Object { $_.kind -ceq $taskKind -and $_.name -ceq $taskName })
    if ($taskAccounts.Count -ne 1) { throw 'ACCOUNT_NOT_FOUND' }
    $taskCurrentRules = @($taskInspection.public.rules | Where-Object { -not $_.isInherited })
    $null = Get-VsbUpdatedRules $taskCurrentRules $taskKind $taskName $taskAccess
    $taskOld = @($taskCurrentRules | Where-Object { $_.accountKind -ceq $taskKind -and $_.accountName -ceq $taskName })
    $taskOldAccess = $null
    if ($taskOld.Count -eq 1) { $taskOldAccess = $taskOld[0].access }
    $taskReview = [ordered]@{ schemaVersion = 1; reviewId = [guid]::NewGuid().ToString(); expiresAt = [DateTime]::UtcNow.AddMinutes(5).ToString('o'); repositoryURL = [string]$Request.repositoryURL; repositoryName = $taskInspection.public.repositoryName; path = $taskInspection.public.path; accountKind = $taskKind; accountName = $taskName; oldAccess = $taskOldAccess; newAccess = $taskAccess; scopeDescription = $taskInspection.public.scopeDescription; version = $taskInspection.public.version }
    foreach ($taskKey in @($State.reviews.Keys)) { if ([DateTime]::Parse($State.reviews[$taskKey].expiresAt).ToUniversalTime() -lt [DateTime]::UtcNow) { $State.reviews.Remove($taskKey) } }
    if ($State.reviews.Count -ge 200) { throw 'REVIEW_LIMIT' }
    $State.reviews[$taskReview.reviewId] = $taskReview
    return $taskReview
}

function Get-VsbReceipt {
    param($State, [string] $OperationId)
    $taskGuid = [guid]::Empty
    if (-not [guid]::TryParseExact($OperationId, 'D', [ref]$taskGuid)) { throw 'INVALID_OPERATION_ID' }
    $taskId = $taskGuid.ToString()
    $taskStarted = Join-Path $State.dataDirectory ($taskId + '.pending.json')
    $taskCompleted = Join-Path $State.dataDirectory ($taskId + '.result.json')
    if (Test-Path -LiteralPath $taskCompleted) { Assert-VsbPrivatePath $taskCompleted; return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($taskCompleted)) }
    if (Test-Path -LiteralPath $taskStarted) { Assert-VsbPrivatePath $taskStarted; return [ordered]@{ schemaVersion = 1; operationId = $taskId; status = 'pending'; code = 'VERIFY_SERVER_STATE' } }
    return $null
}

function Invoke-VsbApply {
    param($State, $Request)
    $taskOperationId = [string]$Request.operationId
    $taskExisting = Get-VsbReceipt $State $taskOperationId
    if ($null -ne $taskExisting) { return $taskExisting }
    $taskEnabled = Get-VsbField $State.config 'enableWrites' $false
    if ($taskEnabled -isnot [bool]) { throw 'CONFIG_BOOLEAN_REQUIRED' }
    if (-not $taskEnabled) { throw 'WRITES_DISABLED' }
    $taskReviewId = [string]$Request.reviewId
    if (-not $State.reviews.ContainsKey($taskReviewId)) { throw 'REVIEW_EXPIRED' }
    $taskReview = $State.reviews[$taskReviewId]
    if ([DateTime]::Parse($taskReview.expiresAt).ToUniversalTime() -lt [DateTime]::UtcNow) { $State.reviews.Remove($taskReviewId); throw 'REVIEW_EXPIRED' }
    $taskOperationId = ([guid]$taskOperationId).ToString()
    # Reserve the review before writing: one prepared review can never authorize two writes.
    $taskReviewFile = Join-Path $State.dataDirectory ($taskReviewId + '.review-used.json')
    Write-VsbNewJsonFile $taskReviewFile ([ordered]@{ reviewId = $taskReviewId; operationId = $taskOperationId })
    $taskPendingPath = Join-Path $State.dataDirectory ($taskOperationId + '.pending.json')
    Write-VsbNewJsonFile $taskPendingPath ([ordered]@{ schemaVersion = 1; operationId = $taskOperationId; review = $taskReview; status = 'pending'; startedAt = [DateTime]::UtcNow.ToString('o') })
    $State.reviews.Remove($taskReviewId)
    $taskResult = [ordered]@{ schemaVersion = 1; operationId = $taskOperationId; status = 'rejected'; code = 'STATE_CHANGED' }
    $taskWriteStarted = $false
    try {
        $taskBefore = Get-VsbInspection $State.config $taskReview.repositoryURL
        if ($taskBefore.public.version -cne $taskReview.version) { throw 'STATE_CHANGED' }
        $taskExpectedRules = Get-VsbUpdatedRules @($taskBefore.public.rules | Where-Object { -not $_.isInherited }) $taskReview.accountKind $taskReview.accountName $taskReview.newAccess
        $taskPermissions = @()
        foreach ($taskEntry in @($taskBefore.currentEntries)) {
            $taskRule = ConvertFrom-VsbPermission $taskEntry $taskBefore.context $taskBefore.target.path $taskBefore.target.path
            if ($taskRule.accountKind -ceq $taskReview.accountKind -and $taskRule.accountName -ceq $taskReview.accountName) { continue }
            # Keep the original embedded instances and every unrelated permission.
            $taskPermissions += $taskEntry
        }
        if ($taskReview.newAccess -cne 'removeExplicit') {
            $taskAccountClass = 'VisualSVN_User'
            if ($taskReview.accountKind -ceq 'group') { $taskAccountClass = 'VisualSVN_Group' }
            $taskAccount = (Get-VsbClass $taskAccountClass).CreateInstance()
            $taskAccount['Name'] = $taskReview.accountName
            $taskEntry = (Get-VsbClass 'VisualSVN_PermissionEntry').CreateInstance()
            $taskEntry['Account'] = $taskAccount
            $taskEntry['AccessLevel'] = [uint32]$taskBefore.context.accessMap[$taskReview.newAccess]
            $taskPermissions += $taskEntry
        }
        $taskInput = $taskBefore.context.repository.GetMethodParameters('SetSecurity')
        $taskInput['AuthorizationSet'] = [uint32]$taskBefore.context.authorization
        $taskInput['Path'] = $taskBefore.target.path
        $taskInput['Permissions'] = [System.Management.ManagementBaseObject[]]$taskPermissions
        $taskInput['ResetChildren'] = $false
        $taskWriteStarted = $true
        $taskOutput = $taskBefore.context.repository.InvokeMethod('SetSecurity', $taskInput, $null)
        if ($null -eq $taskOutput -or -not [bool]$taskOutput['ReturnValue']) { throw 'WMI_WRITE_NOT_CONFIRMED' }
        # Fresh WMI query after mutation. A successful method return alone is insufficient.
        $taskAfter = Get-VsbInspection $State.config $taskReview.repositoryURL
        $taskActual = @($taskAfter.public.rules | Where-Object { -not $_.isInherited } | ForEach-Object { [pscustomobject]@{ accountKind = $_.accountKind; accountName = $_.accountName; access = $_.access } } | Sort-Object accountKind, accountName -CaseSensitive)
        $taskExpected = @($taskExpectedRules | ForEach-Object { [pscustomobject]@{ accountKind = $_.accountKind; accountName = $_.accountName; access = $_.access } })
        if ((ConvertTo-VsbJson $taskActual) -cne (ConvertTo-VsbJson $taskExpected)) { throw 'READBACK_MISMATCH' }
        $taskResult.status = 'confirmed'; $taskResult.code = 'PERMISSION_SAVED'
    } catch {
        if ($taskWriteStarted) { $taskResult.status = 'unknown'; $taskResult.code = 'VERIFY_SERVER_STATE' }
        else { $taskResult.status = 'rejected'; $taskResult.code = 'STATE_CHANGED' }
    }
    # If receipt persistence fails, leave the durable pending file and never replay.
    Write-VsbNewJsonFile (Join-Path $State.dataDirectory ($taskOperationId + '.result.json')) $taskResult
    return $taskResult
}

function Read-VsbRequest {
    param($Request)
    if ($Request.ContentLength64 -le 0 -or $Request.ContentLength64 -gt 65536 -or $Request.Headers['Transfer-Encoding']) { throw 'REQUEST_SIZE_INVALID' }
    if (-not $Request.ContentType -or -not $Request.ContentType.StartsWith('application/json', [StringComparison]::OrdinalIgnoreCase)) { throw 'JSON_REQUIRED' }
    $taskBuffer = New-Object byte[] 4096
    $taskStream = New-Object IO.MemoryStream
    $taskDeadline = [DateTime]::UtcNow.AddSeconds(10)
    try {
        while ($taskStream.Length -lt $Request.ContentLength64) {
            $taskRemaining = [int]($taskDeadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($taskRemaining -le 0) { throw 'REQUEST_TIMEOUT' }
            $taskRead = $Request.InputStream.ReadAsync($taskBuffer, 0, [int][Math]::Min(4096, $Request.ContentLength64 - $taskStream.Length))
            if (-not $taskRead.Wait($taskRemaining)) { throw 'REQUEST_TIMEOUT' }
            $taskCount = $taskRead.Result
            if ($taskCount -eq 0) { throw 'REQUEST_INCOMPLETE' }
            $taskStream.Write($taskBuffer, 0, $taskCount)
        }
        $taskText = (New-Object Text.UTF8Encoding($false, $true)).GetString($taskStream.ToArray())
        $taskObject = ConvertFrom-Json -InputObject $taskText
        if ($null -eq $taskObject -or $taskObject -is [array] -or $taskObject -is [string] -or $taskObject -is [ValueType]) { throw 'REQUEST_INVALID' }
        return $taskObject
    } finally { $taskStream.Dispose() }
}

function Test-VsbToken {
    param([string] $Authorization, [string] $ExpectedHash)
    if (-not $Authorization.StartsWith('Bearer ', [StringComparison]::Ordinal)) { return $false }
    $taskToken = $Authorization.Substring(7)
    if ($taskToken -cnotmatch '^[A-Za-z0-9+/=_-]{43,256}$') { return $false }
    $taskActual = Get-VsbHash $taskToken
    $taskDifference = 0
    for ($taskIndex = 0; $taskIndex -lt 64; $taskIndex++) { $taskDifference = $taskDifference -bor ([int][char]$taskActual[$taskIndex] -bxor [int][char]$ExpectedHash[$taskIndex]) }
    return $taskDifference -eq 0
}

function Send-VsbResponse {
    param($Context, [int] $StatusCode, $Value)
    $taskBytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-VsbJson $Value))
    if ($taskBytes.Length -gt 2097152) { $StatusCode = 413; $taskBytes = [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"code":"RESULT_LIMIT"}') }
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    $Context.Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Context.Response.ContentLength64 = $taskBytes.Length
    $Context.Response.KeepAlive = $false
    try {
        $taskWrite = $Context.Response.OutputStream.WriteAsync($taskBytes, 0, $taskBytes.Length)
        if (-not $taskWrite.Wait(10000)) { throw 'RESPONSE_TIMEOUT' }
        $taskWrite.GetAwaiter().GetResult()
    }
    finally { $Context.Response.Close() }
}

function Start-VisualSvnPermissionBridge {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $ConfigPath)
    if ($env:OS -ne 'Windows_NT') { throw 'WINDOWS_REQUIRED' }
    if ($ConfigPath -notmatch '^[A-Za-z]:\\') { throw 'LOCAL_ABSOLUTE_PATH_REQUIRED' }
    Assert-VsbPrivatePath $ConfigPath
    $taskConfig = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($ConfigPath))
    $taskEnableWrites = Get-VsbField $taskConfig 'enableWrites' $false
    if ($taskEnableWrites -isnot [bool]) { throw 'CONFIG_BOOLEAN_REQUIRED' }
    if ($taskConfig.tokenSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'TOKEN_HASH_INVALID' }
    $taskPrefix = [Uri]$taskConfig.listenPrefix
    if ($taskPrefix.Scheme -cne 'https' -or $taskPrefix.UserInfo -or $taskPrefix.Query -or $taskPrefix.Fragment -or $taskPrefix.AbsolutePath -cne '/' -or $taskPrefix.Host -match '[*+]') { throw 'HTTPS_PREFIX_REQUIRED' }
    if ($taskConfig.allowedClientAddresses -isnot [array] -or $taskConfig.repositories -isnot [array] -or @($taskConfig.allowedClientAddresses).Count -eq 0 -or @($taskConfig.repositories).Count -eq 0) { throw 'ALLOWLIST_REQUIRED' }
    foreach ($taskAddress in @($taskConfig.allowedClientAddresses)) { $null = [Net.IPAddress]::Parse([string]$taskAddress) }
    foreach ($taskRepository in @($taskConfig.repositories)) {
        $null = Get-VsbCanonicalURL ([string]$taskRepository.url)
        if ([string]::IsNullOrWhiteSpace([string]$taskRepository.name) -or $taskRepository.paths -isnot [array] -or @($taskRepository.paths).Count -eq 0) { throw 'ALLOWLIST_INVALID' }
        $taskRepositoryUUID = [guid]::Empty
        if (-not [guid]::TryParseExact([string](Get-VsbField $taskRepository 'uuid' ''), 'D', [ref]$taskRepositoryUUID)) { throw 'ALLOWLIST_INVALID' }
        foreach ($taskPath in @($taskRepository.paths)) {
            if ([string]$taskPath -notmatch '^/' -or [string]$taskPath -match '\\|//|(^|/)\.\.?(/|$)|[\x00-\x1f\x7f]' -or ([string]$taskPath).TrimEnd('/') -cne [string]$taskPath -and [string]$taskPath -cne '/') { throw 'ALLOWLIST_INVALID' }
        }
    }
    if ([string]$taskConfig.dataDirectory -notmatch '^[A-Za-z]:\\') { throw 'LOCAL_ABSOLUTE_PATH_REQUIRED' }
    $taskDataDirectory = [IO.Path]::GetFullPath([string]$taskConfig.dataDirectory)
    Assert-VsbPrivatePath $taskDataDirectory -Directory
    $taskMutex = New-Object Threading.Mutex($false, ('Global\SVNManagerPermissions-' + (Get-VsbHash ($taskDataDirectory.ToLowerInvariant()))))
    $taskOwnsMutex = $false
    $taskListener = New-Object Net.HttpListener
    try {
        try { $taskOwnsMutex = $taskMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $taskOwnsMutex = $true }
        if (-not $taskOwnsMutex) { throw 'BRIDGE_ALREADY_RUNNING' }
        $taskState = @{ config = $taskConfig; dataDirectory = $taskDataDirectory; reviews = @{} }
        $taskListener.Prefixes.Add($taskPrefix.AbsoluteUri)
        $taskListener.Start()
        Write-Output 'SVN permission bridge listening. No secrets or request bodies are logged. Stop with Ctrl+C.'
        while ($taskListener.IsListening) {
            $taskContext = $taskListener.GetContext()
            try {
                $taskRequest = $taskContext.Request
                if (-not $taskRequest.IsSecureConnection -or $taskRequest.HttpMethod -cne 'POST' -or $taskRequest.Url.Query -or $taskRequest.Headers['Origin']) { throw 'REQUEST_NOT_ALLOWED' }
                if (@($taskConfig.allowedClientAddresses) -cnotcontains $taskRequest.RemoteEndPoint.Address.ToString()) { throw 'CLIENT_NOT_ALLOWED' }
                if (-not (Test-VsbToken ([string]$taskRequest.Headers['Authorization']) ([string]$taskConfig.tokenSha256))) { throw 'AUTHENTICATION_REQUIRED' }
                $taskRequestObject = Read-VsbRequest $taskRequest
                $taskResponse = switch -CaseSensitive ($taskRequest.Url.AbsolutePath) {
                    '/v1/inspect' { (Get-VsbInspection $taskConfig ([string]$taskRequestObject.repositoryURL)).public; break }
                    '/v1/prepare' { New-VsbReview $taskState $taskRequestObject; break }
                    '/v1/apply' { Invoke-VsbApply $taskState $taskRequestObject; break }
                    '/v1/status' { $taskReceipt = Get-VsbReceipt $taskState ([string]$taskRequestObject.operationId); if ($null -eq $taskReceipt) { throw 'OPERATION_NOT_FOUND' }; $taskReceipt; break }
                    default { throw 'ENDPOINT_NOT_FOUND' }
                }
                Send-VsbResponse $taskContext 200 $taskResponse
            } catch {
                $taskCode = 'SERVER_OPERATION_FAILED'
                $taskKnownCodes = @('INVALID_REPOSITORY_URL', 'REPOSITORY_NOT_ALLOWED', 'PATH_DEPTH_LIMIT', 'REPOSITORY_UNAVAILABLE', 'REPOSITORY_IDENTITY_MISMATCH', 'AUTHENTICATION_MODE_UNSUPPORTED', 'VERSION_UNAVAILABLE', 'VERSION_UNSUPPORTED', 'WMI_SCHEMA_UNSUPPORTED', 'SECURITY_READ_FAILED', 'ACCOUNT_SCHEMA_UNSUPPORTED', 'ACCESS_LEVEL_UNSUPPORTED', 'RESULT_LIMIT', 'WRITES_DISABLED', 'STATE_CHANGED', 'INVALID_CHANGE', 'ACCOUNT_NOT_FOUND', 'NO_EXPLICIT_RULE', 'DUPLICATE_ACCOUNT_RULE', 'REVIEW_LIMIT', 'INVALID_OPERATION_ID', 'REVIEW_EXPIRED', 'REQUEST_SIZE_INVALID', 'JSON_REQUIRED', 'REQUEST_TIMEOUT', 'REQUEST_INCOMPLETE', 'REQUEST_INVALID', 'REQUEST_NOT_ALLOWED', 'CLIENT_NOT_ALLOWED', 'AUTHENTICATION_REQUIRED', 'OPERATION_NOT_FOUND', 'ENDPOINT_NOT_FOUND')
                if ($taskKnownCodes -ccontains $_.Exception.Message) { $taskCode = $_.Exception.Message }
                $taskStatus = 400
                if (@('WRITES_DISABLED', 'REPOSITORY_NOT_ALLOWED', 'CLIENT_NOT_ALLOWED') -ccontains $taskCode) { $taskStatus = 403 }
                if ($taskCode -ceq 'AUTHENTICATION_REQUIRED') { $taskStatus = 401 }
                if (@('OPERATION_NOT_FOUND', 'ENDPOINT_NOT_FOUND') -ccontains $taskCode) { $taskStatus = 404 }
                if (@('STATE_CHANGED', 'REVIEW_EXPIRED') -ccontains $taskCode) { $taskStatus = 409 }
                if ($taskCode -ceq 'SERVER_OPERATION_FAILED') { $taskStatus = 500 }
                $taskErrorBody = [ordered]@{ schemaVersion = 1; code = $taskCode }
                if ($taskCode -ceq 'SERVER_OPERATION_FAILED') {
                    $taskErrorBody.diagnostic = [ordered]@{ exceptionType = $_.Exception.GetType().FullName; hresult = [Runtime.InteropServices.Marshal]::GetHRForException($_.Exception) }
                }
                try { Send-VsbResponse $taskContext $taskStatus $taskErrorBody } catch { $taskContext.Response.Abort() }
            }
        }
    } finally {
        $taskListener.Close()
        if ($taskOwnsMutex) { $taskMutex.ReleaseMutex() }
        $taskMutex.Dispose()
    }
}

Export-ModuleMember -Function Start-VisualSvnPermissionBridge
