function Restore-MigrationBackup {
    <#
    .SYNOPSIS
        Rolls a migration back using the artifacts written by New-MigrationBackup and
        Update-ProfileListMapping.

    .DESCRIPTION
        Restores the system to pre-migration state in this order:
          1. Validates manifest.json and warns on machine mismatch.
          2. Re-imports the ProfileList registry backup (per-SID files written by
             Update-ProfileListMapping, or the monolithic profilelist.reg from
             New-MigrationBackup — whichever is present).
          3. Restores the profile tree's NTFS ACLs from fs-acl.txt (icacls /restore).
          4. Reverses the hive ACL substitution by re-running Update-RegistryHiveSid
             with source and target swapped (target->source).
          5. Un-retires the throwaway Entra profile folder if it was renamed.
          6. Removes the .epm-migrated idempotency marker.

        Run as SYSTEM/admin with the target user logged off. Reboot after.

    .PARAMETER BackupPath
        The C:\ProgramData\EntraProfileMigrator\Backups\<timestamp> folder.

    .PARAMETER SkipHiveRollback
        Skip step 4 (hive ACL reversal). Use if the hive is locked or if only the
        ProfileList and filesystem ACLs need to be restored.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][ValidateScript({
            Test-Path -LiteralPath $_ -PathType Container
        })][string]$BackupPath,

        [switch]$SkipHiveRollback
    )

    # --- 1. Read and validate manifest ---
    $manifestFile = Join-Path $BackupPath 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestFile)) {
        throw "manifest.json not found in $BackupPath. Cannot roll back without it."
    }
    $m = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json

    foreach ($field in 'sourceSid', 'targetSid', 'sourcePath', 'timestamp') {
        if (-not $m.$field) { throw "manifest.json is missing required field '$field'." }
    }
    if ($m.machine -and $m.machine -ne $env:COMPUTERNAME) {
        Write-Warning "Backup was created on '$($m.machine)'; running on '$($env:COMPUTERNAME)'. Proceed only if this is the same machine."
    }

    $action = "Roll back migration $($m.timestamp): restore $($m.sourceSid) on $($m.sourcePath)"
    if (-not $PSCmdlet.ShouldProcess($BackupPath, $action)) { return }

    Write-MigrationLog "=== Rollback starting: migration $($m.timestamp) ===" -Level WARN

    # --- 2. Restore ProfileList registry ---
    # New Update-ProfileListMapping writes one .reg per SID; New-MigrationBackup writes a
    # monolithic profilelist.reg. Try per-SID first so each key is restored independently.
    $anyRegRestored = $false
    foreach ($sid in @($m.sourceSid, $m.targetSid)) {
        $regFile = Join-Path $BackupPath "profilelist-$sid.reg"
        if (Test-Path -LiteralPath $regFile) {
            $p = Start-Process reg -NoNewWindow -Wait -PassThru `
                -ArgumentList @('import', "`"$regFile`"")
            if ($p.ExitCode -ne 0) {
                Write-MigrationLog "reg import of profilelist-$sid.reg returned $($p.ExitCode)" -Level WARN
            } else {
                Write-MigrationLog "ProfileList\$sid restored from $regFile" -Level SUCCESS
                $anyRegRestored = $true
            }
        }
    }
    if (-not $anyRegRestored) {
        $mono = Join-Path $BackupPath 'profilelist.reg'
        if (Test-Path -LiteralPath $mono) {
            $p = Start-Process reg -NoNewWindow -Wait -PassThru `
                -ArgumentList @('import', "`"$mono`"")
            if ($p.ExitCode -ne 0) { throw "reg import failed (exit $($p.ExitCode))." }
            Write-MigrationLog "ProfileList restored from $mono" -Level SUCCESS
        } else {
            Write-MigrationLog "No ProfileList backup found in $BackupPath; registry not restored." -Level WARN
        }
    }

    # --- 3. Restore filesystem ACLs ---
    $aclFile = Join-Path $BackupPath 'fs-acl.txt'
    if (Test-Path -LiteralPath $aclFile) {
        # icacls /save stores paths relative to the profile folder's PARENT, so /restore must
        # run against that parent (e.g. C:\Users), NOT the profile folder itself — otherwise it
        # matches nothing and the original ACLs are silently never restored.
        $restoreRoot = Split-Path -Parent $m.sourcePath
        $p = Start-Process icacls -NoNewWindow -Wait -PassThru -ArgumentList @(
            "`"$restoreRoot`"", '/restore', "`"$aclFile`"", '/C', '/L', '/Q')
        if ($p.ExitCode -ne 0) {
            Write-MigrationLog "icacls /restore returned $($p.ExitCode)" -Level WARN
        } else {
            Write-MigrationLog "Filesystem ACLs restored for $($m.sourcePath)" -Level SUCCESS
        }
    } else {
        Write-MigrationLog "fs-acl.txt not found; filesystem ACLs not restored." -Level WARN
    }

    # --- 4. Reverse hive ACL substitution (target -> source) ---
    if (-not $SkipHiveRollback) {
        try {
            Update-RegistryHiveSid -ProfilePath $m.sourcePath `
                -OldSid $m.targetSid -NewSid $m.sourceSid
            Write-MigrationLog "Hive ACLs reversed ($($m.targetSid) -> $($m.sourceSid))" -Level SUCCESS
        } catch {
            Write-MigrationLog "Hive ACL reversal failed: $_" -Level WARN
            Write-MigrationLog "Manual fix: load NTUSER.DAT offline, grant $($m.sourceSid) FullControl, unload." -Level WARN
        }
    }

    # --- 5. Un-retire throwaway folder ---
    if ($m.throwawayPath) {
        $throwawayLeaf   = Split-Path $m.throwawayPath -Leaf
        $throwawayParent = Split-Path $m.throwawayPath -Parent
        if (Test-Path -LiteralPath $throwawayParent) {
            $retired = Get-ChildItem -LiteralPath $throwawayParent `
                -Filter "$throwawayLeaf.epm-retired*" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($retired) {
                Rename-Item -LiteralPath $retired.FullName -NewName $throwawayLeaf -ErrorAction SilentlyContinue
                Write-MigrationLog "Throwaway profile un-retired: $($retired.FullName) -> $($m.throwawayPath)" -Level SUCCESS
            }
        }
    }

    # --- 6. Remove idempotency marker so the profile is migratable again ---
    Remove-Item -LiteralPath (Join-Path $m.sourcePath '.epm-migrated') -ErrorAction SilentlyContinue

    Write-MigrationLog "=== Rollback complete for migration $($m.timestamp). Reboot recommended. ===" -Level SUCCESS

    [pscustomobject]@{
        Timestamp  = $m.timestamp
        SourceSid  = $m.sourceSid
        TargetSid  = $m.targetSid
        SourcePath = $m.sourcePath
        BackupPath = $BackupPath
    }
}
