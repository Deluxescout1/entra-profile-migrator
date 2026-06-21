function Invoke-ProfileMigration {
    <#
    .SYNOPSIS
        Migrates a domain profile to an Entra (cloud-only) identity on this device.

    .DESCRIPTION
        DRY RUN BY DEFAULT. Without -Execute it runs prerequisites + prints the plan and changes
        nothing. With -Execute it backs up, re-permissions the filesystem and registry hive, and
        rewrites ProfileList so the user's next MS-account login lands in their existing profile.

        On any failure after backup, it attempts automatic rollback and reports whether manual
        rollback is still required.

    .PARAMETER TargetUpn   Entra UPN to migrate to (user must have signed in once).
    .PARAMETER SourceSid   Optional explicit source domain SID; auto-detected if omitted.
    .PARAMETER Mode        inplace (default) | copy.
    .PARAMETER Execute     Actually perform the migration. Omit for a dry run.

    .EXAMPLE
        Invoke-ProfileMigration -TargetUpn jsmith@contoso.com            # dry run
    .EXAMPLE
        Invoke-ProfileMigration -TargetUpn jsmith@contoso.com -Execute   # do it

    .OUTPUTS
        PSCustomObject { Success; ExitCode; BackupPath; Message }
        Exit codes: 0 ok | 10 dry-run | 20 prereq fail | 30 no source | 40 target SID missing
                    | 50 error(rolled back) | 60 error(manual rollback needed)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$TargetUpn,
        [string]$SourceSid,
        [ValidateSet('inplace','copy')][string]$Mode = 'inplace',
        [switch]$Execute
    )

    $result = { param($ok,$code,$backup,$msg)
        [pscustomobject]@{ Success=$ok; ExitCode=$code; BackupPath=$backup; Message=$msg } }

    Write-MigrationLog "=== Migration requested: $TargetUpn (Mode=$Mode, Execute=$Execute) ===" -Level INFO

    # --- Preflight ---
    $pre = Test-MigrationPrerequisite -TargetUpn $TargetUpn -SourceSid $SourceSid
    $pre.Checks | ForEach-Object {
        Write-MigrationLog ("  [{0}] {1}: {2}" -f ($(if($_.Pass){'PASS'}else{'FAIL'}), $_.Check, $_.Detail)) `
            -Level $(if($_.Pass){'INFO'}else{'WARN'})
    }
    if (-not ($pre.Checks | Where-Object Check -eq 'TargetSidMinted').Pass) {
        return & $result $false 40 $null 'Target user has not signed in yet; no minted SID.'
    }
    if (-not $pre.AllPassed) {
        return & $result $false 20 $null 'Prerequisites failed; see checks/log.'
    }

    # --- Resolve source + target ---
    $target = Resolve-TargetSid -TargetUpn $TargetUpn
    if (-not $target) { return & $result $false 40 $null 'Could not resolve target SID.' }

    if ($SourceSid) {
        $source = Get-ProfileListEntry | Where-Object Sid -eq $SourceSid
    } else {
        $source = @(Get-ProfileListEntry | Where-Object { $_.Classification -eq 'Domain' -and -not $_.IsLoaded })
        if ($source.Count -ne 1) {
            return & $result $false 30 $null "Expected exactly one auto-detected domain profile, found $($source.Count). Pass -SourceSid."
        }
        $source = $source[0]
    }
    if (-not $source -or -not $source.ProfileImagePath) {
        return & $result $false 30 $null 'No usable source profile.'
    }
    if ($source.ProfileImagePath -and (Join-Path $source.ProfileImagePath '.epm-migrated' | Test-Path)) {
        return & $result $true 0 $null 'Already migrated (marker present); nothing to do.'
    }

    $sourcePath    = $source.ProfileImagePath
    $throwawayPath = $target.ProfileImagePath

    $plan = @"
PLAN
  Source SID   : $($source.Sid)  ($($source.Account))
  Source folder: $sourcePath
  Target SID   : $($target.Sid)  ($TargetUpn)
  Throwaway    : $throwawayPath  (will be retired)
  Mode         : $Mode
  Result       : new SID will own $sourcePath; user logs in with MS account -> existing profile.
"@
    Write-MigrationLog $plan -Level INFO

    if (-not $Execute) {
        return & $result $true 10 $null "DRY RUN only. Re-run with -Execute to apply.`n$plan"
    }

    # --- Execute ---
    $backupDir = $null
    try {
        $backupDir = New-MigrationBackup -SourceSid $source.Sid -TargetSid $target.Sid `
                        -SourcePath $sourcePath -ThrowawayPath $throwawayPath -Mode $Mode
        $savedAcl = Join-Path $backupDir 'fs-acl.txt'

        Set-ProfileSidOwnership -ProfilePath $sourcePath -OldSid $source.Sid -NewSid $target.Sid `
                        -AclBackupPath $savedAcl -Copy:($Mode -eq 'copy')
        Update-RegistryHiveSid    -ProfilePath $sourcePath -OldSid $source.Sid -NewSid $target.Sid
        Update-ProfileListMapping -OldSid $source.Sid -NewSid $target.Sid -ProfilePath $sourcePath -BackupDir $backupDir

        # Idempotency marker.
        Set-Content -Path (Join-Path $sourcePath '.epm-migrated') `
            -Value ("Migrated {0} -> {1} on {2}" -f $source.Sid, $TargetUpn, (Get-Date -Format o))

        Write-MigrationLog "=== Migration complete. Reboot to finish. ===" -Level SUCCESS
        return & $result $true 0 $backupDir 'Migration complete. Reboot, then sign in with the MS account.'
    }
    catch {
        Write-MigrationLog "Migration failed: $_" -Level ERROR
        if ($backupDir) {
            try {
                Write-MigrationLog "Attempting automatic rollback from $backupDir" -Level WARN
                Restore-MigrationBackup -BackupPath $backupDir -ErrorAction Stop
                return & $result $false 50 $backupDir "Failed and rolled back: $_"
            } catch {
                return & $result $false 60 $backupDir "Failed; AUTO-ROLLBACK ALSO FAILED. See ROLLBACK.txt in $backupDir. Error: $_"
            }
        }
        return & $result $false 60 $null "Failed before backup completed: $_"
    }
}
