<#
  EntraProfileMigrator-GUI.ps1

  Launches the migration GUI. Imports the module and calls Show-EntraMigrationGui.
  WinForms requires an STA thread; if this is started on an MTA thread (PowerShell 7
  can default to MTA) it relaunches itself under Windows PowerShell with -Sta.

  Run elevated (ideally as SYSTEM via PsExec -i -s) to actually migrate.
#>
[CmdletBinding()]
param(
    [string]$ModulePath = (Join-Path $PSScriptRoot '..\src\EntraProfileMigrator\EntraProfileMigrator.psd1')
)

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    # WinForms needs STA. Relaunch under Windows PowerShell (always present, -Sta supported).
    & powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File $PSCommandPath -ModulePath $ModulePath
    return
}

Import-Module $ModulePath -Force
Show-EntraMigrationGui
