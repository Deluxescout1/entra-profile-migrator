<#
    NinjaOne-Run-Migration.ps1
    Runs EntraProfileMigrator under SYSTEM via a NinjaOne script policy.

    Deploy the module folder (src\EntraProfileMigrator) alongside this script, or have this script
    pull it from your software repo/share. Set parameters via NinjaOne script variables or the
    environment, then alert on any exit code >= 40.

    Run NinjaOne-Discover-Profiles.ps1 first to identify the correct TargetUpn and SourceSid
    for this device, then supply them here.

    NinjaOne environment variables:
      MigrationTargetUpn  — required: the Entra UPN to migrate to (e.g. jsmith@contoso.com)
      MigrationSourceSid  — optional: domain SID to migrate from (required on multi-profile devices)
      MigrationMode       — optional: inplace (default) or copy
      MigrationExecute    — optional: true to actually run; omit for a dry run

    Exit codes (mirrors module): 0 ok | 10 dry-run | 20 prereq | 30 no source | 40 no target SID
                                 | 50 error(rolled back) | 60 error(manual rollback)
#>
[CmdletBinding()]
param(
    [string]$TargetUpn  = $env:MigrationTargetUpn,
    [string]$SourceSid  = $env:MigrationSourceSid,
    [ValidateSet('inplace','copy')][string]$Mode = 'inplace',
    [switch]$Execute,
    [string]$ModulePath = (Join-Path $PSScriptRoot '..\src\EntraProfileMigrator\EntraProfileMigrator.psd1')
)

$ErrorActionPreference = 'Stop'

# Pull overrides from NinjaOne env vars (5.1-safe, no ternary).
if ($env:MigrationMode)    { $Mode = $env:MigrationMode }
if ($env:MigrationExecute -and [System.Convert]::ToBoolean($env:MigrationExecute)) { $Execute = $true }

if (-not $TargetUpn) { Write-Error 'TargetUpn not supplied (set MigrationTargetUpn).'; exit 20 }

try {
    Import-Module $ModulePath -Force
} catch {
    Write-Error "Failed to import module from $ModulePath : $_"; exit 20
}

$invokeParams = @{
    TargetUpn = $TargetUpn
    Mode      = $Mode
    Execute   = $Execute
}
if ($SourceSid) { $invokeParams['SourceSid'] = $SourceSid }

$res = Invoke-ProfileMigration @invokeParams

Write-Output $res.Message
# Optional: write status back to a NinjaOne custom field here, e.g.:
# Ninja-Property-Set migrationLastResult $res.Message

exit $res.ExitCode
