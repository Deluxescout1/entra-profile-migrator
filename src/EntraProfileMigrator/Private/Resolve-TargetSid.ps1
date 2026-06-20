function Resolve-TargetSid {
    <#
    .SYNOPSIS
        Finds the local SID that Windows minted for an Entra user after their first sign-in.
        READ-ONLY. Returns $null if the user has not signed in on this device yet.

    .DESCRIPTION
        The Entra user's local SID does not exist until their first interactive sign-in on the
        device. This resolves a target UPN to that SID by:
          1. Matching a ProfileList entry whose account translates to AzureAD\<upn>, OR
          2. Falling back to a profile folder whose name carries the user's leaf name + tenant
             suffix (e.g. jsmith.CONTOSO) when SID translation is unavailable.

        NEVER constructs or guesses a SID. If it can't be found, the caller must send the user
        back to "sign in once".

    .PARAMETER TargetUpn
        The Entra UPN, e.g. jsmith@contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetUpn
    )

    $leaf = $TargetUpn.Split('@')[0]

    $candidates = Get-ProfileListEntry | Where-Object Classification -eq 'AzureAD'

    # Primary match: SID translates to AzureAD\<upn>.
    $match = $candidates | Where-Object { $_.Account -eq "AzureAD\$TargetUpn" }

    # Fallback: folder name matches <leaf> or <leaf>.<TENANT> (SID translation can be flaky).
    if (-not $match) {
        $match = $candidates | Where-Object {
            $_.ProfileImagePath -and
            (Split-Path $_.ProfileImagePath -Leaf) -match "^$([regex]::Escape($leaf))(\.|$)"
        }
    }

    if (-not $match) {
        Write-MigrationLog "No minted SID for '$TargetUpn' — user must sign in once with their MS account first." -Level WARN
        return $null
    }

    if (@($match).Count -gt 1) {
        Write-MigrationLog "Multiple candidate SIDs for '$TargetUpn'; refusing to guess. Resolve manually." -Level ERROR
        return $null
    }

    Write-MigrationLog "Resolved '$TargetUpn' -> SID $($match.Sid) (folder: $($match.ProfileImagePath))" -Level INFO
    return $match
}
