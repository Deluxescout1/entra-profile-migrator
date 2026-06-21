function Set-ProfileSidOwnership {
    <#
    .SYNOPSIS
        Re-permissions an entire user profile tree from an old SID to a new SID.
    .DESCRIPTION
        Backs up the tree's ACLs first and refuses to proceed if that backup is empty.
        Default (Substitute) restores the backed-up ACLs with the SID swapped everywhere
        it appears (owner + DACL). -Copy is non-destructive: it grants the new SID full
        control but leaves the old SID's ACEs in place. icacls does the traversal, so the
        whole tree is covered regardless of path length. Verifies the result by default.

        Run as SYSTEM/admin. Restore is applied at the profile's PARENT so the relative
        paths recorded in the backup line up.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][ValidateScript({
            try { [void][System.Security.Principal.SecurityIdentifier]::new($_); $true }
            catch { throw "Not a valid SID: $_" }
        })][string]$OldSid,
        [Parameter(Mandatory)][ValidateScript({
            try { [void][System.Security.Principal.SecurityIdentifier]::new($_); $true }
            catch { throw "Not a valid SID: $_" }
        })][string]$NewSid,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$ProfilePath,

        # Keep the ACL backup on a SHORT path so PS-side checks never hit MAX_PATH.
        [string]$AclBackupPath = (Join-Path $env:WINDIR ('Temp\EPM-acl-{0}.bak' -f ([guid]::NewGuid().ToString('N')))),

        [switch]$Copy,
        [switch]$SkipVerify
    )

    $mode   = if ($Copy) { 'Copy' } else { 'Substitute' }
    $action = if ($Copy) { "Grant $NewSid full control (keep $OldSid)" } else { "Substitute $OldSid -> $NewSid" }
    if (-not $PSCmdlet.ShouldProcess($ProfilePath, $action)) { return }

    # --- 1. Back up ALL ACLs in the tree; abort on empty/failed save ---
    $null = & icacls.exe $ProfilePath /save $AclBackupPath /T /C 2>&1
    if (-not (Test-Path -LiteralPath $AclBackupPath) -or ((Get-Item -LiteralPath $AclBackupPath).Length -eq 0)) {
        throw "ACL backup is missing or empty ($AclBackupPath). Aborting before any change is made."
    }
    Write-Verbose "ACL backup: $AclBackupPath ($((Get-Item -LiteralPath $AclBackupPath).Length) bytes)"

    # --- 2. Apply ---
    if ($Copy) {
        $apply = & icacls.exe $ProfilePath /grant ('*{0}:(OI)(CI)F' -f $NewSid) /T /C /L 2>&1
    }
    else {
        # /L leaves the legacy junctions ("Application Data", "My Documents", ...) alone
        # instead of following them out of the profile.
        $parent = Split-Path -LiteralPath (Convert-Path -LiteralPath $ProfilePath) -Parent
        $apply  = & icacls.exe $parent /restore $AclBackupPath /substitute $OldSid $NewSid /C /L 2>&1
    }

    $applyText = ($apply | Out-String)
    if ($applyText -match 'Failed processing\s+(\d+)\s+file' -and [int]$Matches[1] -gt 0) {
        Write-Warning ("icacls reported {0} failed item(s) under {1} (likely locked/in-use; re-run or close handles)." -f $Matches[1], $ProfilePath)
        Write-Verbose $applyText.Trim()
    }

    # --- 3. Verify the WHOLE tree migrated ---
    $verified = $null
    if (-not $SkipVerify -and -not $Copy) {
        $v = Test-ProfileSidMigration -Sid $OldSid -ProfilePath $ProfilePath
        $verified = $v.Clean
        if (-not $v.Clean) {
            $sample = ($v.RemainingAcl | Select-Object -First 10) -join "`n"
            Write-Warning ("{0} object(s) under {1} STILL reference {2} after migration. First few:`n{3}" -f $v.RemainingAcl.Count, $ProfilePath, $OldSid, $sample)
        }
        else {
            Write-Verbose "Verification clean: nothing references $OldSid"
        }
    }

    [pscustomobject]@{
        ProfilePath = $ProfilePath
        Mode        = $mode
        AclBackup   = $AclBackupPath
        OldSid      = $OldSid
        NewSid      = $NewSid
        Verified    = $verified
    }
}
