# Deployment (NinjaOne / Rewst)

The tool runs as **SYSTEM** with the target user logged off.

## NinjaOne
Use `deploy/NinjaOne-Run-Migration.ps1` as a script policy. It:
- expects the module folder deployed alongside it (or pulled from your software repo/share),
- reads parameters from NinjaOne script variables / environment,
- imports the module, runs `Invoke-ProfileMigration`, and surfaces the exit code back to Ninja so
  you can alert on anything ≥ 40.

Recommended Ninja custom fields per device: `MigrationTargetUpn`, `MigrationMode` (inplace|copy),
`MigrationStatus` (write back the result + log path).

Stage as a **dry run first** (omit `-Execute`) across the fleet, review results, then flip to
execute on confirmed-ready devices (those where the user has completed their one Entra sign-in).

## Rewst
Wrap the same script in a Rewst workflow for orchestration:
- gate execution on `dsregcmd` join state and "target SID present" (i.e., user has signed in),
- pull the old→new UPN mapping from your CSV / PSA / a Rewst data table,
- run dry → on success, run execute → schedule the reboot in a maintenance window,
- write status + log link back to the ticket.

## Mapping file
For bulk runs, supply `-MappingCsv` pointing at a CSV like `deploy/mapping.sample.csv`
(`OldAccount,NewUpn`). Single-machine runs can auto-pair when there's exactly one domain profile
and one new Entra profile.

## Prereqs on the endpoint
- Device Entra-joined (Autopilot or provisioning package — separate from this tool).
- August 2025 cumulative update or newer (general hygiene; also unrelated WBfO prereq).
- Target user has signed in once (mints the SID).
- Target user logged off when the tool runs.
- Sufficient free disk if using `-Copy`.
