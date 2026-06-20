function Get-MigratableProfile {
    <#
    .SYNOPSIS
        Lists user profiles on this device, classified for migration. READ-ONLY.

    .DESCRIPTION
        Returns domain profiles (migration sources) and Entra profiles (potential targets),
        excluding system/service accounts. Use this to confirm what the tool sees before running
        any migration.

    .PARAMETER IncludeSystem
        Also return System/service profiles (normally hidden).

    .EXAMPLE
        Get-MigratableProfile | Format-Table Classification, Account, ProfileImagePath, IsLoaded
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeSystem
    )

    $entries = Get-ProfileListEntry

    if (-not $IncludeSystem) {
        $entries = $entries | Where-Object Classification -ne 'System'
    }

    # Annotate already-migrated profiles (marker dropped by Invoke-ProfileMigration).
    foreach ($e in $entries) {
        $marker = if ($e.ProfileImagePath) {
            Join-Path $e.ProfileImagePath '.epm-migrated'
        } else { $null }
        Add-Member -InputObject $e -NotePropertyName AlreadyMigrated `
            -NotePropertyValue ([bool]($marker -and (Test-Path $marker))) -Force
    }

    $entries
}
