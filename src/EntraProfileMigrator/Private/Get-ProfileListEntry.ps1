function Get-ProfileListEntry {
    <#
    .SYNOPSIS
        Reads every entry under the ProfileList registry key and classifies it.
        READ-ONLY. This is the foundation the rest of the tool builds on.

    .OUTPUTS
        PSCustomObject per profile with:
          Sid, Account, ProfileImagePath, Classification, IsLoaded, LastUseTime, RawState
        Classification in: Domain | AzureAD | Local | System
    #>
    [CmdletBinding()]
    param()

    $profileListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

    $wellKnownSystem = @(
        'S-1-5-18',  # LocalSystem
        'S-1-5-19',  # LocalService
        'S-1-5-20'   # NetworkService
    )

    Get-ChildItem -Path $profileListPath -ErrorAction Stop | ForEach-Object {
        $key = $_
        $sid = $key.PSChildName

        # Skip the ".bak" backup keys Windows leaves behind; surface them as a warning instead.
        if ($sid -match '\.bak$') {
            Write-MigrationLog "Found a .bak ProfileList key ($sid) — needs review before migration." -Level WARN
            return
        }

        $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        $imagePath = $props.ProfileImagePath

        # Resolve SID -> account name. May fail if the source domain is gone; that's expected.
        $account = $null
        try {
            $account = ([System.Security.Principal.SecurityIdentifier]$sid).Translate(
                [System.Security.Principal.NTAccount]).Value
        } catch {
            $account = $null
        }

        # Classify. ORDER MATTERS: Entra (cloud) identities use the S-1-12-1 authority, which
        # is NOT S-1-5-21. They must be detected BEFORE any "non-user authority => System"
        # fallback, or every Entra migration *target* gets misread as a System profile and the
        # tool can never find it. (Domain/local users are S-1-5-21; well-known are S-1-5-18/19/20.)
        $classification =
            if     ($wellKnownSystem -contains $sid)                            { 'System' }
            elseif ($sid -match '^S-1-12-1-' -or $account -match '^AzureAD\\')  { 'AzureAD' }
            elseif ($sid -match '^S-1-5-21-') {
                        # Domain vs local: local accounts resolve to <MACHINE>\name; an
                        # unresolved S-1-5-21 is almost always the now-departed source domain.
                        if     ($account -match "^$([regex]::Escape($env:COMPUTERNAME))\\") { 'Local' }
                        elseif ($account)                                                  { 'Domain' }
                        else                                                               { 'Domain' }
                    }
            else                                                               { 'System' }

        # Is the hive currently loaded (user logged on)? Loaded user hives appear under HKU\<SID>.
        $isLoaded = Test-Path "Registry::HKEY_USERS\$sid"

        [pscustomobject]@{
            Sid              = $sid
            Account          = $account
            ProfileImagePath = $imagePath
            Classification   = $classification
            IsLoaded         = $isLoaded
            RawState         = $props.State
            FolderExists     = $(if ($imagePath) { Test-Path $imagePath } else { $false })
        }
    }
}
