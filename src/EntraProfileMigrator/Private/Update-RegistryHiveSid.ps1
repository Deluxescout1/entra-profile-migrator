function Invoke-HiveAclSubstitution {
    # Recursive helper: walks a mounted registry key tree and substitutes OldSid with NewSid
    # in every ACE and owner field. Returns the number of keys whose security was modified.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Key,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$OldSid,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$NewSid
    )

    $count = 0

    try {
        $acl = $Key.GetAccessControl(
            [System.Security.AccessControl.AccessControlSections]::Owner -bor
            [System.Security.AccessControl.AccessControlSections]::Access)
        $changed = $false

        # Substitute owner
        try {
            $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier])
            if ($owner -and $owner.Value -eq $OldSid.Value) {
                $acl.SetOwner($NewSid)
                $changed = $true
            }
        } catch { <# Owner may not be readable on some protected keys; skip silently. #> }

        # Substitute DACL ACEs — only look at explicit (non-inherited) rules so we don't
        # duplicate inherited entries that will propagate correctly after the root is updated.
        $rules = @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
        foreach ($rule in $rules) {
            if ($rule.IdentityReference.Value -eq $OldSid.Value) {
                $null = $acl.RemoveAccessRule($rule)
                $acl.AddAccessRule([System.Security.AccessControl.RegistryAccessRule]::new(
                    $NewSid,
                    $rule.RegistryRights,
                    $rule.InheritanceFlags,
                    $rule.PropagationFlags,
                    $rule.AccessControlType))
                $changed = $true
            }
        }

        if ($changed) {
            $Key.SetAccessControl($acl)
            $count++
        }
    } catch {
        Write-MigrationLog "ACL substitution skipped on '$($Key.Name)': $_" -Level WARN
    }

    # Recurse — FullControl needed so GetSubKeyNames() works on every handle;
    # ReadWriteSubTree skips the ACL check on subkeys (SYSTEM owns the hive anyway).
    foreach ($subName in @($Key.GetSubKeyNames())) {
        try {
            $sub = $Key.OpenSubKey(
                $subName,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                [System.Security.AccessControl.RegistryRights]::FullControl)
            if ($sub) {
                $count += Invoke-HiveAclSubstitution -Key $sub -OldSid $OldSid -NewSid $NewSid
                $sub.Close()
            }
        } catch {
            Write-MigrationLog "Cannot open subkey '$subName' under '$($Key.Name)': $_" -Level WARN
        }
    }

    $count
}

function Update-RegistryHiveSid {
    <#
    .SYNOPSIS
        Loads the profile's user hive(s) offline and substitutes OldSid with NewSid in every
        ACE and owner field, so the migrated user owns their own registry on next logon.

    .DESCRIPTION
        Loads NTUSER.DAT (and UsrClass.dat if present) under a temporary HKU mount, then
        recursively walks every subkey and replaces OldSid with NewSid in DACL ACEs and
        owner fields using .NET RegistrySecurity. The target hive MUST NOT already be loaded
        (user logged off) — caller guarantees this.

        Value-level SID references inside the hive (rare, app-specific) are NOT rewritten by
        ACL changes. If ever needed, gate a SetACL.exe pass behind a feature flag.

    .PARAMETER ProfilePath  Profile folder containing NTUSER.DAT.
    .PARAMETER OldSid       Source (domain) SID to replace.
    .PARAMETER NewSid       Target (Entra) SID to substitute in.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$OldSid,
        [Parameter(Mandatory)][string]$NewSid
    )

    $mount = 'EPM_TMP'
    $hives = @(
        @{ Name = 'NTUSER';   File = Join-Path $ProfilePath 'NTUSER.DAT' },
        @{ Name = 'USRCLASS'; File = Join-Path $ProfilePath 'AppData\Local\Microsoft\Windows\UsrClass.dat' }
    )

    $oldSidObj = [System.Security.Principal.SecurityIdentifier]$OldSid
    $newSidObj = [System.Security.Principal.SecurityIdentifier]$NewSid

    foreach ($h in $hives) {
        if (-not (Test-Path -LiteralPath $h.File)) {
            Write-MigrationLog "Hive not present, skipping: $($h.File)" -Level INFO
            continue
        }
        $mountName = "${mount}_$($h.Name)"

        if ($PSCmdlet.ShouldProcess($h.File, "Substitute SID $OldSid -> $NewSid in hive")) {
            try {
                $p = Start-Process reg -NoNewWindow -Wait -PassThru `
                    -ArgumentList @('load', "HKU\$mountName", "`"$($h.File)`"")
                if ($p.ExitCode -ne 0) { throw "reg load failed for $($h.File) (exit $($p.ExitCode))." }

                $rootKey = [Microsoft.Win32.Registry]::Users.OpenSubKey(
                    $mountName,
                    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                    [System.Security.AccessControl.RegistryRights]::FullControl)

                if (-not $rootKey) { throw "Could not open HKU\$mountName for write." }

                $changed = Invoke-HiveAclSubstitution -Key $rootKey -OldSid $oldSidObj -NewSid $newSidObj
                $rootKey.Close()

                Write-MigrationLog "Hive $($h.Name): SID substituted on $changed key(s)" -Level SUCCESS
            }
            finally {
                [gc]::Collect()
                [gc]::WaitForPendingFinalizers()
                Start-Sleep -Milliseconds 250
                $null = Start-Process reg -NoNewWindow -Wait `
                    -ArgumentList @('unload', "HKU\$mountName")
            }
        }
    }
}
