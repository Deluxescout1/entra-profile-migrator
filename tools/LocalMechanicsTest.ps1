<#
  LocalMechanicsTest.ps1

  Proves the MUTATION + ROLLBACK machinery on a real Windows box using two
  DISPOSABLE LOCAL accounts as stand-ins for the old (domain) and new (Entra)
  SIDs. The ACL / hive / ProfileList rewrite is SID-agnostic, so two local
  SIDs exercise exactly the same code paths the real migration uses.

  What this DOES validate:
    - read-only enumeration / classification
    - New-MigrationBackup, Set-ProfileSidOwnership, Update-RegistryHiveSid,
      Update-ProfileListMapping, Test-ProfileSidMigration
    - Restore-MigrationBackup (the rollback)

  What it does NOT validate (needs a domain profile + an Entra-joined device):
    - Domain/AzureAD classification, the dsregcmd join gate, target-SID
      discovery, and the throwaway-profile retirement of a real first login.

  SETUP (do this once, manually):
    1. Create two throwaway local users you do not care about, e.g.:
         net user oldie  P@ssw0rd! /add
         net user newbie P@ssw0rd! /add
    2. Sign in to EACH once (interactively) so Windows mints their SID +
       profile folder, then sign back out. Drop a few junk files in oldie's
       Desktop/Documents so you can confirm data survives.
    3. Make sure you are NOT logged in as either account.

  USAGE (elevated):
    # Safe dry run (default) - shows the plan, changes nothing:
    .\tools\LocalMechanicsTest.ps1 -SourceAccount oldie -TargetAccount newbie

    # Real run: migrate, verify, then automatically roll back:
    .\tools\LocalMechanicsTest.ps1 -SourceAccount oldie -TargetAccount newbie -Execute

  WARNING: -Execute makes real changes. There is no VM checkpoint on a physical
  PC. Use throwaway accounts only. The script rolls back automatically unless
  you pass -KeepMigrated.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceAccount,
    [Parameter(Mandatory)][string]$TargetAccount,
    [string]$ModulePath = (Join-Path $PSScriptRoot '..\src\EntraProfileMigrator'),
    [switch]$Execute,
    [switch]$KeepMigrated
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Note { param($m) Write-Host "  [..]   $m" }
function Write-Warn { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Stop-Test  { param($m) Write-Host "  [STOP] $m" -ForegroundColor Red; exit 1 }

$pilBase = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

# --- Load private + public functions (the manifest does not export the private ones) ---
foreach ($dir in 'Private', 'Public') {
    Get-ChildItem -Path (Join-Path $ModulePath $dir) -Filter *.ps1 | ForEach-Object { . $_.FullName }
}

# --- Must be elevated ---
$me      = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Stop-Test 'Run this elevated (Administrator).' }

# --- Resolve the two local profiles ---
$all = Get-ProfileListEntry

function Resolve-LocalProfile {
    param($name)
    $hit = @($all | Where-Object { $_.Account -and (($_.Account -split '\\')[-1] -ieq $name) })
    if ($hit.Count -eq 0) {
        Stop-Test "No profile for local account '$name'. Create it and sign in once to mint its profile."
    }
    if ($hit.Count -gt 1) { Stop-Test "Multiple profiles match '$name'; resolve manually." }
    $hit[0]
}

$src = Resolve-LocalProfile $SourceAccount
$tgt = Resolve-LocalProfile $TargetAccount

# --- Safety gates: disposable LOCAL accounts only, not loaded, not us ---
if ($src.Sid -eq $tgt.Sid) { Stop-Test 'Source and target are the same profile.' }
foreach ($p in @($src, $tgt)) {
    if ($p.Classification -ne 'Local') {
        Stop-Test "Refusing: '$($p.Account)' is '$($p.Classification)', not 'Local'. This harness is for disposable LOCAL accounts only."
    }
    if ($p.IsLoaded)              { Stop-Test "Refusing: '$($p.Account)' is logged on (hive loaded). Log it off first." }
    if ($p.Sid -eq $me.User.Value){ Stop-Test "Refusing: '$($p.Account)' is the account running this script." }
    if (-not $p.FolderExists)     { Stop-Test "Profile folder missing for '$($p.Account)': $($p.ProfileImagePath)" }
}

# --- Read-only inventory ---
Write-Step 'Read-only inventory (Get-ProfileListEntry)'
$all | Where-Object Classification -ne 'System' |
    Format-Table Classification, Account, Sid, ProfileImagePath, IsLoaded, FolderExists -AutoSize | Out-Host
Write-Ok "Source (old SID): $($src.Account)  $($src.Sid)  $($src.ProfileImagePath)"
Write-Ok "Target (new SID): $($tgt.Account)  $($tgt.Sid)  $($tgt.ProfileImagePath)"

