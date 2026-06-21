function Test-MigrationPrerequisite {
    <#
    .SYNOPSIS
        Preflight checks for a migration. READ-ONLY. Returns a result object; does not change
        anything.

    .DESCRIPTION
        Verifies: running elevated, device is Entra-joined, target user has a minted SID, target
        is NOT currently logged on, a source domain profile exists, and the backup location is
        writable. Each check returns Pass/Fail with detail so the orchestrator (and RMM) can act.

    .PARAMETER TargetUpn
        Entra UPN to migrate to.

    .PARAMETER SourceSid
        Optional explicit source (domain) profile SID. If omitted, auto-detection is attempted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetUpn,
        [string]$SourceSid
    )

    $results = [System.Collections.Generic.List[object]]::new()
    function Add-Check([string]$Name,[bool]$Pass,[string]$Detail) {
        $results.Add([pscustomobject]@{ Check=$Name; Pass=$Pass; Detail=$Detail })
    }

    # 1. Elevation
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Add-Check 'Elevated' $isAdmin $(if($isAdmin){'Running as administrator/SYSTEM'}else{'Must run elevated'})

    # 2. Entra join state via dsregcmd
    $joined = $false; $joinDetail = 'dsregcmd unavailable'
    try {
        $ds = & dsregcmd /status 2>$null
        $joined = [bool]($ds | Select-String -SimpleMatch 'AzureAdJoined : YES')
        $joinDetail = if ($joined) { 'AzureAdJoined : YES' } else { 'Device is not Entra-joined' }
    } catch { }
    Add-Check 'EntraJoined' $joined $joinDetail

    # 3. Target SID minted (user has signed in once)
    $target = Resolve-TargetSid -TargetUpn $TargetUpn
    Add-Check 'TargetSidMinted' ([bool]$target) $(
        if($target){"SID $($target.Sid)"} else {'User has not signed in yet (no minted SID)'} )

    # 4. Target not currently logged on (hive not loaded)
    $targetLoaded = $false
    if ($target) { $targetLoaded = $target.IsLoaded }
    Add-Check 'TargetLoggedOff' (-not $targetLoaded) $(
        if($targetLoaded){'Target is logged on — log them off before migrating'}else{'Target hive not loaded'})

    # 5. A source domain profile exists
    if ($SourceSid) {
        $source = Get-ProfileListEntry | Where-Object Sid -eq $SourceSid
    } else {
        $source = Get-ProfileListEntry | Where-Object {
            $_.Classification -eq 'Domain' -and -not $_.IsLoaded
        }
    }
    Add-Check 'SourceProfileFound' ([bool]$source) $(
        if($source){ ("Source: " + (@($source).ForEach({ if($_.Account){$_.Account}else{$_.Sid} }) -join ', ')) }
        else {'No eligible domain profile found'})

    # 6. Backup location writable
    $backupOk = $false; $backupDetail = ''
    try {
        $root = 'C:\ProgramData\EntraProfileMigrator\Backups'
        if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
        $probe = Join-Path $root '.writetest'
        'x' | Set-Content -Path $probe -ErrorAction Stop
        Remove-Item $probe -ErrorAction SilentlyContinue
        $backupOk = $true; $backupDetail = $root
    } catch { $backupDetail = "Cannot write to backup root: $_" }
    Add-Check 'BackupWritable' $backupOk $backupDetail

    [pscustomobject]@{
        TargetUpn = $TargetUpn
        AllPassed = -not ($results | Where-Object { -not $_.Pass })
        Checks    = $results
    }
}
