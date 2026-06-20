function Get-ProfileListEntry {
    <#
    .SYNOPSIS
        Reads every entry under the ProfileList registry key and classifies it.
        READ-ONLY. This is the foundation the rest of the tool builds on.

    .OUTPUTS
        PSCustomObject per profile with:
          Sid, Account, ProfileImagePath, Classification, IsLoaded, LastUseTime, RawState
        Classification in: Domain | AzureAD | Local | System | Unknown
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

        # Classify.
        $classification =
            if     ($wellKnownSystem -contains $sid -or $sid -notmatch '^S-1-5-21-') { 'System' }
            elseif ($account -match '^AzureAD\\')                                    { 'AzureAD' }
            elseif ($account -and $account -match '\\')                              {
                        # Domain vs local: local accounts resolve to <MACHINE>\name.
                        if ($account -match "^$($env:COMPUTERNAME)\\") { 'Local' } else { 'Domain' }
                    }
            elseif (-not $account)                                                   { 'Domain' } # unresolved => likely the now-departed domain
            else                                                                     { 'Unknown' }

        # Is the hive currently loaded (user logged on)? Loaded user hives appear under HKU\<SID>.
        $isLoaded = Test-Path "Registry::HKEY_USERS\$sid"

        [pscustomobject]@{
            Sid              = $sid
            Account          = $account
            ProfileImagePath = $imagePath
            Classification   = $classification
            IsLoaded         = $isLoaded
            RawState         = $props.State
            FolderExists     = if ($imagePath) { Test-Path $imagePath } else { $false }
        }
    }
}
