<#
  Invoke-Gate1SmokeTest.ps1
  Gate 1 pre-flight: verify the five private functions load and bind, then confirm
  -WhatIf describes the right actions without touching anything. Run this on the
  snapshotted VM before running LocalMigrationTest.ps1.

  These functions are PRIVATE (not exported by the manifest), so this script
  dot-sources the module's function files directly rather than Import-Module —
  that is the only way to reach them from this scope.

  Expected: five "OK" lines, then the WhatIf description lines with no errors.
#>

$moduleRoot = Join-Path $PSScriptRoot '..\src\EntraProfileMigrator'
foreach ($dir in 'Private', 'Public') {
    Get-ChildItem -Path (Join-Path $moduleRoot $dir) -Filter *.ps1 | ForEach-Object { . $_.FullName }
}

'Resolve-TargetSid', 'Update-RegistryHiveSid', 'Set-ProfileSidOwnership',
'Test-ProfileSidMigration', 'Update-ProfileListMapping' | ForEach-Object {
    if (Get-Command $_ -ErrorAction SilentlyContinue) { "OK   $_" } else { "MISSING  $_" }
}

$p = "$env:TEMP\epm-smoke"
New-Item -ItemType Directory -Force -Path $p | Out-Null

Update-RegistryHiveSid    -OldSid 'S-1-5-21-1-2-3-1001' -NewSid 'S-1-12-1-1-2-3-4' -ProfilePath $p -WhatIf
Set-ProfileSidOwnership   -OldSid 'S-1-5-21-1-2-3-1001' -NewSid 'S-1-12-1-1-2-3-4' -ProfilePath $p -WhatIf
Update-ProfileListMapping -OldSid 'S-1-5-21-1-2-3-1001' -NewSid 'S-1-12-1-1-2-3-4' `
    -ProfilePath $p -BackupDir $p -Provision -WhatIf

Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
