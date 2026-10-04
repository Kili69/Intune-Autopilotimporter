# Project-Version: 1.2.20261004.9
# Author: andreas.lucas@outlook.com (aka Kili)

@{
    RootModule        = 'AutopilotImport.Client.psm1'
    ModuleVersion     = '1.2.20261004.9'
    GUID              = '83797727-048b-4db2-9480-2cd31aeb3f2e'
    Author            = 'andreas.lucas@outlook.com (aka Kili)'
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
            Tags       = @('Autopilot', 'Intune', 'AzureFunctions')
            LicenseUri = 'https://github.com/Kili69/Intune-Autopilotimporter/blob/main/LICENSE'
            ProjectUri = 'https://github.com/Kili69/Intune-Autopilotimporter'
        }
    }
}
