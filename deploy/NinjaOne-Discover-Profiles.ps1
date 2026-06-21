<#
    NinjaOne-Discover-Profiles.ps1

    Runs Get-MigrationCandidate on the device and writes a structured JSON report plus a
    human-readable summary to stdout (captured in the NinjaOne activity log). Review the
    output, then run NinjaOne-Run-Migration.ps1 with the parameters shown.

    NinjaOne environment variables (set as script variables in the policy):
      MigrationMappingCsv  — optional path to a mapping CSV (OldUsername,NewUpn)
      MigrationUserLeaf    — optional: restrict discovery to one username leaf (e.g. "jsmith")

    Exit codes:
      0   One or more candidates are ready to migrate.
      30  No domain profiles found — nothing to migrate on this device.
      40  Candidates found but none are ready (see blocking issues in output).
#>
[CmdletBinding()]
param(
    [string]$ModulePath  = (Join-Path $PSScriptRoot '..\src\EntraProfileMigrator\EntraProfileMigrator.psd1'),
    [string]$MappingCsv  = $env:MigrationMappingCsv,
    [string]$UserLeaf    = $env:MigrationUserLeaf
)

$ErrorActionPreference = 'Stop'

try {
    Import-Module $ModulePath -Force
} catch {
    Write-Error "Failed to import module from $ModulePath : $_"
    exit 20
}

$params = @{}
if ($MappingCsv) { $params['MappingCsv'] = $MappingCsv }
if ($UserLeaf)   { $params['UserLeaf']   = $UserLeaf }

$report = Get-MigrationCandidate @params

# --- Persist JSON report ---
$reportDir  = 'C:\ProgramData\EntraProfileMigrator'
$reportFile = Join-Path $reportDir ("discovery_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportFile -Encoding UTF8

# --- Human-readable summary for NinjaOne activity log ---
Write-Output "=========================================="
Write-Output " EntraProfileMigrator — Profile Discovery"
Write-Output "=========================================="
Write-Output "Device    : $($report.Machine)"
Write-Output "Timestamp : $($report.Timestamp)"
Write-Output "Report    : $reportFile"
Write-Output ""

if ($report.TotalCandidates -eq 0) {
    Write-Output "No domain profiles found on this device. Nothing to migrate."
    exit 30
}

Write-Output ("Found {0} candidate(s), {1} ready to migrate." -f $report.TotalCandidates, $report.ReadyCount)
Write-Output ""

foreach ($c in $report.Candidates) {
    $status = if ($c.ReadyToMigrate) { 'READY' } else { 'NOT READY' }

    Write-Output "------------------------------------------"
    Write-Output "  Status     : $status"
    Write-Output "  Source     : $($c.SourceAccount)"
    Write-Output "  Folder     : $($c.SourcePath)"
    Write-Output "  Source SID : $($c.SourceSid)"
    Write-Output "  Target UPN : $(if ($c.TargetUpn) { $c.TargetUpn } else { '(not found)' })"
    Write-Output "  Target SID : $(if ($c.TargetSid) { $c.TargetSid } else { '(not minted)' })"
    Write-Output "  Confidence : $($c.MatchConfidence) — $($c.MatchReason)"

    if ($c.BlockingIssues) {
        Write-Output "  Blocking:"
        foreach ($b in $c.BlockingIssues) { Write-Output "    ! $b" }
    }

    if ($c.ReadyToMigrate) {
        Write-Output ""
        Write-Output "  >> To migrate, run NinjaOne-Run-Migration.ps1 with:"
        Write-Output "       MigrationTargetUpn = $($c.TargetUpn)"
        Write-Output "       MigrationSourceSid = $($c.SourceSid)"
        Write-Output "       MigrationExecute   = true"
    }

    Write-Output ""
}

if ($report.UnpairedEntra) {
    Write-Output "------------------------------------------"
    Write-Output "Entra profiles with no matched domain source:"
    foreach ($e in $report.UnpairedEntra) {
        Write-Output "  $($e.Account)  —  $($e.ProfileImagePath)"
    }
    Write-Output ""
}

if ($report.ReadyCount -gt 0) { exit 0 } else { exit 40 }
