function Get-MigrationCandidate {
    <#
    .SYNOPSIS
        Discovers user profiles on this device and proposes domain-to-Entra migration pairings.

    .DESCRIPTION
        Enumerates all profiles, then for each domain (source) profile attempts to find a
        matching Entra (target) profile by comparing username leaves. Returns a result object
        with per-candidate confidence, blocking issues, and the exact parameters to pass to
        Invoke-ProfileMigration.

        This is the READ-ONLY discovery step. Review the output first; then run
        Invoke-ProfileMigration with the TargetUpn (and SourceSid if needed).

    .PARAMETER UserLeaf
        Optional. Restrict output to candidates whose domain username matches this value
        (e.g. "jsmith"). Useful when targeting a single user on a shared device.

    .PARAMETER MappingCsv
        Optional. Path to a CSV with OldUsername and NewUpn columns. Use when the Entra UPN
        does not share the same username leaf as the old domain account (e.g. john.smith ->
        jsmith@contoso.com). Same format as deploy\mapping.sample.csv.

    .OUTPUTS
        PSCustomObject with:
          Machine, Timestamp, TotalCandidates, ReadyCount,
          Candidates[]  (SourceSid, SourceAccount, SourcePath, SourceLoaded, AlreadyMigrated,
                         TargetSid, TargetUpn, TargetPath, TargetLoaded,
                         MatchConfidence, MatchReason, ReadyToMigrate, BlockingIssues[]),
          UnpairedEntra[]

    .EXAMPLE
        Get-MigrationCandidate | ConvertTo-Json -Depth 6

    .EXAMPLE
        Get-MigrationCandidate -UserLeaf jsmith
    #>
    [CmdletBinding()]
    param(
        [string]$UserLeaf,
        [string]$MappingCsv
    )

    # Load optional name mapping: OldUsername (sAMAccountName or UPN prefix) -> NewUpn
    $nameMap = @{}
    if ($MappingCsv -and (Test-Path -LiteralPath $MappingCsv)) {
        Import-Csv -Path $MappingCsv | ForEach-Object {
            if ($_.OldUsername -and $_.NewUpn) {
                $nameMap[$_.OldUsername.Trim().ToLower()] = $_.NewUpn.Trim()
            }
        }
        Write-MigrationLog "Loaded $($nameMap.Count) name mapping(s) from $MappingCsv" -Level INFO
    }

    $all            = Get-MigratableProfile
    $domainProfiles = @($all | Where-Object Classification -eq 'Domain')
    $entraProfiles  = @($all | Where-Object Classification -eq 'AzureAD')

    Write-MigrationLog "Discovery: $($domainProfiles.Count) domain profile(s), $($entraProfiles.Count) Entra profile(s)" -Level INFO

    $candidates    = [System.Collections.Generic.List[object]]::new()
    $usedEntraSids = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($src in $domainProfiles) {

        # --- Extract the sAMAccountName leaf from the domain profile ---
        $srcLeaf = $null
        if ($src.Account -and $src.Account -match '\\(.+)$') {
            $srcLeaf = $Matches[1].ToLower()
        }
        if (-not $srcLeaf -and $src.ProfileImagePath) {
            $srcLeaf = (Split-Path $src.ProfileImagePath -Leaf).ToLower()
        }
        if (-not $srcLeaf) {
            Write-MigrationLog "Could not determine username for SID $($src.Sid); skipping." -Level WARN
            continue
        }
        if ($UserLeaf -and $srcLeaf -ne $UserLeaf.ToLower()) { continue }

        # --- Resolve the expected Entra UPN ---
        $mappedUpn = if ($nameMap.ContainsKey($srcLeaf)) { $nameMap[$srcLeaf] } else { $null }

        # --- Match against available Entra profiles ---
        $entraMatch  = $null
        $confidence  = 'None'
        $matchReason = 'No Entra profile found — user must sign in once with their Microsoft account'

        if ($mappedUpn) {
            # CSV-driven: find the Entra profile for the explicit target UPN
            $upnLeaf = $mappedUpn.Split('@')[0].ToLower()
            $entraMatch = $entraProfiles | Where-Object {
                ($_.Account -eq "AzureAD\$mappedUpn") -or
                ($_.ProfileImagePath -and
                 (Split-Path $_.ProfileImagePath -Leaf).ToLower() -match "^$([regex]::Escape($upnLeaf))(\.|$)")
            } | Select-Object -First 1

            if ($entraMatch) {
                $confidence  = 'High'
                $matchReason = "CSV mapping: $srcLeaf -> $mappedUpn"
            }
            else {
                $matchReason = "CSV maps $srcLeaf -> $mappedUpn but that Entra profile has not been created yet"
            }
        }
        else {
            # Auto-match: compare username leaves derived from account name and folder path
            $getEntraLeaf = {
                param($e)
                # Prefer the UPN prefix from the translated account name
                if ($e.Account -match '^AzureAD\\([^@]+)@') { return $Matches[1].ToLower() }
                # Fallback: profile folder minus any ".TENANT" suffix
                if ($e.ProfileImagePath) {
                    return ((Split-Path $e.ProfileImagePath -Leaf).ToLower() -split '\.')[0]
                }
                return $null
            }

            $acctMatches   = @($entraProfiles | Where-Object { (& $getEntraLeaf $_) -eq $srcLeaf })
            $folderMatches = @($entraProfiles | Where-Object {
                $_.ProfileImagePath -and
                ((Split-Path $_.ProfileImagePath -Leaf).ToLower() -eq $srcLeaf -or
                 (Split-Path $_.ProfileImagePath -Leaf).ToLower() -like "$srcLeaf.*")
            })

            $acctCount   = @($acctMatches).Count
            $folderCount = @($folderMatches).Count

            if ($acctCount -eq 1 -and $folderCount -ge 1 -and
                $acctMatches[0].Sid -eq $folderMatches[0].Sid) {
                $entraMatch  = $acctMatches[0]
                $confidence  = 'High'
                $matchReason = "Account name ($srcLeaf) and profile folder both match"
            }
            elseif ($acctCount -eq 1) {
                $entraMatch  = $acctMatches[0]
                $confidence  = 'Medium'
                $matchReason = "Account name ($srcLeaf) matches; folder name differs (verify manually)"
            }
            elseif ($folderCount -eq 1) {
                $entraMatch  = $folderMatches[0]
                $confidence  = 'Medium'
                $matchReason = "Profile folder matches $srcLeaf.*; account name differs (SID translation may be partial)"
            }
            elseif ($acctCount -gt 1 -or $folderCount -gt 1) {
                $confidence  = 'Low'
                $matchReason = "Multiple Entra profiles matched — pass -SourceSid and -TargetUpn explicitly to Invoke-ProfileMigration"
            }
        }

        if ($entraMatch) { $null = $usedEntraSids.Add($entraMatch.Sid) }

        # --- Blocking issues ---
        $blocking = [System.Collections.Generic.List[string]]::new()
        if ($src.IsLoaded)          { $blocking.Add('Source profile is loaded — user must log off before migrating') }
        if ($src.AlreadyMigrated)   { $blocking.Add('Already migrated (.epm-migrated marker present) — nothing to do') }
        if (-not $src.FolderExists) { $blocking.Add("Source profile folder not found: $($src.ProfileImagePath)") }
        if ($confidence -eq 'None') { $blocking.Add('No Entra profile found — user must sign in once with their Microsoft account first') }
        if ($confidence -eq 'Low')  { $blocking.Add('Ambiguous match — specify SourceSid and TargetUpn explicitly') }
        if ($entraMatch -and $entraMatch.IsLoaded) {
            $blocking.Add('Target (Entra) profile is currently loaded — user must log off')
        }

        $targetUpn = if ($mappedUpn) {
            $mappedUpn
        } elseif ($entraMatch -and $entraMatch.Account -match '^AzureAD\\(.+)$') {
            $Matches[1]
        } else { $null }

        $candidates.Add([pscustomobject]@{
            SourceSid       = $src.Sid
            SourceAccount   = $(if ($src.Account) { $src.Account } else { "(unresolved — domain gone)" })
            SourcePath      = $src.ProfileImagePath
            SourceLoaded    = $src.IsLoaded
            AlreadyMigrated = $src.AlreadyMigrated
            TargetSid       = $(if ($entraMatch) { $entraMatch.Sid }            else { $null })
            TargetUpn       = $targetUpn
            TargetPath      = $(if ($entraMatch) { $entraMatch.ProfileImagePath } else { $null })
            TargetLoaded    = $(if ($entraMatch) { $entraMatch.IsLoaded }         else { $null })
            MatchConfidence = $confidence
            MatchReason     = $matchReason
            ReadyToMigrate  = ($blocking.Count -eq 0)
            BlockingIssues  = $blocking.ToArray()
        })

        Write-MigrationLog ("Candidate: {0} -> {1} [{2}]{3}" -f
            $src.Account, $(if ($targetUpn) { $targetUpn } else { '(no target)' }),
            $confidence, $(if ($blocking.Count) { ' BLOCKED' } else { '' })) -Level INFO
    }

    $unpairedEntra = @($entraProfiles | Where-Object { -not $usedEntraSids.Contains($_.Sid) })

    [pscustomobject]@{
        Machine         = $env:COMPUTERNAME
        Timestamp       = (Get-Date -Format 'o')
        TotalCandidates = $candidates.Count
        ReadyCount      = @($candidates | Where-Object ReadyToMigrate).Count
        Candidates      = $candidates.ToArray()
        UnpairedEntra   = $unpairedEntra
    }
}
