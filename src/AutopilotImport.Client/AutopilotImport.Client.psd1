# Project-Version: 1.1.20260913.4
# Author: andreas.lucas@microsoft.com (aka Kili)

@{
    RootModule        = 'AutopilotImport.Client.psm1'
    ModuleVersion     = '1.1.20260913.4'
    GUID              = '83797727-048b-4db2-9480-2cd31aeb3f2e'
    Author            = 'andreas.lucas@microsoft.com (aka Kili)'
    Description       = 'Client commands for the secured Windows Autopilot import Function.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'New-AutoPilotImporterClientConfiguration'
        'Get-AutoPilotImporterClientConfiguration'
        'Import-AutopilotDevice'
        'Get-AutopilotImportStatus'
        'Get-AutopilotImportHistory'
        'Get-AutopilotTagPolicy'
        'Add-AutopilotTagPolicy'
        'Remove-AutopilotTagPolicy'
        'Set-AutopilotTagPolicy'
        'Update-AutopilotTagPolicyManager'
        'Add-AutopilotTagPolicyManager'
        'Remove-AutopilotTagPolicyManager'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('Autopilot', 'Intune', 'AzureFunctions')
        }
    }
}
