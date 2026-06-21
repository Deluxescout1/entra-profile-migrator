function Test-ProfileSidMigration {
    <#
    .SYNOPSIS
        Reports any files/folders under a profile whose ACL still references a SID.
    .DESCRIPTION
        Wraps "icacls /findsid". After a migration, run it against the OLD SID: an empty
        result means every object in the tree was re-permissioned. icacls performs the
        traversal, so paths over 260 chars are handled. Covers the FILESYSTEM side only;
        registry hives are validated separately (Update-RegistryHiveSid).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^S-1-5-21-\d+-\d+-\d+-\d+$')][string]$Sid,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$ProfilePath
    )

    $out = & icacls.exe $ProfilePath /findsid $Sid /T /C /L 2>&1

    # Matching items are printed as full paths (contain ":\"); the trailing
    # "Successfully/Failed processing" summary lines do not.
    $hits = $out | Where-Object { $_ -match ':\\' -and $_ -notmatch '^\s*(Successfully|Failed) processing' }

    [pscustomobject]@{
        Sid          = $Sid
        ProfilePath  = $ProfilePath
        Clean        = (@($hits).Count -eq 0)
        RemainingAcl = @($hits)
        Raw          = ($out -join "`n")
    }
}
