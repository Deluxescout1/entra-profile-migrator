<#
  Start-MigrationAsSystem.ps1

  Runs Invoke-ProfileMigration as NT AUTHORITY\SYSTEM in the background, without any
  RMM. Re-permissioning another user's profile and loading their NTUSER.DAT needs
  SYSTEM (or backup/restore privileges) and the target logged off; this gives an
  elevated technician a one-command SYSTEM run by registering a transient scheduled
  task, running it, waiting, then removing it.

  Dry run by default (safe). Add -Execute to actually migrate. Mirrors the module's
  exit codes: 0 ok | 10 dry-run | 20 prereq | 30 no source | 40 no target SID
              | 50 error(rolled back) | 60 error(manual rollback) | 70 launcher error.

  USAGE (elevated):
    .\deploy\Start-MigrationAsSystem.ps1 -TargetUpn jsmith@contoso.com            # dry run
    .\deploy\Start-MigrationAsSystem.ps1 -TargetUpn jsmith@contoso.com -Execute   # migrate
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetUpn,
    [string]$SourceSid,
    [ValidateSet('inplace', 'copy')][string]$Mode = 'inplace',
    [switch]$Execute,
    [string]$ModulePath = (Join-Path $PSScriptRoot '..\src\EntraProfileMigrator\EntraProfileMigrator.psd1'),
    [int]$TimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Error 'Run elevated (Administrator) to register a SYSTEM task.'; exit 70 }

try {
    $moduleFull = (Resolve-Path -LiteralPath $ModulePath).Path
}
catch { Write-Error "Module not found at $ModulePath"; exit 70 }

# --- Build the SYSTEM-side runner script ---
$work = Join-Path $env:ProgramData 'EntraProfileMigrator\system-run'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$stamp      = Get-Date -Format 'yyyyMMdd_HHmmss'
$resultFile = Join-Path $work "result_$stamp.json"
$runner     = Join-Path $work "run_$stamp.ps1"

function ConvertTo-PSLiteral { param($s) "'" + ($s -replace "'", "''") + "'" }

$invoke = "Invoke-ProfileMigration -TargetUpn $(ConvertTo-PSLiteral $TargetUpn) -Mode $(ConvertTo-PSLiteral $Mode)"
if ($SourceSid) { $invoke += " -SourceSid $(ConvertTo-PSLiteral $SourceSid)" }
if ($Execute)   { $invoke += ' -Execute' }

$runnerContent = @"
`$ErrorActionPreference = 'Stop'
try {
    Import-Module $(ConvertTo-PSLiteral $moduleFull) -Force
    `$res = $invoke
    `$res | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $(ConvertTo-PSLiteral $resultFile) -Encoding UTF8
    exit [int]`$res.ExitCode
}
catch {
    @{ Success = `$false; ExitCode = 60; Message = "`$(`$_ | Out-String)" } |
        ConvertTo-Json | Set-Content -LiteralPath $(ConvertTo-PSLiteral $resultFile) -Encoding UTF8
    exit 60
}
"@
Set-Content -LiteralPath $runner -Value $runnerContent -Encoding UTF8

# --- Register + run a one-shot SYSTEM task ---
$taskName  = "EPM-SystemRun-$stamp"
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runner`""
$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds $TimeoutSeconds)

Write-Host "Registering SYSTEM task '$taskName' (Execute=$Execute, Mode=$Mode)..."
$task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings
Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null

$exitCode = 70
try {
    Start-ScheduledTask -TaskName $taskName
    Write-Host "Running as SYSTEM; waiting up to $TimeoutSeconds s..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Start-Sleep -Seconds 2
    while ((Get-Date) -lt $deadline) {
        if ((Get-ScheduledTask -TaskName $taskName).State -eq 'Ready') { break }
        Start-Sleep -Seconds 2
    }
    $info = Get-ScheduledTaskInfo -TaskName $taskName
    # 0x41301 = still running (timed out); otherwise LastTaskResult is the process exit code.
    if ($info.LastTaskResult -eq 0x41301) {
        Write-Warning "Task still running after timeout; not cleaning up. Check Task Scheduler / logs."
        exit 70
    }
    $exitCode = [int]$info.LastTaskResult
}
finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $resultFile) {
    try {
        $res = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        Write-Host ("Result: Success={0} ExitCode={1}" -f $res.Success, $res.ExitCode)
        Write-Output $res.Message
    }
    catch { Write-Warning "Could not read result file $resultFile" }
}
Write-Host "Logs: $(Join-Path $env:ProgramData 'EntraProfileMigrator\Logs')"
exit $exitCode
