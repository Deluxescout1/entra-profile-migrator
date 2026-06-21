function Show-EntraMigrationGui {
    <#
    .SYNOPSIS
        WinForms front-end for the migration. Lists the profiles on this device, lets you pick
        the target (Entra) and optional source (domain) profile manually, and runs the SAME
        Invoke-ProfileMigration that the CLI and SYSTEM/background paths use.

    .DESCRIPTION
        Read-only until you click Migrate (which asks for confirmation and is dry-run-safe via
        the underlying orchestrator). Run elevated; ideally as SYSTEM (e.g. PsExec -i -s) because
        re-ACLing another user's hive needs SYSTEM / backup privileges, and the target must be
        logged off.

        This is just a thin shell over the module: Get-MigratableProfile to populate the list,
        Test-MigrationPrerequisite for preflight, Invoke-ProfileMigration to run, and
        Restore-MigrationBackup to roll back. No migration logic lives here.

    .EXAMPLE
        Show-EntraMigrationGui
    #>
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = 'EntraProfileMigrator'
    $form.Size          = New-Object System.Drawing.Size(920, 660)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize   = New-Object System.Drawing.Size(720, 520)

    # --- Header ---
    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Location  = New-Object System.Drawing.Point(12, 10)
    $hdr.Size      = New-Object System.Drawing.Size(880, 36)
    $hdr.Anchor    = 'Top,Left,Right'
    if ($isAdmin) {
        $hdr.Text      = 'Select a TARGET (AzureAD) profile and (optionally) a SOURCE (Domain) profile, then Dry Run or Migrate.'
        $hdr.ForeColor = [System.Drawing.Color]::Black
    } else {
        $hdr.Text      = 'NOT ELEVATED - read-only only. Re-launch as Administrator/SYSTEM to migrate.'
        $hdr.ForeColor = [System.Drawing.Color]::Firebrick
    }
    $form.Controls.Add($hdr)

    # --- Profile list ---
    $list = New-Object System.Windows.Forms.ListView
    $list.Location      = New-Object System.Drawing.Point(12, 50)
    $list.Size          = New-Object System.Drawing.Size(880, 270)
    $list.View          = 'Details'
    $list.FullRowSelect = $true
    $list.MultiSelect   = $false
    $list.GridLines     = $true
    $list.Anchor        = 'Top,Left,Right'
    [void]$list.Columns.Add('Classification', 95)
    [void]$list.Columns.Add('Account', 210)
    [void]$list.Columns.Add('SID', 235)
    [void]$list.Columns.Add('Profile Path', 175)
    [void]$list.Columns.Add('Loaded', 55)
    [void]$list.Columns.Add('Migrated', 70)
    $form.Controls.Add($list)

    # --- Target UPN ---
    $lblUpn = New-Object System.Windows.Forms.Label
    $lblUpn.Location = New-Object System.Drawing.Point(12, 332)
    $lblUpn.Size     = New-Object System.Drawing.Size(150, 22)
    $lblUpn.Text     = 'Target UPN (Entra):'
    $form.Controls.Add($lblUpn)

    $txtUpn = New-Object System.Windows.Forms.TextBox
    $txtUpn.Location = New-Object System.Drawing.Point(165, 330)
    $txtUpn.Size     = New-Object System.Drawing.Size(300, 22)
    $form.Controls.Add($txtUpn)

    # --- Source SID (optional) ---
    $lblSrc = New-Object System.Windows.Forms.Label
    $lblSrc.Location = New-Object System.Drawing.Point(12, 362)
    $lblSrc.Size     = New-Object System.Drawing.Size(150, 22)
    $lblSrc.Text     = 'Source SID (optional):'
    $form.Controls.Add($lblSrc)

    $txtSrc = New-Object System.Windows.Forms.TextBox
    $txtSrc.Location = New-Object System.Drawing.Point(165, 360)
    $txtSrc.Size     = New-Object System.Drawing.Size(300, 22)
    $form.Controls.Add($txtSrc)

    # --- Copy mode ---
    $chkCopy = New-Object System.Windows.Forms.CheckBox
    $chkCopy.Location = New-Object System.Drawing.Point(485, 331)
    $chkCopy.Size     = New-Object System.Drawing.Size(360, 22)
    $chkCopy.Text     = 'Copy mode (robocopy to a new folder; safer, 2x disk)'
    $form.Controls.Add($chkCopy)

    # --- Output box ---
    $out = New-Object System.Windows.Forms.TextBox
    $out.Location   = New-Object System.Drawing.Point(12, 430)
    $out.Size       = New-Object System.Drawing.Size(880, 180)
    $out.Multiline  = $true
    $out.ReadOnly   = $true
    $out.ScrollBars = 'Vertical'
    $out.Font       = New-Object System.Drawing.Font('Consolas', 9)
    $out.Anchor     = 'Top,Bottom,Left,Right'
    $form.Controls.Add($out)

    # --- Helpers ---
    $refresh = {
        $list.Items.Clear()
        foreach ($p in (Get-MigratableProfile)) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$p.Classification)
            [void]$item.SubItems.Add([string]$p.Account)
            [void]$item.SubItems.Add([string]$p.Sid)
            [void]$item.SubItems.Add([string]$p.ProfileImagePath)
            [void]$item.SubItems.Add([string]$p.IsLoaded)
            [void]$item.SubItems.Add([string]$p.AlreadyMigrated)
            $item.Tag = $p
            [void]$list.Items.Add($item)
        }
    }

    $list.Add_SelectedIndexChanged({
        if ($list.SelectedItems.Count -eq 0) { return }
        $p = $list.SelectedItems[0].Tag
        if ($p.Classification -eq 'AzureAD') {
            if ($p.Account -match '^AzureAD\\(.+)$') { $txtUpn.Text = $Matches[1] }
        }
        elseif ($p.Classification -eq 'Domain') {
            $txtSrc.Text = [string]$p.Sid
        }
    })

    $runMigration = {
        param([bool]$Execute)
        $upn = $txtUpn.Text.Trim()
        if (-not $upn) {
            [void][System.Windows.Forms.MessageBox]::Show('Pick an AzureAD target profile (or type its UPN) first.', 'Need a target')
            return
        }
        $params = @{ TargetUpn = $upn }
        if ($txtSrc.Text.Trim()) { $params['SourceSid'] = $txtSrc.Text.Trim() }
        if ($chkCopy.Checked)    { $params['Mode']      = 'copy' }
        if ($Execute) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "Migrate $upn now? This rewrites ACLs and ProfileList (a backup + rollback are written first).",
                'Confirm migration', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { return }
            $params['Execute'] = $true
        }
        $form.Cursor = 'WaitCursor'
        try {
            $res = Invoke-ProfileMigration @params
            $out.Text = ("Success : {0}`r`nExitCode: {1}`r`n`r`n{2}" -f $res.Success, $res.ExitCode, $res.Message)
        }
        catch { $out.Text = "ERROR: $_" }
        finally {
            $form.Cursor = 'Default'
            & $refresh
        }
    }

    # --- Buttons ---
    $mkButton = {
        param($text, $x)
        $b = New-Object System.Windows.Forms.Button
        $b.Text     = $text
        $b.Location = New-Object System.Drawing.Point($x, 392)
        $b.Size     = New-Object System.Drawing.Size(110, 30)
        $form.Controls.Add($b)
        $b
    }

    $btnRefresh = & $mkButton 'Refresh'   12
    $btnPre     = & $mkButton 'Preflight' 130
    $btnDry     = & $mkButton 'Dry Run'   248
    $btnGo      = & $mkButton 'Migrate'   366
    $btnRoll    = & $mkButton 'Roll Back' 484

    $btnRefresh.Add_Click({ & $refresh; $out.Text = 'Profile list refreshed.' })

    $btnPre.Add_Click({
        $upn = $txtUpn.Text.Trim()
        if (-not $upn) {
            [void][System.Windows.Forms.MessageBox]::Show('Pick an AzureAD target profile (or type its UPN) first.', 'Need a target')
            return
        }
        $preParams = @{ TargetUpn = $upn }
        if ($txtSrc.Text.Trim()) { $preParams['SourceSid'] = $txtSrc.Text.Trim() }
        $pre = Test-MigrationPrerequisite @preParams
        $sb  = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine(("AllPassed: {0}`r`n" -f $pre.AllPassed))
        foreach ($c in $pre.Checks) {
            [void]$sb.AppendLine(("[{0}] {1}: {2}" -f $(if ($c.Pass) { 'PASS' } else { 'FAIL' }), $c.Check, $c.Detail))
        }
        $out.Text = $sb.ToString()
    })

    $btnDry.Add_Click({ & $runMigration $false })
    $btnGo.Add_Click({  & $runMigration $true  })
    if (-not $isAdmin) { $btnGo.Enabled = $false }

    $btnRoll.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Select the backup folder to roll back (ProgramData\EntraProfileMigrator\Backups\<timestamp>)'
        $root = Join-Path $env:ProgramData 'EntraProfileMigrator\Backups'
        if (Test-Path $root) { $dlg.SelectedPath = $root }
        if ($dlg.ShowDialog() -eq 'OK') {
            $form.Cursor = 'WaitCursor'
            try {
                $r = Restore-MigrationBackup -BackupPath $dlg.SelectedPath -Confirm:$false
                $out.Text = ("Rolled back migration {0} for {1}." -f $r.Timestamp, $r.SourcePath)
            }
            catch { $out.Text = "Rollback error: $_" }
            finally { $form.Cursor = 'Default'; & $refresh }
        }
    })

    & $refresh
    [void]$form.ShowDialog()
    $form.Dispose()
}
