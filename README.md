# EntraProfileMigrator

In-house replacement for ForensiT User Profile Wizard, scoped to **on-prem AD (domain-joined) →
Entra ID (cloud-only) joined** profile migrations. PowerShell module, deployable via NinjaOne /
Rewst. After migration the user signs in with their Microsoft account and lands in their existing
profile — data, Outlook cache, browser profiles and app settings intact.

> ⚠️ This tool re-permissions profiles and rewrites the `ProfileList` registry. It is destructive
> to ACLs. **Test in a disposable Windows 11 VM with a checkpoint. Never first-run on a client
> machine. Always have a separate full backup.**

## How it works (short version)
1. Device is Entra-joined (Autopilot / provisioning package — separate from this tool).
2. The user signs in **once** with their MS account → Windows mints their local SID.
3. This tool re-points that SID at the existing profile and discards the throwaway one.
4. Reboot → done.

See `docs/DESIGN.md` (architecture + the SID-timing constraint), `docs/MIGRATION-FLOW.md`
(runbook), `docs/DEPLOYMENT.md` (NinjaOne/Rewst).

## Quick start (in a test VM, elevated)
```powershell
Import-Module .\src\EntraProfileMigrator\EntraProfileMigrator.psd1 -Force

# See what the tool sees (read-only)
Get-MigratableProfile | Format-Table Classification, Account, ProfileImagePath, IsLoaded, AlreadyMigrated

# Preflight (read-only)
Test-MigrationPrerequisite -TargetUpn jsmith@contoso.com

# Dry run (changes nothing)
Invoke-ProfileMigration -TargetUpn jsmith@contoso.com

# Execute
Invoke-ProfileMigration -TargetUpn jsmith@contoso.com -Execute

# Roll back if needed
Restore-MigrationBackup -BackupPath 'C:\ProgramData\EntraProfileMigrator\Backups\<timestamp>'
```

## Status
Early scaffold. Read-only path (enumerate/classify/resolve/preflight) is implemented; mutating
functions have the correct mechanics in place with hardening TODOs marked inline and in
`docs/DESIGN.md` §9. Prove the read-only path against a real VM before exercising any mutation.

## Requirements
- Windows 10/11, PowerShell 5.1+ (7+ fine). Windows-only.
- Run elevated / as SYSTEM, with the target user logged off.
- Device Entra-joined; target user has signed in once.
