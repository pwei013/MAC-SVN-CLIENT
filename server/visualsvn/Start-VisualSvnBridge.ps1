#requires -Version 4.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string] $ConfigPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VisualSvnBridge.psm1') -Force
try { Start-VisualSvnPermissionBridge -ConfigPath $ConfigPath }
catch {
    # Never echo an exception containing a configuration path, request, token or WMI object.
    $taskSafeCode = 'BRIDGE_STOPPED'
    if (@('WINDOWS_REQUIRED', 'LOCAL_ABSOLUTE_PATH_REQUIRED', 'PRIVATE_PATH_MISSING', 'PRIVATE_PATH_INVALID', 'PRIVATE_PATH_ACL_TOO_BROAD', 'PRIVATE_PATH_OWNER_INVALID', 'PRIVATE_PATH_PARENT_REPARSE_POINT', 'PRIVATE_PATH_PARENT_OWNER_INVALID', 'PRIVATE_PATH_PARENT_WRITABLE', 'CONFIG_BOOLEAN_REQUIRED', 'TOKEN_HASH_INVALID', 'HTTPS_PREFIX_REQUIRED', 'ALLOWLIST_REQUIRED', 'ALLOWLIST_INVALID', 'BRIDGE_ALREADY_RUNNING') -ccontains $_.Exception.Message) { $taskSafeCode = $_.Exception.Message }
    Write-Output (ConvertTo-Json -Compress -InputObject ([ordered]@{ code = $taskSafeCode; exceptionType = $_.Exception.GetType().FullName; hresult = [Runtime.InteropServices.Marshal]::GetHRForException($_.Exception) }))
    exit 1
}
