#requires -Version 4.0
# Offline contract tests. No listener, WMI query or permission change is performed.
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$taskModule = Import-Module (Join-Path $PSScriptRoot 'VisualSvnBridge.psm1') -Force -PassThru
& $taskModule {
    # BEGIN OFFLINE TEST BODY
    $script:VsbTestCount = 0
    function Assert-VsbTest {
        param([bool] $Condition, [string] $Name)
        if (-not $Condition) { throw ('TEST_FAILED: ' + $Name) }
        $script:VsbTestCount++
    }
    function Assert-VsbThrows {
        param([scriptblock] $Action, [string] $Code)
        $taskThrown = $false
        try { & $Action | Out-Null } catch { $taskThrown = $_.Exception.Message -ceq $Code }
        Assert-VsbTest $taskThrown ('expected ' + $Code)
    }
    $taskConfig = ConvertFrom-Json '{"enableWrites":false,"repositories":[{"name":"Repo","url":"http://svn.example/Repo","paths":["/project"]}]}'
    Assert-VsbTest ((Resolve-VsbTarget $taskConfig 'http://svn.example/Repo/project').path -ceq '/project') 'exact scope'
    Assert-VsbTest ((Resolve-VsbTarget $taskConfig 'http://SVN.EXAMPLE:80/Repo/project/code/').path -ceq '/project/code') 'origin and trailing slash'
    $taskUnicode = [string][char]0x4e2d + [string][char]0x6587
    Assert-VsbTest ((Resolve-VsbTarget $taskConfig ('http://svn.example/Repo/project/' + $taskUnicode)).path -ceq ('/project/' + $taskUnicode)) 'Unicode path'
    Assert-VsbTest ((Resolve-VsbTarget $taskConfig 'http://svn.example/Repo/project/a%20b').path -ceq '/project/a b') 'space encoded once'
    foreach ($taskUrl in @('http://evil.example/Repo/project', 'http://svn.example/Repository/project', 'http://svn.example/Repo/project-other', 'http://svn.example/Repo/Project', 'https://svn.example/Repo/project')) {
        Assert-VsbThrows { Resolve-VsbTarget $taskConfig $taskUrl } 'REPOSITORY_NOT_ALLOWED'
    }
    foreach ($taskUrl in @('file:///Repo/project', 'http://u:pw@svn.example/Repo/project', 'http://svn.example/Repo/project?x=1', 'http://svn.example/Repo/project#x', 'http://svn.example/Repo/project/../other', 'http://svn.example/Repo/project/%2e%2e/other', 'http://svn.example/Repo/project/a%2fb', 'http://svn.example/Repo/project/a%5cb', 'http://svn.example/Repo/project/%00', 'http://svn.example/Repo/project/%xx', 'http://svn.example/Repo\project')) {
        Assert-VsbThrows { Get-VsbCanonicalURL $taskUrl } 'INVALID_REPOSITORY_URL'
    }
    $taskDuplicate = ConvertFrom-Json '{"repositories":[{"name":"a","url":"http://svn.example/Repo","paths":["/"]},{"name":"b","url":"http://svn.example/Repo/project","paths":["/"]}]}'
    Assert-VsbThrows { Resolve-VsbTarget $taskDuplicate 'http://svn.example/Repo/project/code' } 'REPOSITORY_NOT_ALLOWED'
    Assert-VsbTest (((Get-VsbAncestorPaths '/a/b') -join ',') -ceq '/,/a,/a/b') 'ancestor list flat and complete'
    $taskFakeClass = [pscustomobject]@{ Properties = @{ AccessLevel = [pscustomobject]@{ Qualifiers = @([pscustomobject]@{ Name = 'Values'; Value = @('No Access', 'Read Only', 'Read Write') }) } } }
    Assert-VsbTest ((Get-VsbEnum $taskFakeClass 'AccessLevel' 'No Access') -eq 0) 'enum zero without ValueMap'
    Assert-VsbTest ((Get-VsbEnum $taskFakeClass 'AccessLevel' 'Read Write') -eq 2) 'enum ordinal without ValueMap'
    $taskFakeClass.Properties.AccessLevel.Qualifiers += [pscustomobject]@{ Name = 'ValueMap'; Value = @('2', '5', '9') }
    Assert-VsbTest ((Get-VsbEnum $taskFakeClass 'AccessLevel' 'Read Only') -eq 5) 'enum explicit ValueMap'
    Assert-VsbThrows { Get-VsbEnum $taskFakeClass 'AccessLevel' 'Unknown' } 'WMI_SCHEMA_UNSUPPORTED'
    $taskRules = @([pscustomobject]@{ accountKind = 'user'; accountName = 'alice'; access = 'read' }, [pscustomobject]@{ accountKind = 'group'; accountName = 'team'; access = 'write' })
    $taskChanged = Get-VsbUpdatedRules $taskRules 'user' 'alice' 'write'
    Assert-VsbTest ($taskChanged.Count -eq 2 -and $taskChanged[1].access -ceq 'write' -and $taskChanged[0].accountName -ceq 'team') 'change preserves unrelated rule'
    $taskRemoved = Get-VsbUpdatedRules $taskRules 'user' 'alice' 'removeExplicit'
    Assert-VsbTest ($taskRemoved.Count -eq 1 -and $taskRemoved[0].accountName -ceq 'team') 'remove explicit preserves group'
    $taskEmpty = Get-VsbUpdatedRules @($taskRules[0]) 'user' 'alice' 'removeExplicit'
    Assert-VsbTest ($taskEmpty.Count -eq 0) 'remove last explicit produces empty list'
    Assert-VsbThrows { Get-VsbUpdatedRules $taskRules 'everyone' '*' 'write' } 'INVALID_CHANGE'
    Assert-VsbThrows { Get-VsbUpdatedRules $taskRules 'user' 'absent' 'removeExplicit' } 'NO_EXPLICIT_RULE'
    Assert-VsbThrows { Get-VsbUpdatedRules @($taskRules[0], $taskRules[0]) 'user' 'alice' 'read' } 'DUPLICATE_ACCOUNT_RULE'
    $taskTestToken = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH'
    $taskHash = Get-VsbHash $taskTestToken
    Assert-VsbTest (Test-VsbToken ('Bearer ' + $taskTestToken) $taskHash) 'bearer verification'
    Assert-VsbTest (-not (Test-VsbToken ('Bearer ' + $taskTestToken + 'x') $taskHash)) 'wrong token rejected'
    Assert-VsbTest (-not (Test-VsbToken 'Basic invalid' $taskHash)) 'wrong scheme rejected'
    Assert-VsbTest (-not (Test-VsbToken 'Bearer short' $taskHash)) 'short token rejected'
    Assert-VsbTest ((Get-VsbField ([pscustomobject]@{}) 'enableWrites' $false) -eq $false) 'missing writes disabled'

    # Replace only internal adapters in this module scope with synthetic snapshots.
    function Get-VsbInspection {
        param($Config, [string] $RepositoryURL)
        return $script:VsbFixture
    }
    function Get-VsbReceipt {
        param($State, [string] $OperationId)
        return $script:VsbReceiptFixture
    }
    $script:VsbReceiptFixture = $null
    $script:VsbFixture = [pscustomobject]@{ public = [pscustomobject]@{ writesEnabled = $false; version = 'v1'; repositoryName = 'Repo'; path = '/project'; scopeDescription = 'scope'; accounts = @([pscustomobject]@{ kind = 'user'; name = 'alice' }); rules = @([pscustomobject]@{ accountKind = 'user'; accountName = 'alice'; access = 'read'; isInherited = $false }) } }
    $taskState = @{ config = $taskConfig; reviews = @{} }
    $taskRequest = [pscustomobject]@{ repositoryURL = 'http://svn.example/Repo/project'; accountKind = 'user'; accountName = 'alice'; access = 'write'; expectedVersion = 'v1' }
    Assert-VsbThrows { New-VsbReview $taskState $taskRequest } 'WRITES_DISABLED'
    $script:VsbFixture.public.writesEnabled = $true
    $taskRequest.expectedVersion = 'old'
    Assert-VsbThrows { New-VsbReview $taskState $taskRequest } 'STATE_CHANGED'
    $taskRequest.expectedVersion = 'v1'; $taskRequest.accountName = 'absent'
    Assert-VsbThrows { New-VsbReview $taskState $taskRequest } 'ACCOUNT_NOT_FOUND'
    $taskRequest.accountName = 'alice'
    $taskReview = New-VsbReview $taskState $taskRequest
    Assert-VsbTest ($taskReview.oldAccess -ceq 'read' -and $taskReview.newAccess -ceq 'write' -and $taskReview.version -ceq 'v1' -and $taskState.reviews.Count -eq 1) 'review binds full intent and snapshot'
    Assert-VsbTest ([DateTime]::Parse($taskReview.expiresAt).ToUniversalTime() -gt [DateTime]::UtcNow) 'review expires in future'
    $taskApply = [pscustomobject]@{ operationId = [guid]::NewGuid().ToString(); reviewId = $taskReview.reviewId }
    Assert-VsbThrows { Invoke-VsbApply $taskState $taskApply } 'WRITES_DISABLED'
    $taskState.config.enableWrites = 'false'
    Assert-VsbThrows { Invoke-VsbApply $taskState $taskApply } 'CONFIG_BOOLEAN_REQUIRED'
    $taskState.config.enableWrites = $false
    $script:VsbReceiptFixture = [pscustomobject]@{ status = 'confirmed'; code = 'PERMISSION_SAVED' }
    Assert-VsbTest ((Invoke-VsbApply $taskState $taskApply).status -ceq 'confirmed') 'existing operation queried without replay even if writes disabled'
    $script:VsbReceiptFixture = $null
    $taskState.config.enableWrites = $true; $taskApply.reviewId = [guid]::NewGuid().ToString()
    Assert-VsbThrows { Invoke-VsbApply $taskState $taskApply } 'REVIEW_EXPIRED'
    $taskApply.reviewId = $taskReview.reviewId; $taskState.reviews[$taskReview.reviewId].expiresAt = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
    Assert-VsbThrows { Invoke-VsbApply $taskState $taskApply } 'REVIEW_EXPIRED'
    Write-Output ('Offline bridge checks passed: ' + $script:VsbTestCount + '. No WMI or network operation executed.')
    # END OFFLINE TEST BODY
}
