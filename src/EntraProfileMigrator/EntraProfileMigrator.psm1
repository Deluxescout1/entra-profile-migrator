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
$script:LogRoot         = Join-Path $script:ModuleRoot 'Logs'
$script:BackupRoot      = Join-Path $script:ModuleRoot 'Backups'
