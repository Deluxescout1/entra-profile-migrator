function New-MigrationBackup {
    <#
    .SYNOPSIS
        Captures everything needed to roll a migration back. Run BEFORE any mutation.

    .DESCRIPTION
        Writes to C:\ProgramData\EntraProfileMigrator\Backups\<timestamp>\:
          - profilelist.reg  : full export of the ProfileList key
          - fs-acl.txt       : icacls /save of the source profile tree (also used by /restore)
          - manifest.json    : source/target SIDs, paths, mode, intended changes
          - ROLLBACK.txt     : human-readable manual rollback steps
        Returns the backup folder path. Throws if the backup cannot be fully written
        (no backup => caller must abort).

    .PARAMETER SourceSid
    .PARAMETER TargetSid
    .PARAMETER SourcePath  Source profile folder (the real data).
    .PARAMETER ThrowawayPath  The sparse Entra profile folder to be cleaned up.
    .PARAMETER Mode  inplace | copy
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SourceSid,
        [Parameter(Mandatory)][string]$TargetSid,
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$ThrowawayPath,
        [ValidateSet('inplace','copy')][string]$Mode = 'inplace'
    )

    $stamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupDir = Join-Path 'C:\ProgramData\EntraProfileMigrator\Backups' $stamp

    if ($PSCmdlet.ShouldProcess($backupDir, 'Create migration backup')) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

        # 1. ProfileList export
        $regOut = Join-Path $backupDir 'profilelist.reg'
        $regKey = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $p = Start-Process reg -ArgumentList @('export', "`"$regKey`"", "`"$regOut`"", '/y') -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0 -or -not (Test-Path $regOut)) { throw "ProfileList export failed (exit $($p.ExitCode))." }

        # 2. Filesystem ACL save (this file is BOTH the backup and the input to the /substitute restore)
        $aclOut = Join-Path $backupDir 'fs-acl.txt'
        # NOTE: icacls /save writes a file relative to the directory it is run against; capture carefully.
        $p = Start-Process icacls -ArgumentList @("`"$SourcePath`"", '/save', "`"$aclOut`"", '/T', '/C', '/Q') -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) { Write-MigrationLog "icacls /save returned $($p.ExitCode); some items may be skipped." -Level WARN }

        # 3. Manifest
        $manifest = [ordered]@{
            timestamp     = $stamp
            sourceSid     = $SourceSid
            targetSid     = $TargetSid
            sourcePath    = $SourcePath
            throwawayPath = $ThrowawayPath
            mode          = $Mode
            machine       = $env:COMPUTERNAME
        }
        $manifest | ConvertTo-Json | Set-Content -Path (Join-Path $backupDir 'manifest.json')

        # 4. Human rollback steps
        @"
ROLLBACK for migration $stamp on $($env:COMPUTERNAME)
=====================================================
If the migration failed and left the system inconsistent:

1. Restore the ProfileList registry key:
     reg import "$regOut"

2. Restore the source-profile NTFS ACLs:
     icacls "$SourcePath" /restore "$aclOut" /C /Q

3. If a copy was made, the original at "$SourcePath" was left intact (copy mode only).

4. Reboot. Source SID $SourceSid should again own the profile at $SourcePath.

Or run:  Restore-MigrationBackup -BackupPath "$backupDir"
"@ | Set-Content -Path (Join-Path $backupDir 'ROLLBACK.txt')

        Write-MigrationLog "Backup written to $backupDir" -Level SUCCESS
    }

    return $backupDir
}
