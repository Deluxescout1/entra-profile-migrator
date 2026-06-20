function Update-ProfileListMapping {
    <#
    .SYNOPSIS
        Maps the new (Entra) SID's ProfileList entry to the existing profile folder.
    .DESCRIPTION
        Two models:
          * Sign-in-once  - the new SID already has an entry (and a throwaway profile);
                            repoint it at the real profile and retire the throwaway.
          * Background    - the user has NOT signed in yet (no entry exists). Pass
                            -Provision and the entry is created from the old profile's
                            values, then pointed at the real profile. This is the path
                            for unattended SYSTEM deployment ahead of first sign-in.
        Either way: rewrites State/Flags/RefCount to clean values, rewrites the binary
        Sid to the new SID, backs both keys up to the rollback dir, and removes the old
        domain SID's entry after backup.
        Run as SYSTEM with the target user logged off (hives must be unloaded).
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

        [Parameter(Mandatory)][ValidateScript({
            Test-Path -LiteralPath $_ -PathType Container
        })][string]$ProfilePath,

        [Parameter(Mandatory)][ValidateScript({
            Test-Path -LiteralPath $_ -PathType Container
        })][string]$BackupDir,

        # Create the new SID's entry if it doesn't exist yet (background / pre-sign-in).
        [switch]$Provision,
        [bool]$RemoveOldEntry = $true,
        # Delete the throwaway folder when it is empty; rename (retire) it when non-empty.
        [switch]$PurgeThrowaway
    )

    $base       = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $oldKey     = Join-Path $base $OldSid
    $newKey     = Join-Path $base $NewSid
    $targetPath = (Convert-Path -LiteralPath $ProfilePath)
    $newExists  = Test-Path -LiteralPath $newKey

    if (-not $newExists -and -not $Provision) {
        throw "No ProfileList entry for the new SID ($NewSid). For a background migration before the user signs in, re-run with -Provision."
    }
    if (Test-Path -LiteralPath ($newKey + '.bak')) {
        Write-Warning "A shadow key '$NewSid.bak' exists; Windows may prefer it and drop the user into a temp profile. Reconcile it manually."
    }

    $action = if ($newExists) { "Back up keys, then repoint new SID at $targetPath" } `
              else             { "Back up keys, then provision new SID entry -> $targetPath" }
    if (-not $PSCmdlet.ShouldProcess($newKey, $action)) { return }

    # --- Back up existing ProfileList keys before any change ---
    foreach ($pair in @(@{ Sid = $OldSid; Path = $oldKey }, @{ Sid = $NewSid; Path = $newKey })) {
        if (Test-Path -LiteralPath $pair.Path) {
            $regFile   = Join-Path $BackupDir ('profilelist-{0}.reg' -f $pair.Sid)
            $regNative = $pair.Path -replace '^HKLM:\\', 'HKLM\'
            $null = & reg.exe export $regNative $regFile /y 2>&1
            if (-not (Test-Path -LiteralPath $regFile) -or
                (Get-Item -LiteralPath $regFile).Length -eq 0) {
                throw "Failed to back up $($pair.Path) to $regFile. Aborting before any change."
            }
            Write-MigrationLog "Backed up ProfileList\$($pair.Sid) -> $regFile" -Level INFO
        }
    }

    $retiredPath = $null

    if ($newExists) {
        # ---- Sign-in-once: retire the throwaway profile created at first logon ----
        $throwaway = $null
        try {
            $throwaway = (Get-ItemProperty -LiteralPath $newKey -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
        } catch { }

        if ($throwaway) {
            $tw = [Environment]::ExpandEnvironmentVariables($throwaway).TrimEnd('\')
            if ($tw -ieq $targetPath.TrimEnd('\')) {
                Write-MigrationLog "New SID already points at the target profile; nothing to retire." -Level INFO
            }
            elseif (Test-Path -LiteralPath $tw) {
                $isEmpty = @(Get-ChildItem -LiteralPath $tw -Force -ErrorAction SilentlyContinue).Count -eq 0
                try {
                    if ($PurgeThrowaway -and $isEmpty) {
                        Remove-Item -LiteralPath $tw -Recurse -Force -ErrorAction Stop
                        Write-MigrationLog "Deleted empty throwaway $tw" -Level INFO
                    }
                    else {
                        $retiredName = '{0}.epm-retired-{1}' -f (Split-Path $tw -Leaf), (Get-Date -Format 'yyyyMMddHHmmss')
                        $retiredPath = Join-Path (Split-Path $tw -Parent) $retiredName
                        if (Test-Path -LiteralPath $retiredPath) {
                            $retiredPath = '{0}-{1}' -f $retiredPath, [guid]::NewGuid().ToString('N').Substring(0, 6)
                        }
                        Rename-Item -LiteralPath $tw -NewName (Split-Path $retiredPath -Leaf) -ErrorAction Stop
                        if (-not $isEmpty) { Write-Warning "Throwaway $tw was not empty; retired to $retiredPath." }
                        Write-MigrationLog "Retired throwaway -> $retiredPath" -Level INFO
                    }
                }
                catch { throw "Could not retire throwaway folder $tw (user still logged on?): $($_.Exception.Message)" }
            }
        }
    }
    else {
        # ---- Background: provision the entry by cloning the old profile's values ----
        if (-not (Test-Path -LiteralPath $oldKey)) {
            throw "Cannot provision: no source ProfileList entry for the old SID ($OldSid) to clone from."
        }
        New-Item -Path $newKey -Force | Out-Null
        $srcKey = Get-Item -LiteralPath $oldKey
        $src    = Get-ItemProperty -LiteralPath $oldKey
        foreach ($prop in $src.PSObject.Properties) {
            if ($prop.Name -in 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') { continue }
            Set-ItemProperty -LiteralPath $newKey -Name $prop.Name -Value $prop.Value `
                -Type $srcKey.GetValueKind($prop.Name) -ErrorAction SilentlyContinue
        }
        Write-MigrationLog "Provisioned ProfileList[$NewSid] cloned from $OldSid" -Level INFO
    }

    # --- Point at the real profile; rewrite binary Sid; reset to clean state (both models) ---
    $sidObj   = [System.Security.Principal.SecurityIdentifier]::new($NewSid)
    $sidBytes = New-Object byte[] $sidObj.BinaryLength
    $sidObj.GetBinaryForm($sidBytes, 0)

    Set-ItemProperty -LiteralPath $newKey -Name ProfileImagePath -Value $targetPath  -Type ExpandString
    Set-ItemProperty -LiteralPath $newKey -Name Sid              -Value $sidBytes     -Type Binary
    Set-ItemProperty -LiteralPath $newKey -Name State            -Value 0             -Type DWord
    Set-ItemProperty -LiteralPath $newKey -Name Flags            -Value 0             -Type DWord
    Set-ItemProperty -LiteralPath $newKey -Name RefCount         -Value 0             -Type DWord
    Write-MigrationLog "ProfileList[$NewSid].ProfileImagePath -> $targetPath" -Level SUCCESS

    # --- Remove old entry (backed up above); casing-collision guard ---
    $oldRemoved = $false
    if ($RemoveOldEntry -and ($OldSid -ine $NewSid) -and (Test-Path -LiteralPath $oldKey)) {
        Remove-Item -LiteralPath $oldKey -Recurse -Force -ErrorAction Stop
        $oldRemoved = $true
        Write-MigrationLog "Removed old ProfileList entry $OldSid (backed up)" -Level SUCCESS
    }
    elseif (-not $RemoveOldEntry) {
        Write-MigrationLog "Old ProfileList key $OldSid kept (RemoveOldEntry=false)" -Level INFO
    }

    [pscustomobject]@{
        NewSid           = $NewSid
        OldSid           = $OldSid
        Mode             = if ($newExists) { 'Repoint' } else { 'Provision' }
        ProfileImagePath = $targetPath
        ThrowawayRetired = $retiredPath
        OldEntryRemoved  = $oldRemoved
        BackupDir        = $BackupDir
    }
}
