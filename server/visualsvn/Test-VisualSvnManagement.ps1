#requires -Version 3.0
<#
Read-only compatibility probe. Run on the VisualSVN Windows server from its
VisualSVN Server PowerShell console. It reads product/command/class metadata
only; it never reads user instances, passwords or repository access rules.
The optional JSON report is the only file this script creates.
#>
[CmdletBinding()]
param(
    [string] $OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$taskReport = [ordered]@{
    schemaVersion = 1
    readOnly = $true
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    osVersion = [Environment]::OSVersion.Version.ToString()
    products = @()
    commands = @()
    classes = @()
    diagnostics = @()
    truncated = $false
}

function Add-ProbeDiagnostic {
    param([string] $Code, [System.Exception] $Exception)
    $taskReport.diagnostics += [ordered]@{
        code = $Code
        exceptionType = $Exception.GetType().FullName
        hresult = [Runtime.InteropServices.Marshal]::GetHRForException($Exception)
    }
}

function Read-ProbeQualifiers {
    param($Qualifiers)
    $taskValues = [ordered]@{}
    foreach ($taskQualifier in $Qualifiers) {
        if (@('In', 'Out', 'Static', 'EmbeddedInstance', 'Key', 'Read', 'Write', 'Required', 'Values', 'ValueMap', 'BitValues', 'BitMap') -contains $taskQualifier.Name) {
            $taskQualifierValues = @()
            foreach ($taskValue in @($taskQualifier.Value)) { $taskQualifierValues += [string]$taskValue }
            $taskValues[$taskQualifier.Name] = $taskQualifierValues
        }
    }
    return $taskValues
}

function Read-ProbeReference {
    param($Declaration)
    $taskReference = $Declaration.PSObject.Properties['ReferenceClassName']
    if ($null -ne $taskReference) { return [string]$taskReference.Value }
    return $null
}

if ($env:OS -ne 'Windows_NT') {
    $taskReport.diagnostics += [ordered]@{ code = 'WINDOWS_REQUIRED' }
} else {
    # Read only version/display-name metadata from the installed-product registry.
    foreach ($taskRegistry in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        try {
            if (Test-Path -LiteralPath $taskRegistry) {
                foreach ($taskProduct in @(Get-ChildItem -LiteralPath $taskRegistry -ErrorAction Stop)) {
                    $taskProductName = [string]$taskProduct.GetValue('DisplayName')
                    if ($taskProductName -match '^VisualSVN Server(?:\s|$)') {
                        $taskReport.products += [ordered]@{
                            name = $taskProductName
                            version = [string]$taskProduct.GetValue('DisplayVersion')
                        }
                    }
                }
            }
        } catch { Add-ProbeDiagnostic 'PRODUCT_METADATA_UNAVAILABLE' $_.Exception }
    }

    # Discover parameter declarations; no VisualSVN cmdlet is invoked.
    foreach ($taskName in @(
        'Get-SvnRepository', 'Get-SvnAccessRule', 'Select-SvnAccessRule',
        'Add-SvnAccessRule', 'Set-SvnAccessRule', 'Remove-SvnAccessRule',
        'Get-SvnLocalUser', 'Get-SvnLocalGroup', 'Get-SvnEffectiveAccess'
    )) {
        try {
            $taskCommand = @(Get-Command -Name $taskName -CommandType Cmdlet,Function -ErrorAction SilentlyContinue)
            if ($taskCommand.Count -eq 0) {
                $taskReport.commands += [ordered]@{ name = $taskName; available = $false; parameters = @() }
                continue
            }
            $taskReport.commands += [ordered]@{
                name = $taskName
                available = $true
                module = [string]$taskCommand[0].ModuleName
                parameters = @($taskCommand[0].Parameters.Keys | Sort-Object)
            }
        } catch { Add-ProbeDiagnostic 'COMMAND_METADATA_UNAVAILABLE' $_.Exception }
    }

    # Get-CimClass reads class declarations, not object instances. Query locally
    # through COM; no WinRM/SSH listener or remote session is enabled or created.
    try {
        $taskClasses = @(Get-CimClass -Namespace 'root/VisualSVN' -ClassName 'VisualSVN_*' -OperationTimeoutSec 20)
        if ($taskClasses.Count -gt 200) { $taskReport.truncated = $true }
        foreach ($taskClass in @($taskClasses | Sort-Object { $_.CimSystemProperties.ClassName } | Select-Object -First 200)) {
            $taskProperties = @()
            $taskMethods = @()
            foreach ($taskProperty in $taskClass.CimClassProperties) {
                $taskProperties += [ordered]@{
                    name = $taskProperty.Name
                    type = $taskProperty.CimType.ToString()
                    referenceClass = Read-ProbeReference $taskProperty
                    qualifiers = Read-ProbeQualifiers $taskProperty.Qualifiers
                }
            }
            foreach ($taskMethod in $taskClass.CimClassMethods) {
                $taskParameters = @()
                foreach ($taskParameter in $taskMethod.Parameters) {
                    $taskParameters += [ordered]@{
                        name = $taskParameter.Name
                        type = $taskParameter.CimType.ToString()
                        referenceClass = Read-ProbeReference $taskParameter
                        qualifiers = Read-ProbeQualifiers $taskParameter.Qualifiers
                    }
                }
                $taskMethods += [ordered]@{
                    name = $taskMethod.Name
                    returnType = $taskMethod.ReturnType.ToString()
                    parameters = $taskParameters
                    qualifiers = Read-ProbeQualifiers $taskMethod.Qualifiers
                }
            }
            $taskReport.classes += [ordered]@{
                name = $taskClass.CimSystemProperties.ClassName
                properties = $taskProperties
                methods = $taskMethods
                qualifiers = Read-ProbeQualifiers $taskClass.CimClassQualifiers
            }
        }
        if ($taskClasses.Count -eq 0) {
            $taskReport.diagnostics += [ordered]@{ code = 'NO_VISUALSVN_CLASS_METADATA' }
        }
    } catch { Add-ProbeDiagnostic 'CLASS_METADATA_UNAVAILABLE' $_.Exception }
}

$taskJson = ConvertTo-Json -InputObject $taskReport -Depth 12
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    # Never overwrite a pre-existing report or follow a file link at that path.
    $taskOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $taskBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($taskJson)
    $taskStream = $null
    try {
        $taskStream = [IO.File]::Open($taskOutput, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $taskStream.Write($taskBytes, 0, $taskBytes.Length)
        $taskStream.Flush()
    } catch {
        throw 'REPORT_WRITE_FAILED: Choose a new JSON file in an existing writable folder.'
    } finally {
        if ($null -ne $taskStream) { $taskStream.Dispose() }
    }
}
Write-Output $taskJson
