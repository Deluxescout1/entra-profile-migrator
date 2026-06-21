@{
    RootModule        = 'EntraProfileMigrator.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b3f6b1a2-0c7e-4d6a-9f1e-0a1b2c3d4e5f'
    Author            = 'Intelos'
    CompanyName       = 'Intelos'
    Copyright         = '(c) Intelos. Internal use.'
    Description       = 'Migrates Windows user profiles from on-prem AD to Entra ID (cloud-only) joined identities. In-house ForensiT User Profile Wizard replacement.'
    PowerShellVersion = '5.1'
    # Windows-only. Mutating functions require elevation.
    FunctionsToExport = @(
        'Get-MigratableProfile',
        'Get-MigrationCandidate',
        'Test-MigrationPrerequisite',
        'Invoke-ProfileMigration',
        'Restore-MigrationBackup',
        'Show-EntraMigrationGui'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Entra','AzureAD','ProfileMigration','MSP','Intune')
        }
    }
}
