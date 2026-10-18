# Project-Version: 1.4.20261018.1
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Reads and updates explicit policy managers using the caller's Azure RBAC rights.
.DESCRIPTION
Requires Easy Auth and a separate delegated ARM token in x-autopilot-arm-token.
GET ?access=true only checks visibility using the Function identity's
Function-scoped roleAssignments/read permission, without a delegated ARM token.
It returns canManagePolicyManagers, never manager settings or directory data.
ARM validates that token; its user must match the Easy Auth user. Effective
Owner/Contributor assignments on this Function App or an ancestor are required
on every request, including directory searches. No managed-identity ARM write
permission is granted. The installer is protected and all app settings are
preserved. Updating app settings can restart the Function App.
PUT supplies additionalPrincipalIds and the expectedPolicy returned by GET.
Concurrent manager edits are rejected; unrelated settings are read afresh before
writing, with the same ARM collection-replacement limitation as the PS client.
#>
using namespace System.Net
param($Request, $TriggerMetadata)

Import-Module (Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1') -Force
$correlationId = [guid]::NewGuid().ToString()
$auditRequested = $false
function Send-ManagerResponse {
    param([HttpStatusCode] $StatusCode, [object] $Body)
    $Body.correlationId = $correlationId
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers = @{ 'Content-Type' = 'application/json'; 'Cache-Control' = 'no-store' }
        Body = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
    })
}
function Invoke-ManagerArm {
    param([string] $Uri, [string] $Method = 'GET', [object] $Body)
    if (-not $Uri.StartsWith('https://management.azure.com/', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected ARM response URL.'
    }
    $parameters = @{
        Uri = $Uri; Method = $Method; Authentication = 'Bearer'
        Token = $armToken; ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
        $parameters.ContentType = 'application/json'
    }
    Invoke-RestMethod @parameters
}
function Read-ManagerPolicy {
    param([string] $Json)
    $policy = $Json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if (-not $policy -or -not $policy.ContainsKey('installerPrincipalId') -or
        -not $policy.ContainsKey('additionalPrincipalIds') -or
        [guid] $policy.installerPrincipalId -eq [guid]::Empty) {
        throw 'Invalid manager policy.'
    }
    $policy.installerPrincipalId = ([guid] $policy.installerPrincipalId).ToString()
    $policy.additionalPrincipalIds = @($policy.additionalPrincipalIds | ForEach-Object {
        if ([guid] $_ -eq [guid]::Empty) { throw 'Invalid manager object ID.' }
        ([guid] $_).ToString()
    } | Sort-Object -Unique)
    return $policy
}

if ([string]::IsNullOrWhiteSpace([string] $Request.Headers['x-ms-client-principal'])) {
    Send-ManagerResponse Unauthorized @{ error = 'authenticationRequired' }
    return
}
$accessCheck = $Request.Query -and $null -ne $Request.Query['access']
if ($accessCheck -and ($Request.Method -ine 'GET' -or $Request.Query['access'] -ine 'true' -or
    $null -ne $Request.Query['search'] -or $null -ne $Request.Query['history'])) {
    Send-ManagerResponse BadRequest @{ error = 'invalidAccessCheck' }
    return
}
if (-not $accessCheck -and [string]::IsNullOrWhiteSpace([string] $Request.Headers['x-autopilot-arm-token'])) {
    Send-ManagerResponse Unauthorized @{ error = 'azureAuthenticationRequired' }
    return
}
$resourceId = $env:FUNCTION_RESOURCE_ID
if ($resourceId -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft.Web/sites/[^/]+$') {
    Send-ManagerResponse InternalServerError @{ error = 'managerServiceNotConfigured' }
    return
}
try {
    $principal = ConvertFrom-ClientPrincipalHeader $Request.Headers['x-ms-client-principal']
    $callerId = [guid] (@($principal.claims | Where-Object {
        $_.typ -in @('oid', 'http://schemas.microsoft.com/identity/claims/objectidentifier')
    } | Select-Object -First 1).val)
    if ($callerId -eq [guid]::Empty) { throw 'Missing user object ID.' }
    if (-not $accessCheck) {
        $plainToken = [string] $Request.Headers['x-autopilot-arm-token']
        $payload = $plainToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
        $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        if ([guid] $claims.oid -ne $callerId -or [guid] $claims.tid -ne [guid] $env:TENANT_ID) {
            throw 'Azure and API accounts must match.'
        }
        $armToken = ConvertTo-SecureString $plainToken -AsPlainText -Force
    }
}
catch {
    Send-ManagerResponse Unauthorized @{ error = $(if ($accessCheck) { 'invalidPrincipal' } else { 'invalidAzureAuthentication' }) }
    return
}
try {
    if ($accessCheck) {
        $armToken = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -ErrorAction Stop).Token
        if ($armToken -isnot [Security.SecureString]) {
            $armToken = ConvertTo-SecureString $armToken -AsPlainText -Force
        }
    }
    # Decoded claims are not authorization: ARM must first accept the token.
    $filter = [uri]::EscapeDataString("assignedTo('$callerId')")
    $next = "https://management.azure.com$resourceId/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=$filter"
    $assignments = @(
        do {
            $page = Invoke-ManagerArm $next
            if (-not $page.PSObject.Properties['value'] -or $page.value -isnot [array]) {
                throw 'Invalid ARM role-assignment response.'
            }
            foreach ($assignment in $page.value) {
                $roleId = ([string] $assignment.properties.roleDefinitionId).Split('/')[-1]
                $roleName = switch ($roleId) {
                    '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' { 'Owner' }
                    'b24988ac-6180-42a0-ab88-20f7382dd24c' { 'Contributor' }
                    default { '' }
                }
                [pscustomobject]@{ Scope = $assignment.properties.scope; RoleDefinitionName = $roleName }
            }
            $next = if ($page.PSObject.Properties['nextLink']) { [string] $page.nextLink } else { '' }
        } while ($next)
    )
    $canManage = Test-TagManagerPolicyAdministratorRole $assignments $resourceId
    if ($accessCheck) {
        Send-ManagerResponse OK @{ canManagePolicyManagers = [bool] $canManage }
        return
    }
    if (-not $canManage) {
        Send-ManagerResponse Forbidden @{ error = 'policyManagerAdministrationForbidden' }
        return
    }
}
catch {
    $status = if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
        $_.Exception.Response.StatusCode
    } else { $null }
    if (-not $accessCheck -and $status -in @(401, 403)) {
        Send-ManagerResponse Forbidden @{ error = 'policyManagerAdministrationForbidden' }
    } else {
        Write-Error "[$correlationId] Azure role verification failed: $($_.Exception.Message)" -ErrorAction Continue
        Send-ManagerResponse BadGateway @{ error = 'azureAuthorizationUnavailable' }
    }
    return
}

