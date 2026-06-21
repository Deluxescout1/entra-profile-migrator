<#
  Build-Exe.ps1

  Produces a single self-contained EntraProfileMigrator.exe that opens the GUI.
  Run this ONCE on a Windows PC (internet needed the first time to fetch PS2EXE).
  It inlines every module function into one script and compiles it, so the
  resulting .exe needs no other files alongside it.

  There is no prebuilt .exe in the repo because this tool is PowerShell and an
  .exe can only be produced on Windows. This builds it for you.

  USAGE:
    .\tools\Build-Exe.ps1
    # -> dist\EntraProfileMigrator.exe  (double-click it; it asks for admin)
#>
[CmdletBinding()]
param(
    [string]$ModuleRoot = (Join-Path $PSScriptRoot '..\src\EntraProfileMigrator'),
    [string]$OutputDir  = (Join-Path $PSScriptRoot '..\dist'),
    [string]$ExeName    = 'EntraProfileMigrator.exe'
)

$ErrorActionPreference = 'Stop'

# --- 1. Ensure PS2EXE is available ---
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Installing PS2EXE from the PowerShell Gallery...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
        Register-PSRepository -Default -ErrorAction SilentlyContinue
    }
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe -Force

# --- 2. Inline every Private + Public function into one self-contained script ---
function Read-NoBom {
    param([string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $text
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# AUTO-GENERATED self-contained build of EntraProfileMigrator. Do not edit.')
# Script-scoped constants (mirrors EntraProfileMigrator.psm1; harmless if unused).
[void]$sb.AppendLine("`$script:ProfileListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'")
[void]$sb.AppendLine("`$script:ModuleRoot = 'C:\ProgramData\EntraProfileMigrator'")
[void]$sb.AppendLine("`$script:LogRoot = `"`$script:ModuleRoot\Logs`"")
[void]$sb.AppendLine("`$script:BackupRoot = `"`$script:ModuleRoot\Backups`"")

foreach ($dir in 'Private', 'Public') {
    $sub = Join-Path $ModuleRoot $dir
    foreach ($f in (Get-ChildItem -Path $sub -Filter *.ps1 | Sort-Object Name)) {
        [void]$sb.AppendLine("# ===== $dir\$($f.Name) =====")
        [void]$sb.AppendLine((Read-NoBom $f.FullName))
    }
}
# Entry point: open the GUI.
[void]$sb.AppendLine('Show-EntraMigrationGui')

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$combined = Join-Path $OutputDir '_EntraProfileMigrator.combined.ps1'
# Write UTF-8 *with* BOM so the compiler reads the non-ASCII characters correctly.
[System.IO.File]::WriteAllText($combined, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))

# --- 3. Compile to a single GUI .exe (STA for WinForms, manifest requests admin) ---
$exe = Join-Path $OutputDir $ExeName
Write-Host "Compiling $exe ..."
Invoke-PS2EXE -InputFile $combined -OutputFile $exe `
    -STA -NoConsole -RequireAdmin `
    -Title 'EntraProfileMigrator' -Company 'Intelos' -Product 'EntraProfileMigrator' -Version '0.1.0'

Remove-Item -LiteralPath $combined -Force -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $exe) {
    Write-Host ""
    Write-Host "Done: $exe" -ForegroundColor Green
    Write-Host "Double-click it (it will prompt for admin). Run as SYSTEM (PsExec -i -s) to migrate."
} else {
    Write-Error 'Build did not produce an .exe; see PS2EXE output above.'
    exit 1
}
