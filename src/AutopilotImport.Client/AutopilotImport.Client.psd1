# Project-Version: 1.4.20261020.3
# Author: andreas.lucas@outlook.com (aka Kili)

@{
    RootModule        = 'AutopilotImport.Client.psm1'
    ModuleVersion     = '1.4.20261020.3'
    GUID              = '83797727-048b-4db2-9480-2cd31aeb3f2e'
    Author            = 'andreas.lucas@outlook.com (aka Kili)'
    Description       = 'Client commands for secured Windows Autopilot imports and Group Tag changes.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'New-AutoPilotImporterClientConfiguration'
        'Get-AutoPilotImporterClientConfiguration'
        'Import-AutoPilotDevice'
        'Get-AutoPilotDeviceTagAssignment'
        'Set-AutoPilotDeviceGroupTag'
        'Get-AutoPilotImportStatus'
        'Get-AutoPilotImportHistory'
        'Get-AutoPilotTagPolicy'
        'Get-AutoPilotTagPolicyHistory'
        'Add-AutoPilotTagPolicy'
        'Remove-AutoPilotTagPolicy'
        'Set-AutoPilotTagPolicy'
        'Get-AutoPilotTagPolicyManager'
        'Update-AutoPilotTagPolicyManager'
        'Add-AutoPilotTagPolicyManager'
        'Remove-AutoPilotTagPolicyManager'
        'Export-AutoPilotConfiguration'
        'Restore-AutoPilotConfiguration'
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