try {
    if ($Request.Method -ieq 'GET' -and $Request.Query -and $Request.Query['history'] -eq 'true') {
        try {
            $history = Get-ManagementAuditHistory -Kind managers -Continuation ([string] $Request.Query['continuation'])
        } catch [ArgumentException] {
            Send-ManagerResponse BadRequest @{ error = 'invalidHistoryContinuation' }
            return
        }
        Send-ManagerResponse OK $history
        return
    }
    if ($Request.Method -ieq 'GET' -and $Request.Query -and $null -ne $Request.Query['search']) {
        $query = ([string] $Request.Query['search']).Trim()
        if ($query.Length -lt 2 -or $query.Length -gt 128) {
            Send-ManagerResponse BadRequest @{ error = 'invalidObjectSearch' }
            return
        }
        $token = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com/' -ErrorAction Stop).Token
        if ($token -isnot [Security.SecureString]) { $token = ConvertTo-SecureString $token -AsPlainText -Force }
        $users = Find-EntraPolicyGroups -SearchText $query -ObjectType users -AccessToken $token
        $groups = Find-EntraPolicyGroups -SearchText $query -ObjectType groups -AccessToken $token
        $objects = @(
            $users.groups | ForEach-Object { @{ id = $_.id; displayName = "$($_.displayName) [User]" } }
            $groups.groups | ForEach-Object { @{ id = $_.id; displayName = "$($_.displayName) [Group]" } }
        )
        Send-ManagerResponse OK @{
            groups = @($objects | Sort-Object { $_.displayName } | Select-Object -First 25)
            hasMore = $objects.Count -gt 25 -or $users.hasMore -or $groups.hasMore
        }
        return
    }
    $settingsUri = "https://management.azure.com$resourceId/config/appsettings"
    $settings = Invoke-ManagerArm "${settingsUri}/list?api-version=2022-03-01" POST
    $policyJson = [string] $settings.properties.MANAGER_AUTHORIZATION_POLICY
    $policy = Read-ManagerPolicy $policyJson
    if ($Request.Method -ieq 'GET') {
        Send-ManagerResponse OK @{ policy = $policy; expectedPolicy = $policyJson }
        return
    }
    if ($Request.Method -ine 'PUT') {
        Send-ManagerResponse MethodNotAllowed @{ error = 'methodNotAllowed' }
        return
    }
    try {
        $body = if ($Request.Body -is [string]) { $Request.Body | ConvertFrom-Json -AsHashtable } else {
            $Request.Body | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        }
        if (-not $body.ContainsKey('additionalPrincipalIds') -or $body.additionalPrincipalIds -isnot [array] -or
            -not $body.ContainsKey('expectedPolicy')) { throw 'Expected manager policy and an object-ID array are required.' }
        $ids = @($body.additionalPrincipalIds | ForEach-Object {
            if ($_ -isnot [string] -or [guid] $_ -eq [guid]::Empty) { throw 'Invalid manager object ID.' }
            ([guid] $_).ToString()
        } | Sort-Object -Unique | Where-Object { $_ -ne $policy.installerPrincipalId })
    }
    catch {
        Send-ManagerResponse BadRequest @{ error = 'invalidManagerPolicy'; message = $_.Exception.Message }
        return
    }
    if ([string] $body.expectedPolicy -cne $policyJson) {
        Send-ManagerResponse Conflict @{ error = 'managerPolicyChanged'; message = 'Reload managers before saving.' }
        return
    }
    $newIds = @($ids | Where-Object { $_ -notin $policy.additionalPrincipalIds })
    if ($newIds.Count -gt 0) {
        $token = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com/' -ErrorAction Stop).Token
        if ($token -isnot [Security.SecureString]) { $token = ConvertTo-SecureString $token -AsPlainText -Force }
        foreach ($id in $newIds) {
            $users = Find-EntraPolicyGroups -SearchText $id -ObjectType users -AccessToken $token
            $groups = Find-EntraPolicyGroups -SearchText $id -ObjectType groups -AccessToken $token
            if (@($users.groups) + @($groups.groups) | Where-Object { $_.id -eq $id }) { continue }
            Send-ManagerResponse BadRequest @{ error = 'managerObjectNotFound'; message = "User or group not found: $id" }
            return
        }
    }
    $settings = Invoke-ManagerArm "${settingsUri}/list?api-version=2022-03-01" POST
    if ([string] $settings.properties.MANAGER_AUTHORIZATION_POLICY -cne $policyJson) {
        Send-ManagerResponse Conflict @{ error = 'managerPolicyChanged'; message = 'Reload managers before saving.' }
        return
    }
    $policy.additionalPrincipalIds = $ids
    $updatedJson = ConvertTo-Json -InputObject $policy -Depth 10 -Compress
    Write-ManagementAuditEvent -Kind managers -OperationId $correlationId -Stage requested `
        -Principal $principal -Before ($policyJson | ConvertFrom-Json) -After $policy
    $auditRequested = $true
    $settings.properties.MANAGER_AUTHORIZATION_POLICY = $updatedJson
    $null = Invoke-ManagerArm "${settingsUri}?api-version=2022-03-01" PUT @{ properties = $settings.properties }
    Write-ManagementAuditEvent -Kind managers -OperationId $correlationId -Stage applied -Principal $principal
    Send-ManagerResponse OK @{ policy = $policy; expectedPolicy = $updatedJson }
}
catch {
    Write-Error "[$correlationId] Manager operation failed: $($_.Exception.Message)" -ErrorAction Continue
    if ($auditRequested) {
        try {
            Write-ManagementAuditEvent -Kind managers -OperationId $correlationId -Stage failed `
                -Principal $principal -Before ($policyJson | ConvertFrom-Json) -After $policy
        } catch {
            Write-Error "[$correlationId] Manager failure audit could not be recorded: $($_.Exception.Message)" -ErrorAction Continue
        }
    }
    Send-ManagerResponse BadGateway @{ error = 'managerOperationFailed'; message = 'Could not read, update or confirm the manager audit record. Reload managers and history to verify the current state.' }
}
