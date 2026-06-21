<#
    EntraProfileMigrator.Tests.ps1  —  Pester v5

    Unit tests:  Windows PowerShell 5.1+ / 7+. They mock Windows APIs and binaries
                 (reg.exe, icacls.exe) and use C:\ paths, so they need a Windows host
                 but perform no real mutation. CI runs them on 5.1 and 7.
    Integration: tagged RequiresWindows. Run on a snapshotted Win11 VM only.
                 These tests mutate the registry and filesystem — VM snapshot is the rollback.
#>

BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..\src\EntraProfileMigrator\EntraProfileMigrator.psd1'
    Import-Module (Resolve-Path $manifest) -Force

    # Helpers used across multiple Describe blocks
    function New-FakeProfile {
        param($Sid, $Account, $Path, $Classification, [switch]$IsLoaded, [switch]$AlreadyMigrated)
        [pscustomobject]@{
            Sid              = $Sid
            Account          = $Account
            ProfileImagePath = $Path
            Classification   = $Classification
            IsLoaded         = [bool]$IsLoaded
            FolderExists     = $true
            AlreadyMigrated  = [bool]$AlreadyMigrated
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Module surface' {
    It 'exports the expected public functions' {
        $exported = (Get-Command -Module EntraProfileMigrator).Name | Sort-Object
        'Get-MigratableProfile'    | Should -BeIn $exported
        'Get-MigrationCandidate'   | Should -BeIn $exported
        'Test-MigrationPrerequisite' | Should -BeIn $exported
        'Invoke-ProfileMigration'  | Should -BeIn $exported
        'Restore-MigrationBackup'  | Should -BeIn $exported
        'Show-EntraMigrationGui'   | Should -BeIn $exported
    }
}

# ---------------------------------------------------------------------------
Describe 'Resolve-TargetSid' {
    BeforeAll {
        Mock -ModuleName EntraProfileMigrator Write-MigrationLog { }
    }

    It 'returns $null when no AzureAD profiles exist' {
        Mock -ModuleName EntraProfileMigrator Get-ProfileListEntry {
            @( New-FakeProfile 'S-1-5-21-1-2-3-1001' 'DOMAIN\jsmith' 'C:\Users\jsmith' 'Domain' )
        }
        InModuleScope EntraProfileMigrator {
            Resolve-TargetSid -TargetUpn 'jsmith@contoso.com' | Should -BeNullOrEmpty
        }
    }

    It 'returns the matching profile when exactly one AzureAD entry matches the UPN' {
        Mock -ModuleName EntraProfileMigrator Get-ProfileListEntry {
            @(
                New-FakeProfile 'S-1-5-21-1-2-3-1001' 'DOMAIN\jsmith'             'C:\Users\jsmith'         'Domain'
                New-FakeProfile 'S-1-12-1-111-222-333-444' 'AzureAD\jsmith@contoso.com' 'C:\Users\jsmith.CONTOSO' 'AzureAD'
            )
        }
        InModuleScope EntraProfileMigrator {
            $result = Resolve-TargetSid -TargetUpn 'jsmith@contoso.com'
            $result              | Should -Not -BeNullOrEmpty
            $result.Sid          | Should -Be 'S-1-12-1-111-222-333-444'
            $result.Account      | Should -Be 'AzureAD\jsmith@contoso.com'
        }
    }

    It 'returns $null and logs an error when multiple AzureAD profiles match' {
        Mock -ModuleName EntraProfileMigrator Get-ProfileListEntry {
            @(
                New-FakeProfile 'S-1-12-1-1' 'AzureAD\jsmith@contoso.com' 'C:\Users\jsmith.A' 'AzureAD'
                New-FakeProfile 'S-1-12-1-2' 'AzureAD\jsmith@contoso.com' 'C:\Users\jsmith.B' 'AzureAD'
            )
        }
        InModuleScope EntraProfileMigrator {
            Resolve-TargetSid -TargetUpn 'jsmith@contoso.com' | Should -BeNullOrEmpty
        }
    }

    It 'falls back to folder-name matching when SID account translation is unavailable' {
        Mock -ModuleName EntraProfileMigrator Get-ProfileListEntry {
            @(
                New-FakeProfile 'S-1-12-1-111-222-333-444' $null 'C:\Users\jsmith.CONTOSO' 'AzureAD'
            )
        }
        InModuleScope EntraProfileMigrator {
            $result = Resolve-TargetSid -TargetUpn 'jsmith@contoso.com'
            $result.Sid | Should -Be 'S-1-12-1-111-222-333-444'
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-ProfileListEntry' {
    BeforeAll {
        Mock -ModuleName EntraProfileMigrator Write-MigrationLog { }
        Mock -ModuleName EntraProfileMigrator Get-ChildItem {
            $base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
            @(
                [pscustomobject]@{ PSChildName = 'S-1-5-18';                PSPath = "$base\S-1-5-18" }
                [pscustomobject]@{ PSChildName = 'S-1-5-21-1-2-3-1001';     PSPath = "$base\S-1-5-21-1-2-3-1001" }
                [pscustomobject]@{ PSChildName = 'S-1-5-21-1-2-3-1001.bak'; PSPath = "$base\S-1-5-21-1-2-3-1001.bak" }
            )
        }
        Mock -ModuleName EntraProfileMigrator Get-ItemProperty {
            $leaf = ($Path -split '\\')[-1]
            if ($leaf -eq 'S-1-5-18') {
                [pscustomobject]@{ ProfileImagePath = 'C:\Windows\system32\config\systemprofile'; State = 0 }
            } else {
                [pscustomobject]@{ ProfileImagePath = 'C:\Users\jsmith'; State = 0 }
            }
        }
        # Default: nothing loaded, no folders present. Individual tests override as needed.
        Mock -ModuleName EntraProfileMigrator Test-Path { $false }
    }

    It 'skips .bak shadow keys and warns about them' {
        $sids = InModuleScope EntraProfileMigrator { (Get-ProfileListEntry).Sid }
        $sids | Should -Not -Contain 'S-1-5-21-1-2-3-1001.bak'
        Should -Invoke Write-MigrationLog -ModuleName EntraProfileMigrator `
            -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*.bak*' }
    }

    It 'classifies well-known SIDs (S-1-5-18) as System' {
        $c = InModuleScope EntraProfileMigrator {
            (Get-ProfileListEntry | Where-Object Sid -eq 'S-1-5-18').Classification
        }
        $c | Should -Be 'System'
    }

    It 'classifies an unresolved S-1-5-21 SID as Domain with a null account' {
        $d = InModuleScope EntraProfileMigrator {
            Get-ProfileListEntry | Where-Object Sid -eq 'S-1-5-21-1-2-3-1001'
        }
        $d.Classification | Should -Be 'Domain'
        $d.Account        | Should -BeNullOrEmpty
    }

    It 'classifies an Entra (S-1-12-1) SID as AzureAD even when translation fails' {
        # Regression guard: Entra SIDs are S-1-12-1 (not S-1-5-21). They must NOT fall through
        # to the "non-user authority => System" branch, or the tool can never find a target.
        Mock -ModuleName EntraProfileMigrator Get-ChildItem {
            $base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
            @( [pscustomobject]@{ PSChildName = 'S-1-12-1-111-222-333-444'; PSPath = "$base\S-1-12-1-111-222-333-444" } )
        }
        $cls = InModuleScope EntraProfileMigrator {
            (Get-ProfileListEntry | Where-Object Sid -eq 'S-1-12-1-111-222-333-444').Classification
        }
        $cls | Should -Be 'AzureAD'
    }

    It 'reports IsLoaded = $true when the hive is mounted under HKEY_USERS' {
        Mock -ModuleName EntraProfileMigrator Test-Path { $Path -like '*HKEY_USERS\S-1-5-21-1-2-3-1001' }
        $loaded = InModuleScope EntraProfileMigrator {
            (Get-ProfileListEntry | Where-Object Sid -eq 'S-1-5-21-1-2-3-1001').IsLoaded
        }
        $loaded | Should -BeTrue
    }

    It 'reports FolderExists from the profile path on disk' {
        Mock -ModuleName EntraProfileMigrator Test-Path { $Path -eq 'C:\Users\jsmith' }
        $exists = InModuleScope EntraProfileMigrator {
            (Get-ProfileListEntry | Where-Object Sid -eq 'S-1-5-21-1-2-3-1001').FolderExists
        }
        $exists | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-MigratableProfile' {
    BeforeAll {
        Mock -ModuleName EntraProfileMigrator Write-MigrationLog { }
        Mock -ModuleName EntraProfileMigrator Get-ProfileListEntry {
            @(
                New-FakeProfile 'S-1-5-18'               $null              $null              'System'
                New-FakeProfile 'S-1-5-21-1-2-3-1001'    'DOMAIN\jsmith'    'C:\Users\jsmith'  'Domain'
                New-FakeProfile 'S-1-12-1-111-222-333-444' 'AzureAD\jsmith@contoso.com' 'C:\Users\jsmith.CONTOSO' 'AzureAD'
            )
        }
        Mock -ModuleName EntraProfileMigrator Test-Path { $false }
    }

    It 'excludes System profiles by default' {
        $result = Get-MigratableProfile
        $result.Classification | Should -Not -Contain 'System'
    }

    It 'includes System profiles with -IncludeSystem' {
        $result = Get-MigratableProfile -IncludeSystem
        $result.Classification | Should -Contain 'System'
    }

    It 'marks profiles with .epm-migrated as AlreadyMigrated' {
        Mock -ModuleName EntraProfileMigrator Test-Path {
            $Path -like '*\.epm-migrated'
        }
        $result = Get-MigratableProfile
        ($result | Where-Object ProfileImagePath -eq 'C:\Users\jsmith').AlreadyMigrated | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-MigrationCandidate' {
    BeforeAll {
        Mock -ModuleName EntraProfileMigrator Write-MigrationLog { }
    }

    Context 'High confidence — account name and folder both match' {
        BeforeAll {
            Mock -ModuleName EntraProfileMigrator Get-MigratableProfile {
                @(
                    New-FakeProfile 'S-1-5-21-1-2-3-1001'      'DOMAIN\jsmith'             'C:\Users\jsmith'          'Domain'
                    New-FakeProfile 'S-1-12-1-111-222-333-444'  'AzureAD\jsmith@contoso.com' 'C:\Users\jsmith.CONTOSO'  'AzureAD'
                )
            }
        }

        It 'pairs the profiles and reports High confidence' {
            $report = Get-MigrationCandidate
            $report.Candidates.Count   | Should -Be 1
            $c = $report.Candidates[0]
            $c.MatchConfidence | Should -Be 'High'
            $c.TargetUpn       | Should -Be 'jsmith@contoso.com'
            $c.SourceSid       | Should -Be 'S-1-5-21-1-2-3-1001'
        }

        It 'reports ReadyToMigrate = true when no blocking issues' {
            $report = Get-MigrationCandidate
            $report.Candidates[0].ReadyToMigrate | Should -BeTrue
            $report.ReadyCount | Should -Be 1
        }
    }

    Context 'Blocking — source profile is loaded' {
        BeforeAll {
            Mock -ModuleName EntraProfileMigrator Get-MigratableProfile {
                @(
                    New-FakeProfile 'S-1-5-21-1-2-3-1001'     'DOMAIN\jsmith'              'C:\Users\jsmith'         'Domain' -IsLoaded
                    New-FakeProfile 'S-1-12-1-111-222-333-444' 'AzureAD\jsmith@contoso.com' 'C:\Users\jsmith.CONTOSO' 'AzureAD'
                )
            }
        }

        It 'sets ReadyToMigrate = false and lists a blocking issue' {
            $c = (Get-MigrationCandidate).Candidates[0]
            $c.ReadyToMigrate  | Should -BeFalse
            $c.BlockingIssues  | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Confidence None — no Entra profile yet' {
        BeforeAll {
            Mock -ModuleName EntraProfileMigrator Get-MigratableProfile {
                @(
                    New-FakeProfile 'S-1-5-21-1-2-3-1001' 'DOMAIN\jsmith' 'C:\Users\jsmith' 'Domain'
                )
            }
        }

        It 'reports MatchConfidence = None and ReadyToMigrate = false' {
            $c = (Get-MigrationCandidate).Candidates[0]
            $c.MatchConfidence | Should -Be 'None'
            $c.ReadyToMigrate  | Should -BeFalse
        }
    }

    Context 'Ambiguous — multiple Entra profiles match' {
        BeforeAll {
            Mock -ModuleName EntraProfileMigrator Get-MigratableProfile {
                @(
                    New-FakeProfile 'S-1-5-21-1-2-3-1001' 'DOMAIN\jsmith'               'C:\Users\jsmith'   'Domain'
                    New-FakeProfile 'S-1-12-1-1'           'AzureAD\jsmith@contoso.com'  'C:\Users\jsmith.A' 'AzureAD'
                    New-FakeProfile 'S-1-12-1-2'           'AzureAD\jsmith@contoso.com'  'C:\Users\jsmith.B' 'AzureAD'
                )
            }
        }

        It 'reports MatchConfidence = Low and blocks' {
            $c = (Get-MigrationCandidate).Candidates[0]
            $c.MatchConfidence | Should -Be 'Low'
            $c.ReadyToMigrate  | Should -BeFalse
        }
    }

    It 'filters to the requested UserLeaf' {
        Mock -ModuleName EntraProfileMigrator Get-MigratableProfile {
            @(
                New-FakeProfile 'S-1-5-21-1-2-3-1001' 'DOMAIN\jsmith' 'C:\Users\jsmith' 'Domain'
                New-FakeProfile 'S-1-5-21-1-2-3-1002' 'DOMAIN\adoe'   'C:\Users\adoe'   'Domain'
            )
        }
        $report = Get-MigrationCandidate -UserLeaf 'adoe'
        $report.Candidates.Count | Should -Be 1
        $report.Candidates[0].SourceAccount | Should -BeLike '*adoe*'
    }
}

# ---------------------------------------------------------------------------
Describe 'Update-ProfileListMapping' {
    BeforeAll {
        Mock -ModuleName EntraProfileMigrator Write-MigrationLog { }
        Mock -ModuleName EntraProfileMigrator reg.exe { }
        Mock -ModuleName EntraProfileMigrator New-Item     { [pscustomobject]@{} }
        Mock -ModuleName EntraProfileMigrator Set-ItemProperty { }
        Mock -ModuleName EntraProfileMigrator Remove-Item  { }
        Mock -ModuleName EntraProfileMigrator Rename-Item  { }
        Mock -ModuleName EntraProfileMigrator Get-ChildItem { @() }
        Mock -ModuleName EntraProfileMigrator Get-Item     {
            $m = [pscustomobject]@{}
            $m | Add-Member -MemberType ScriptMethod -Name GetValueKind -Value { 'String' }
            $m
        }
        Mock -ModuleName EntraProfileMigrator Get-ItemProperty {
            [pscustomobject]@{ ProfileImagePath = 'C:\Users\old.CONTOSO' }
        }
        # Backup directory exists; new SID key does NOT exist by default
        Mock -ModuleName EntraProfileMigrator Convert-Path { $Path }
    }

    It 'throws without -Provision when the new SID key does not exist' {
        Mock -ModuleName EntraProfileMigrator Test-Path {
            # BackupDir exists, new SID key does NOT
            if ($LiteralPath -like '*ProfileList*') { $false } else { $true }
        }
        InModuleScope EntraProfileMigrator {
            {
                Update-ProfileListMapping -OldSid 'S-1-5-21-1-2-3-1001' `
                    -NewSid 'S-1-12-1-1-2-3-4' `
                    -ProfilePath 'C:\Users\jsmith' `
                    -BackupDir   'C:\ProgramData\EPM\backup'
            } | Should -Throw '*Provision*'
        }
    }

    It 'does not write any registry values under -WhatIf' {
        Mock -ModuleName EntraProfileMigrator Test-Path { $true }
        InModuleScope EntraProfileMigrator {
            Update-ProfileListMapping -OldSid 'S-1-5-21-1-2-3-1001' `
                -NewSid 'S-1-12-1-1-2-3-4' `
                -ProfilePath 'C:\Users\jsmith' `
                -BackupDir   'C:\ProgramData\EPM\backup' `
                -WhatIf
        }
        Should -Invoke Set-ItemProperty -ModuleName EntraProfileMigrator -Times 0
        Should -Invoke New-Item         -ModuleName EntraProfileMigrator -Times 0
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-MigrationPrerequisite' {
    BeforeAll {
        Mock -ModuleName EntraProfileMigrator Write-MigrationLog { }
    }

    It 'passes the SID/source checks when the target resolves, is logged off, and a domain source exists' {
        Mock -ModuleName EntraProfileMigrator Resolve-TargetSid {
            New-FakeProfile 'S-1-12-1-1' 'AzureAD\jsmith@contoso.com' 'C:\Users\jsmith.CONTOSO' 'AzureAD'
        }
        Mock -ModuleName EntraProfileMigrator Get-ProfileListEntry {
            @( New-FakeProfile 'S-1-5-21-1-2-3-1001' 'DOMAIN\jsmith' 'C:\Users\jsmith' 'Domain' )
        }
        $r = Test-MigrationPrerequisite -TargetUpn 'jsmith@contoso.com'
        ($r.Checks | Where-Object Check -eq 'TargetSidMinted').Pass    | Should -BeTrue
        ($r.Checks | Where-Object Check -eq 'TargetLoggedOff').Pass    | Should -BeTrue
        ($r.Checks | Where-Object Check -eq 'SourceProfileFound').Pass | Should -BeTrue
    }

    It 'fails TargetSidMinted (and AllPassed) when the user has not signed in yet' {
        Mock -ModuleName EntraProfileMigrator Resolve-TargetSid { $null }
        Mock -ModuleName EntraProfileMigrator Get-ProfileListEntry {
            @( New-FakeProfile 'S-1-5-21-1-2-3-1001' 'DOMAIN\jsmith' 'C:\Users\jsmith' 'Domain' )
        }
        $r = Test-MigrationPrerequisite -TargetUpn 'jsmith@contoso.com'
        ($r.Checks | Where-Object Check -eq 'TargetSidMinted').Pass | Should -BeFalse
        $r.AllPassed | Should -BeFalse
    }

    It 'fails TargetLoggedOff when the target hive is already loaded' {
        Mock -ModuleName EntraProfileMigrator Resolve-TargetSid {
            New-FakeProfile 'S-1-12-1-1' 'AzureAD\jsmith@contoso.com' 'C:\Users\jsmith.CONTOSO' 'AzureAD' -IsLoaded
        }
        Mock -ModuleName EntraProfileMigrator Get-ProfileListEntry { @() }
        $r = Test-MigrationPrerequisite -TargetUpn 'jsmith@contoso.com'
        ($r.Checks | Where-Object Check -eq 'TargetLoggedOff').Pass | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
Describe 'Invoke-ProfileMigration' {
    BeforeAll {
        Mock -ModuleName EntraProfileMigrator Write-MigrationLog { }
    }

    It 'returns ExitCode 10 (dry-run) when called without -Execute' {
        Mock -ModuleName EntraProfileMigrator Test-MigrationPrerequisite {
            [pscustomobject]@{
                AllPassed = $true
                Checks    = @(
                    [pscustomobject]@{ Check = 'TargetSidMinted'; Pass = $true; Detail = 'S-1-12-1-1' }
                )
            }
        }
        Mock -ModuleName EntraProfileMigrator Resolve-TargetSid {
            New-FakeProfile 'S-1-12-1-1' 'AzureAD\jsmith@contoso.com' 'C:\Users\jsmith.CONTOSO' 'AzureAD'
        }
        Mock -ModuleName EntraProfileMigrator Get-ProfileListEntry {
            @( New-FakeProfile 'S-1-5-21-1-2-3-1001' 'DOMAIN\jsmith' 'C:\Users\jsmith' 'Domain' )
        }
        Mock -ModuleName EntraProfileMigrator Test-Path { $false }

        $result = Invoke-ProfileMigration -TargetUpn 'jsmith@contoso.com'
        $result.ExitCode | Should -Be 10
        $result.Success  | Should -BeTrue
    }

    It 'returns ExitCode 40 when the target SID has not been minted yet' {
        Mock -ModuleName EntraProfileMigrator Test-MigrationPrerequisite {
            [pscustomobject]@{
                AllPassed = $false
                Checks    = @(
                    [pscustomobject]@{ Check = 'TargetSidMinted'; Pass = $false; Detail = 'No minted SID' }
                )
            }
        }
        $result = Invoke-ProfileMigration -TargetUpn 'jsmith@contoso.com'
        $result.ExitCode | Should -Be 40
        $result.Success  | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
Describe 'Compare-ProfileListSnapshot' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\tools\Compare-ProfileSurface.ps1')
    }

    It 'reports KEY ADDED when a SID appears only in After' {
        $before = @{ 'S-1-5-21-1-2-3-1001' = @{ ProfileImagePath = 'C:\Users\old' } }
        $after  = @{
            'S-1-5-21-1-2-3-1001' = @{ ProfileImagePath = 'C:\Users\old' }
            'S-1-12-1-111-222-333-444' = @{ ProfileImagePath = 'C:\Users\new' }
        }
        $diff = Compare-ProfileListSnapshot -Before $before -After $after
        ($diff | Where-Object Change -eq 'KEY ADDED').Sid | Should -Be 'S-1-12-1-111-222-333-444'
    }

    It 'reports KEY REMOVED when a SID appears only in Before' {
        $before = @{
            'S-1-5-21-1-2-3-1001'    = @{ ProfileImagePath = 'C:\Users\old' }
            'S-1-5-21-1-2-3-9999'    = @{ ProfileImagePath = 'C:\Users\gone' }
        }
        $after  = @{ 'S-1-5-21-1-2-3-1001' = @{ ProfileImagePath = 'C:\Users\old' } }
        $diff = Compare-ProfileListSnapshot -Before $before -After $after
        ($diff | Where-Object Change -eq 'KEY REMOVED').Sid | Should -Be 'S-1-5-21-1-2-3-9999'
    }

    It 'reports VALUE CHANGED for ProfileImagePath repoint' {
        $before = @{ 'S-1-12-1-1' = @{ ProfileImagePath = 'C:\Users\jsmith.CONTOSO'; State = '0' } }
        $after  = @{ 'S-1-12-1-1' = @{ ProfileImagePath = 'C:\Users\jsmith';         State = '0' } }
        $diff = Compare-ProfileListSnapshot -Before $before -After $after
        $row = $diff | Where-Object { $_.Change -eq 'VALUE CHANGED' -and $_.Name -eq 'ProfileImagePath' }
        $row        | Should -Not -BeNullOrEmpty
        $row.Before | Should -Be 'C:\Users\jsmith.CONTOSO'
        $row.After  | Should -Be 'C:\Users\jsmith'
    }

    It 'returns no output when snapshots are identical' {
        $snap = @{ 'S-1-5-21-1-2-3-1001' = @{ ProfileImagePath = 'C:\Users\jsmith'; State = '0' } }
        Compare-ProfileListSnapshot -Before $snap -After $snap | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Restore-MigrationBackup' -Tag 'Integration', 'RequiresWindows' -Skip:(-not $IsWindows) {
    It 'throws when manifest.json is missing' {
        $empty = Join-Path $TestDrive 'empty-backup'
        New-Item -ItemType Directory -Path $empty | Out-Null
        { Restore-MigrationBackup -BackupPath $empty } | Should -Throw '*manifest.json*'
    }

    It 'warns on machine name mismatch without throwing' {
        $dir = Join-Path $TestDrive 'mismatch-backup'
        New-Item -ItemType Directory -Path $dir | Out-Null
        @{
            timestamp  = '20260101_000000'
            sourceSid  = 'S-1-5-21-1-2-3-1001'
            targetSid  = 'S-1-12-1-1'
            sourcePath = 'C:\Users\jsmith'
            machine    = 'DIFFERENT-MACHINE'
        } | ConvertTo-Json | Set-Content (Join-Path $dir 'manifest.json')
        { Restore-MigrationBackup -BackupPath $dir -WhatIf } | Should -Not -Throw
    }
}

Describe 'Update-RegistryHiveSid' -Tag 'Integration', 'RequiresWindows' -Skip:(-not $IsWindows) {
    It 'skips gracefully when NTUSER.DAT does not exist' {
        $dir = Join-Path $TestDrive 'empty-profile'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Mock -ModuleName EntraProfileMigrator Write-MigrationLog { }
        InModuleScope EntraProfileMigrator {
            { Update-RegistryHiveSid -ProfilePath $using:dir `
                -OldSid 'S-1-5-21-1-2-3-1001' -NewSid 'S-1-5-21-1-2-3-1002' } |
            Should -Not -Throw
        }
    }
}

Describe 'Set-ProfileSidOwnership' -Tag 'Integration', 'RequiresWindows' -Skip:(-not $IsWindows) {
    It 'throws before touching anything when the ACL backup is empty' {
        $dir     = Join-Path $TestDrive 'profile'
        $aclFile = Join-Path $TestDrive 'empty.bak'
        New-Item -ItemType Directory -Path $dir | Out-Null
        New-Item -ItemType File -Path $aclFile  | Out-Null  # zero bytes
        InModuleScope EntraProfileMigrator {
            {
                Set-ProfileSidOwnership -OldSid 'S-1-5-21-1-2-3-1001' `
                    -NewSid 'S-1-5-21-1-2-3-1002' `
                    -ProfilePath  $using:dir `
                    -AclBackupPath $using:aclFile
            } | Should -Throw '*empty*'
        }
    }
}

Describe 'New-MigrationBackup' -Tag 'Integration', 'RequiresWindows' -Skip:(-not $IsWindows) {
    It 'writes manifest.json, fs-acl.txt, profilelist.reg, and ROLLBACK.txt' {
        $profile = Join-Path $TestDrive 'profile'
        New-Item -ItemType Directory -Path $profile | Out-Null
        Mock -ModuleName EntraProfileMigrator Write-MigrationLog { }

        InModuleScope EntraProfileMigrator {
            $backup = New-MigrationBackup `
                -SourceSid   'S-1-5-21-1-2-3-1001' `
                -TargetSid   'S-1-12-1-111-222-333-444' `
                -SourcePath  $using:profile `
                -Mode        'inplace'

            $backup              | Should -Not -BeNullOrEmpty
            "$backup\manifest.json"   | Should -Exist
            "$backup\profilelist.reg" | Should -Exist
            "$backup\ROLLBACK.txt"    | Should -Exist
            $m = Get-Content "$backup\manifest.json" | ConvertFrom-Json
            $m.sourceSid  | Should -Be 'S-1-5-21-1-2-3-1001'
            $m.targetSid  | Should -Be 'S-1-12-1-111-222-333-444'
        }
    }
}
