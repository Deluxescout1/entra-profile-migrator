function Write-MigrationLog {
    <#
    .SYNOPSIS
        Writes a timestamped line to the console and the migration log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')][string]$Level = 'INFO'
    )

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "[$stamp][$Level] $Message"

    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        'DEBUG'   { Write-Verbose $line }
        default   { Write-Host $line }
    }

    try {
        $logRoot = 'C:\ProgramData\EntraProfileMigrator\Logs'
        if (-not (Test-Path $logRoot)) { New-Item -ItemType Directory -Path $logRoot -Force | Out-Null }
        $logFile = Join-Path $logRoot ("migration_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
        Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    } catch {
        # Logging must never throw and abort a migration.
    }
}
