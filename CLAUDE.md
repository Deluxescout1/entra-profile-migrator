# CLAUDE.md — Operating instructions for this project

You are working on **EntraProfileMigrator**, a PowerShell tool that migrates Windows user
profiles from an on-prem Active Directory (domain-joined) identity to a **Microsoft Entra ID
(cloud-only) joined** identity — an in-house replacement for ForensiT User Profile Wizard,
deployable through NinjaOne RMM / Rewst.

Read `docs/DESIGN.md` first. It is the source of truth for architecture and the hard decisions.
Then `docs/MIGRATION-FLOW.md` for the runtime sequence and edge cases.

## What this tool actually does (one paragraph)
After a device is Entra-joined and the target user has signed in **once** with their Microsoft
account (which mints a new *local* SID), the tool re-permissions the user's existing domain
profile to the new SID and rewrites `HKLM\...\ProfileList` so Windows hands the user their old
profile — data, Outlook cache, browser profiles, app settings intact — instead of a blank one.
One reboot and the user is home.

## Non-negotiable safety rules (this code runs on real people's machines)
1. **WhatIf-first.** Every function that changes the system MUST support `-WhatIf`
   (`[CmdletBinding(SupportsShouldProcess)]`). The default for `Invoke-ProfileMigration` when
   called without `-Execute` is a dry run that reports the plan and changes nothing.
2. **Back up before you touch anything.** Before any mutation: `reg export` of the full
   `ProfileList` key, an `icacls /save` of the source profile ACLs, and a JSON manifest of the
   intended changes. No backup written → abort. These are the rollback inputs.
3. **Never run against a logged-on target.** The target profile's hive (`NTUSER.DAT`) must not
   be loaded. Check, and refuse if it is.
4. **Idempotent.** Re-running on an already-migrated profile must detect that and no-op, not
   double-apply.
5. **Fail loud, fail safe.** On any error mid-migration, stop, log, and leave clear rollback
   instructions. Return meaningful exit codes (see DESIGN.md) for RMM.
6. **Never invent SIDs.** The target SID is *discovered* from `ProfileList` after the user's
   first Entra sign-in — never guessed or constructed.
7. Full transcript logging to `C:\ProgramData\EntraProfileMigrator\Logs\` always on.

## How to work
- Make changes in small, reviewable steps. After editing a function, update its Pester test.
- This is Windows-only PowerShell 5.1+ / 7+. It cannot run or be tested on Linux/macOS —
  the developer tests in a disposable **Windows 11 Hyper-V VM with a checkpoint** taken before
  every test run. Assume that environment; do not add cross-platform shims.
- Prefer the .NET ACL APIs and built-in `icacls` / `reg` over third-party binaries. If thorough
  registry-hive SID substitution proves necessary, `SetACL.exe` is an *optional* dependency —
  gate it behind a check, never hard-require it.
- Keep functions single-purpose. Public functions in `Public/`, helpers in `Private/`.
- Don't add telemetry, network calls, or anything that phones home.

## Module layout
- `src/EntraProfileMigrator/` — the module (manifest + Public/Private functions)
- `deploy/` — NinjaOne wrapper + sample mapping CSV
- `tests/` — Pester tests
- `docs/` — design, runtime flow, deployment

## Current status / build order
See the checklist at the bottom of `docs/DESIGN.md`. Start by hardening the read-only path
(`Get-MigratableProfile`, `Test-MigrationPrerequisite`, `Resolve-TargetSid`) and proving it
against a real VM before touching any mutating function.
