<#
  Compare-ProfileSurface.ps1 - capture what a profile-migration tool changes, so you
  can diff Profwiz's surface against your own functions' surface and catch anything
  you're missing BEFORE the pilot.

  PROFILELIST (scriptable, precise):
    $before = Get-ProfileListSnapshot
    # ...run Profwiz (or your tool) on the test profile...
    $after  = Get-ProfileListSnapshot
    Compare-ProfileListSnapshot $before $after | Format-Table -Auto

  Completeness check:
    1. Snapshot -> run Profwiz -> snapshot -> save the diff as $profwiz
    2. Revert the VM snapshot
    3. Snapshot -> run YOUR functions -> snapshot -> save the diff as $mine
    4. Anything present in $profwiz.Name but not $mine.Name is a value you don't write.

  BROADER SURFACE (files + other keys): use Procmon, not this script. Filter:
    Process Name is Profwiz.exe  AND  Operation is one of
      RegSetValue, RegCreateKey, RegDeleteValue, SetSecurityFile, WriteFile, CreateFile
    Exclude SUCCESS-only reads. Watch for anything OUTSIDE these three surfaces you
    already cover: ProfileList, the profile tree's file ACLs, and the NTUSER/UsrClass
    hives. Per-user "Shell Folders", scheduled tasks, or default-user hive writes would
    be the surprises worth catching.
#>

function Get-ProfileListSnapshot {
    [CmdletBinding()]
    param()
    $base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $snap = @{}
    foreach ($child in Get-ChildItem -LiteralPath $base -ErrorAction Stop) {
        $key  = Get-Item -LiteralPath $child.PSPath
        $vals = @{}
        foreach ($n in $key.GetValueNames()) {
            $kind = $key.GetValueKind($n)
            $v    = $key.GetValue($n)
            if ($kind -eq 'Binary') { $v = -join ($v | ForEach-Object { $_.ToString('x2') }) }
            $vals[$n] = [string]$v
        }
        $snap[$child.PSChildName] = $vals
    }
    return $snap
}

function Compare-ProfileListSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Before,
        [Parameter(Mandatory)][hashtable]$After
    )
    $sids = @($Before.Keys) + @($After.Keys) | Select-Object -Unique
    foreach ($sid in $sids) {
        $b = $Before[$sid]; $a = $After[$sid]
        if ($null -eq $b) {
            [pscustomobject]@{ Sid=$sid; Change='KEY ADDED';   Name='*'; Before='';          After='(new key)' }
            continue
        }
        if ($null -eq $a) {
            [pscustomobject]@{ Sid=$sid; Change='KEY REMOVED'; Name='*'; Before='(existed)'; After='' }
            continue
        }
        $names = @($b.Keys) + @($a.Keys) | Select-Object -Unique
        foreach ($n in $names) {
            $bv = $b[$n]; $av = $a[$n]
            if ($bv -ne $av) {
                $chg = if ($null -eq $bv)     { 'VALUE ADDED'   } `
                       elseif ($null -eq $av)  { 'VALUE REMOVED' } `
                       else                    { 'VALUE CHANGED' }
                [pscustomobject]@{ Sid=$sid; Change=$chg; Name=$n; Before=$bv; After=$av }
            }
        }
    }
}