# --- Dry run: show the plan, change nothing ---
Write-Step 'DRY RUN (-WhatIf) - changes nothing'
$dry = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP 'epm-localtest-dry')
try {
    $null = New-MigrationBackup    -SourceSid $src.Sid -TargetSid $tgt.Sid -SourcePath $src.ProfileImagePath -ThrowawayPath $tgt.ProfileImagePath -WhatIf
    Set-ProfileSidOwnership        -OldSid $src.Sid -NewSid $tgt.Sid -ProfilePath $src.ProfileImagePath -WhatIf
    Update-RegistryHiveSid         -OldSid $src.Sid -NewSid $tgt.Sid -ProfilePath $src.ProfileImagePath -WhatIf
    Update-ProfileListMapping      -OldSid $src.Sid -NewSid $tgt.Sid -ProfilePath $src.ProfileImagePath -BackupDir $dry.FullName -WhatIf
}
finally { Remove-Item -LiteralPath $dry.FullName -Recurse -Force -ErrorAction SilentlyContinue }
Write-Ok 'Dry run complete.'

if (-not $Execute) {
    Write-Host "`nDry run only. Re-run with -Execute to perform a real migrate + automatic rollback." -ForegroundColor Yellow
    exit 0
}

# --- Confirm the real run ---
Write-Step 'EXECUTE - real changes'
Write-Warn "Will re-ACL $($src.ProfileImagePath), rewrite its NTUSER.DAT ACLs, repoint"
Write-Warn "ProfileList[$($tgt.Sid)] at that folder, and retire $($tgt.ProfileImagePath)."
if ((Read-Host 'Type MIGRATE to proceed') -ne 'MIGRATE') { Stop-Test 'Not confirmed.' }

# --- Migrate (same sequence as Invoke-ProfileMigration, with explicit local SIDs) ---
Write-Step 'Migrating'
$backupDir = New-MigrationBackup -SourceSid $src.Sid -TargetSid $tgt.Sid `
                -SourcePath $src.ProfileImagePath -ThrowawayPath $tgt.ProfileImagePath
Write-Ok "Backup: $backupDir"
Set-ProfileSidOwnership   -OldSid $src.Sid -NewSid $tgt.Sid -ProfilePath $src.ProfileImagePath `
                -AclBackupPath (Join-Path $backupDir 'fs-acl.txt') -Confirm:$false | Out-Host
Update-RegistryHiveSid    -OldSid $src.Sid -NewSid $tgt.Sid -ProfilePath $src.ProfileImagePath -Confirm:$false
Update-ProfileListMapping -OldSid $src.Sid -NewSid $tgt.Sid -ProfilePath $src.ProfileImagePath `
                -BackupDir $backupDir -Confirm:$false | Out-Host
Set-Content -Path (Join-Path $src.ProfileImagePath '.epm-migrated') `
    -Value ("LocalMechanicsTest {0} -> {1} {2}" -f $src.Sid, $tgt.Sid, (Get-Date -Format o))

# --- Verify the migration applied ---
Write-Step 'Verify migration'
$chk = Test-ProfileSidMigration -Sid $src.Sid -ProfilePath $src.ProfileImagePath
if ($chk.Clean) { Write-Ok "Filesystem: nothing under the profile still references old SID $($src.Sid)" }
else            { Write-Warn "$($chk.RemainingAcl.Count) item(s) still reference the old SID" }

$newPil = (Get-ItemProperty -LiteralPath (Join-Path $pilBase $tgt.Sid) -ErrorAction SilentlyContinue).ProfileImagePath
if ($newPil -ieq $src.ProfileImagePath) { Write-Ok "ProfileList[$($tgt.Sid)] -> $newPil" }
else                                    { Write-Warn "ProfileList[$($tgt.Sid)] -> $newPil (expected $($src.ProfileImagePath))" }

if ($KeepMigrated) {
    Write-Host "`n-KeepMigrated set: leaving the machine migrated. Roll back manually with:" -ForegroundColor Yellow
    Write-Host "  Restore-MigrationBackup -BackupPath '$backupDir'" -ForegroundColor Yellow
    exit 0
}

# --- Roll back and verify ---
Write-Step 'ROLLBACK (Restore-MigrationBackup)'
Restore-MigrationBackup -BackupPath $backupDir -Confirm:$false | Out-Host

Write-Step 'Verify rollback'
$after   = Get-ProfileListEntry
$srcBack = @($after | Where-Object Sid -eq $src.Sid)
$tgtBack = @($after | Where-Object Sid -eq $tgt.Sid)
if ($srcBack.Count -eq 1) { Write-Ok "ProfileList entry for source SID $($src.Sid) restored." }
else                      { Write-Warn "Source SID entry not present after rollback." }
if ($tgtBack.Count -eq 1 -and ($tgtBack[0].ProfileImagePath -ieq $tgt.ProfileImagePath)) {
    Write-Ok "Target SID points back at $($tgt.ProfileImagePath)."
} else {
    Write-Warn "Target SID path after rollback: $($tgtBack[0].ProfileImagePath)"
}
if (Test-Path -LiteralPath $tgt.ProfileImagePath) { Write-Ok "Target folder un-retired: $($tgt.ProfileImagePath)" }
else                                              { Write-Warn "Target folder missing: $($tgt.ProfileImagePath)" }
if (-not (Test-Path -LiteralPath (Join-Path $src.ProfileImagePath '.epm-migrated'))) { Write-Ok 'Idempotency marker removed.' }
else                                                                                 { Write-Warn '.epm-migrated marker still present.' }

Write-Host "`nDone. Artifacts kept for inspection: $backupDir" -ForegroundColor Cyan
