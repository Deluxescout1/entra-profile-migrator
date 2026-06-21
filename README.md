# EntraProfileMigrator

[![CI](https://github.com/Deluxescout1/entra-profile-migrator/actions/workflows/ci.yml/badge.svg)](https://github.com/Deluxescout1/entra-profile-migrator/actions/workflows/ci.yml)

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

## Three ways to run it (same core)
All three drive the same `Invoke-ProfileMigration` engine — pick whichever fits.

**1. PowerShell (interactive / CLI).** Elevated console, as in Quick start above.

**2. GUI (pick profiles manually).** A WinForms front-end that lists every profile, lets you
select the target (Entra) and optional source (domain), and Preflight / Dry Run / Migrate / Roll
Back — read-only until you confirm a migration.
```powershell
Import-Module .\src\EntraProfileMigrator\EntraProfileMigrator.psd1 -Force
Show-EntraMigrationGui
# or just run the launcher (handles the STA requirement for you):
.\tools\EntraProfileMigrator-GUI.ps1
```

**3. Background, as SYSTEM (no RMM).** Re-ACLing another user's hive needs SYSTEM and the target
logged off. This registers a transient SYSTEM scheduled task, runs the migration, waits, and
cleans up — dry-run by default:
```powershell
.\deploy\Start-MigrationAsSystem.ps1 -TargetUpn jsmith@contoso.com            # dry run
.\deploy\Start-MigrationAsSystem.ps1 -TargetUpn jsmith@contoso.com -Execute   # migrate
```
For RMM, use `deploy\NinjaOne-Run-Migration.ps1` (reads parameters from NinjaOne variables). The
orchestrator runs fully non-interactive (no prompts) so it is safe under SYSTEM/Rewst/NinjaOne.

### Want a single .exe?
There is no prebuilt `.exe` (this tool is PowerShell, and an `.exe` can only be produced on
Windows). To build one yourself, run once on a Windows PC:
```powershell
.\tools\Build-Exe.ps1     # -> dist\EntraProfileMigrator.exe (double-click; prompts for admin)
```
That inlines the whole module into one file and compiles it with PS2EXE. Or skip the build and
just double-click **`Run-EntraMigrator-GUI.cmd`**, which launches the same GUI without compiling.

**Prebuilt download:** every version tag publishes the compiled `.exe` (plus a SHA256) to the
[Releases page](https://github.com/Deluxescout1/entra-profile-migrator/releases) via CI. To cut a
release, push a tag (`git tag v0.1.0; git push origin v0.1.0`) or run the **Release** workflow from
the Actions tab. Always verify the SHA256, and test in a VM before using on a real machine.

## Testing the mutation mechanics on a local PC
The risky machinery (re-ACL, hive rewrite, `ProfileList` repoint, **and rollback**) is SID-agnostic,
so you can prove it on a throwaway Windows box using two **disposable local accounts** as stand-ins
for the old (domain) and new (Entra) SIDs — no domain or Entra join required. This does **not** cover
Domain/AzureAD classification, the `dsregcmd` join gate, or target-SID discovery (those need a real
domain profile + an Entra-joined device).

```powershell
# 1. Get the code
git clone https://github.com/Deluxescout1/entra-profile-migrator.git
cd entra-profile-migrator
#    (downloaded a ZIP instead? unblock it first:)
#    Get-ChildItem -Recurse -Include *.ps1,*.psm1,*.psd1 | Unblock-File

# 2. Elevated PowerShell, allow scripts for this session only
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# 3. Read-only sanity check (zero risk)
Import-Module .\src\EntraProfileMigrator\EntraProfileMigrator.psd1 -Force
Get-MigratableProfile | Format-Table Classification, Account, Sid, ProfileImagePath, IsLoaded

# 4. Make two throwaway accounts, then SIGN IN to each once (Switch user) to mint
#    their profiles, drop junk files in oldie's Desktop, and sign back out.
net user oldie  P@ssw0rd! /add
net user newbie P@ssw0rd! /add

# 5. Dry run — shows the plan, changes nothing
.\tools\LocalMechanicsTest.ps1 -SourceAccount oldie -TargetAccount newbie

# 6. Real run — migrate, verify, then automatically roll back (type MIGRATE to confirm)
.\tools\LocalMechanicsTest.ps1 -SourceAccount oldie -TargetAccount newbie -Execute
```

Run this as a *third* admin account (not `oldie`/`newbie`). It refuses any profile that isn't a
disposable local account, is logged on, or is the account running it. Automated mocked tests run
separately in CI on every push (see the badge above); `LocalMechanicsTest.ps1` is always manual
because it mutates a real machine.

## Status
Early scaffold. Read-only path (enumerate/classify/resolve/preflight) is implemented; mutating
functions have the correct mechanics in place with hardening TODOs marked inline and in
`docs/DESIGN.md` §9. Prove the read-only path against a real VM before exercising any mutation.

## Requirements
- Windows 10/11, PowerShell 5.1+ (7+ fine). Windows-only.
- Run elevated / as SYSTEM, with the target user logged off.
- Device Entra-joined; target user has signed in once.
