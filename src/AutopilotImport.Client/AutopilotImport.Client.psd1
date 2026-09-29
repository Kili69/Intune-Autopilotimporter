# Project-Version: 1.2.20260929.3
# Author: andreas.lucas@microsoft.com (aka Kili)

@{
    RootModule        = 'AutopilotImport.Client.psm1'
    ModuleVersion     = '1.2.20260929.3'
    GUID              = '83797727-048b-4db2-9480-2cd31aeb3f2e'
    Author            = 'andreas.lucas@microsoft.com (aka Kili)'
    Description       = 'Client commands for the secured Windows Autopilot import Function.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'New-AutoPilotImporterClientConfiguration'
        'Get-AutoPilotImporterClientConfiguration'
        'Import-AutoPilotDevice'
        'Get-AutoPilotImportStatus'
        'Get-AutoPilotImportHistory'
        'Get-AutoPilotTagPolicy'
        'Add-AutoPilotTagPolicy'
        'Remove-AutoPilotTagPolicy'
        'Set-AutoPilotTagPolicy'
        'Get-AutoPilotTagPolicyManager'
        'Update-AutoPilotTagPolicyManager'
        'Add-AutoPilotTagPolicyManager'
        'Remove-AutoPilotTagPolicyManager'
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
