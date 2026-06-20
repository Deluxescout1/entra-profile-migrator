# Runtime flow — single device

This is the operator/runbook view. The tool automates steps 4–6.

1. **Pre-stage (tech / Autopilot / provisioning package).** Confirm the user exists as a
   cloud-only Entra account. Confirm a current backup exists (the migration is destructive to
   ACLs). Confirm the device's OneDrive / data is in a known state.

2. **Entra-join the device.** Settings → Accounts → Access work or school → Connect → *Join this
   device to Microsoft Entra ID*. (Or push a provisioning package / Autopilot.) Verify with
   `dsregcmd /status` → `AzureAdJoined : YES`. *(Out of scope for the core tool.)*

3. **User signs in once with their MS account** (use "Other User" → full UPN). This is the one
   unavoidable sign-in: it mints the user's local SID and a throwaway profile. They can sign
   straight back out.

4. **Run the tool (dry run).** As SYSTEM/admin, target logged off:
   `Invoke-ProfileMigration -TargetUpn user@contoso.com`  → reports the plan, changes nothing.
   Confirm it found the right source profile and the freshly-minted target SID.

5. **Run the tool (execute).**
   `Invoke-ProfileMigration -TargetUpn user@contoso.com -Execute`
   - writes backups (ProfileList .reg, FS ACL save, manifest)
   - re-ACLs the profile filesystem (old SID → new SID)
   - re-ACLs NTUSER.DAT / UsrClass.dat for the new SID
   - rewrites ProfileList so the new SID points at the real profile folder
   - removes the throwaway profile

6. **Reboot.** User signs in with their MS account and lands in their full, original profile.

## If something goes wrong
- Exit `40`: the target user hasn't signed in yet — go back to step 3.
- Exit `50`: failed but auto-rolled-back — safe to investigate and retry.
- Exit `60`: failed, manual rollback needed — follow `ROLLBACK.txt` in the backup folder
  (`C:\ProgramData\EntraProfileMigrator\Backups\<timestamp>\`).

## Test loop (developer)
Win11 Hyper-V VM → take a **checkpoint** → join a test tenant → create a fake "domain-ish"
profile with data → sign in test Entra user once → run dry then execute → verify login →
**revert to checkpoint** and repeat. Never first-run on a production/client machine.
