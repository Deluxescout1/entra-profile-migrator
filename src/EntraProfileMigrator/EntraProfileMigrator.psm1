#Requires -Version 5.1
Set-StrictMode -Version Latest

# Dot-source all Private then Public function files.
$private = @( Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue )
$public  = @( Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1"  -ErrorAction SilentlyContinue )

foreach ($file in @($private + $public)) {
    try {
        . $file.FullName
    } catch {
        Write-Error "Failed to import function $($file.FullName): $_"
    }
}

Export-ModuleMember -Function $public.BaseName

# Shared module-scoped constants
$script:ProfileListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$script:ModuleRoot      = 'C:\ProgramData\EntraProfileMigrator'
# Plain string composition (not Join-Path): these are Windows runtime paths, and
# Join-Path resolves the 'C:' PSDrive at import — which throws on non-Windows hosts
# where the mocked unit tests run.
$script:LogRoot         = "$script:ModuleRoot\Logs"
$script:BackupRoot      = "$script:ModuleRoot\Backups"
