# Project-Version: 1.1.20260918.4
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
DISCLAIMER:
This sample script is not supported under any Microsoft standard support program or service.
The sample script is provided AS IS without warranty of any kind. Microsoft further disclaims
all implied warranties including, without limitation, any implied warranties of merchantability
or of fitness for a particular purpose. The entire risk arising out of the use or performance of
the sample scripts and documentation remains with you. In no event shall Microsoft, its authors,
or anyone else involved in the creation, production, or delivery of the scripts be liable for any
damages whatsoever (including, without limitation, damages for loss of business profits, business
interruption, loss of business information, or other pecuniary loss) arising out of the use of or
inability to use the sample scripts or documentation, even if Microsoft has been advised of the
possibility of such damages.
#>

<#
.SYNOPSIS
Provides validation and authorization helpers for the Autopilot import API.

.DESCRIPTION
Contains the testable core used by the Azure Function HTTP triggers to decode
Easy Auth principals, enforce group-to-tag and manager policies, and construct
a validated Microsoft Graph Autopilot import payload.
#>

Set-StrictMode -Version Latest

function ConvertFrom-BlobBindingContent {
    <#
    .SYNOPSIS
    Converts an Azure Functions blob input binding value to text.

    .PARAMETER Value
    Blob binding value represented as text, bytes, a stream, or a content
    wrapper supplied by the Functions PowerShell worker.

    .OUTPUTS
    System.String, or null when the binding has no value.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        return $Value
    }
    if ($Value -is [byte[]]) {
        return [Text.Encoding]::UTF8.GetString($Value)
    }
    if ($Value -is [IO.Stream]) {
        if ($Value.CanSeek) {
            $Value.Position = 0
        }
        $reader = [IO.StreamReader]::new(
            $Value,
            [Text.Encoding]::UTF8,
            $true,
            1024,
            $true
        )
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    if ($Value.PSObject.Properties.Name -contains 'Content') {
        return ConvertFrom-BlobBindingContent -Value $Value.Content
    }
    if ($Value -is [System.Collections.IDictionary] -or
        $Value -is [pscustomobject] -or
        $Value -is [System.Collections.IEnumerable]) {
        return $Value | ConvertTo-Json -Depth 20 -Compress
    }

    return $Value.ToString()
}

function Get-ImportAuditTableUri {
    <#
    .SYNOPSIS
    Resolves the Azure Table endpoint used for import audit records.
    #>
    [CmdletBinding()]
    param()

    $storageAccountName = $env:AzureWebJobsStorage__accountName
    if ([string]::IsNullOrWhiteSpace($storageAccountName)) {
        throw 'AzureWebJobsStorage__accountName is required for import audit history.'
    }

    $tableName = if ([string]::IsNullOrWhiteSpace(
            $env:IMPORT_AUDIT_TABLE_NAME)) {
        'importaudit'
    }
    else {
        $env:IMPORT_AUDIT_TABLE_NAME.Trim()
    }
    if ($tableName -notmatch '^[A-Za-z][A-Za-z0-9]{2,62}$') {
        throw "Import audit table name '$tableName' is invalid."
    }

    return "https://$storageAccountName.table.core.windows.net/$tableName"
}

function Get-ImportAuditAccessToken {
    <#
    .SYNOPSIS
    Acquires an Azure Storage token through the current managed identity.
    #>
    [CmdletBinding()]
    param()

    $tokenResult = Get-AzAccessToken `
        -ResourceUrl 'https://storage.azure.com/' `
        -ErrorAction Stop
    if ($tokenResult.Token -is [Security.SecureString]) {
        return $tokenResult.Token
    }
    return ConvertTo-SecureString `
        ([string] $tokenResult.Token) `
        -AsPlainText `
        -Force
}

function Get-DeviceHashSha256 {
    <#
    .SYNOPSIS
    Returns a stable SHA-256 index for a Base64 Autopilot device hash.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateLength(1, 65536)]
        [string] $DeviceHash
    )

    try {
        $deviceHashBytes = [Convert]::FromBase64String($DeviceHash)
    }
    catch {
        throw [ArgumentException]::new('DeviceHash must be valid Base64.')
    }
    if ($deviceHashBytes.Length -eq 0) {
        throw [ArgumentException]::new('DeviceHash must not be empty.')
    }

    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($deviceHashBytes)
    ).ToLowerInvariant()
}

function Test-ImportAuditHttpStatus {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord] $ErrorRecord,

        [Parameter(Mandatory)]
        [int] $StatusCode
    )

    if ($ErrorRecord.Exception.PSObject.Properties['Response'] -and
        $ErrorRecord.Exception.Response -and
        $ErrorRecord.Exception.Response.PSObject.Properties['StatusCode']) {
        return [int] $ErrorRecord.Exception.Response.StatusCode -eq $StatusCode
    }
    return $ErrorRecord.Exception.Data.Contains('StatusCode') -and
        [int] $ErrorRecord.Exception.Data['StatusCode'] -eq $StatusCode
}

function Set-ImportAuditRecord {
    <#
    .SYNOPSIS
    Merges audit properties into the record for an Autopilot import.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid] $ImportId,

        [Parameter(Mandatory)]
        [Collections.IDictionary] $Properties,

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken
    )

    $tableUri = Get-ImportAuditTableUri
    $rowKey = $ImportId.ToString()
    $entity = [ordered]@{
        PartitionKey = 'imports'
        RowKey = $rowKey
    }
    foreach ($propertyName in $Properties.Keys) {
        if ($propertyName -in @('PartitionKey', 'RowKey') -or
            $null -eq $Properties[$propertyName]) {
            continue
        }
        $entity[[string] $propertyName] = $Properties[$propertyName]
    }
    $headers = @{
        Accept         = 'application/json;odata=nometadata'
        'If-Match'     = '*'
        'x-ms-date'    = [datetime]::UtcNow.ToString(
            'R', [Globalization.CultureInfo]::InvariantCulture)
        'x-ms-version' = '2019-02-02'
    }
    $body = $entity | ConvertTo-Json -Depth 6 -Compress
    $entityUri = "$tableUri(PartitionKey='imports',RowKey='$rowKey')"

    try {
        Invoke-RestMethod `
            -Method Merge `
            -Uri $entityUri `
            -Authentication Bearer `
            -Token $AccessToken `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body $body `
            -ErrorAction Stop | Out-Null
    }
    catch {
        if (-not (Test-ImportAuditHttpStatus `
                -ErrorRecord $_ `
                -StatusCode 404)) {
            throw
        }
        $headers.Remove('If-Match')
        try {
            Invoke-RestMethod `
                -Method Post `
                -Uri $tableUri `
                -Authentication Bearer `
                -Token $AccessToken `
                -Headers $headers `
                -ContentType 'application/json' `
                -Body $body `
                -ErrorAction Stop | Out-Null
        }
        catch {
            if (-not (Test-ImportAuditHttpStatus `
                    -ErrorRecord $_ `
                    -StatusCode 409)) {
                throw
            }
            Set-ImportAuditRecord `
                -ImportId $ImportId `
                -Properties $Properties `
                -AccessToken $AccessToken
        }
    }
}

function Get-ImportAuditRecords {
    <#
    .SYNOPSIS
    Returns audit records indexed by Autopilot import ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid[]] $ImportId,

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken
    )

    $records = @{}
    $ids = @($ImportId | Select-Object -Unique)
    if ($ids.Count -eq 0) {
        return $records
    }

    $tableUri = Get-ImportAuditTableUri
    $headers = @{
        Accept         = 'application/json;odata=nometadata'
        'x-ms-date'    = [datetime]::UtcNow.ToString(
            'R', [Globalization.CultureInfo]::InvariantCulture)
        'x-ms-version' = '2019-02-02'
    }
    for ($offset = 0; $offset -lt $ids.Count; $offset += 20) {
        $lastIndex = [Math]::Min($offset + 19, $ids.Count - 1)
        $rowFilters = @($ids[$offset..$lastIndex] | ForEach-Object {
            "RowKey eq '$($_.ToString())'"
        })
        $filter = "PartitionKey eq 'imports' and ($($rowFilters -join ' or '))"
        $requestUri = "$tableUri()?`$filter=$([uri]::EscapeDataString($filter))"
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $requestUri `
            -Authentication Bearer `
            -Token $AccessToken `
            -Headers $headers `
            -ErrorAction Stop
        foreach ($record in @($response.value)) {
            $records[[string] $record.RowKey] = $record
        }
    }

    return $records
}

function Get-ImportAuditRetentionCutoffUtc {
    <#
    .SYNOPSIS
    Returns the UTC cutoff for the import audit retention period.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 3650)]
        [int] $RetentionDays = 30,

        [datetimeoffset] $ReferenceUtc = [datetimeoffset]::UtcNow
    )

    return $ReferenceUtc.AddDays(-$RetentionDays)
}

function Get-ImportAuditHistory {
    <#
    .SYNOPSIS
    Returns recent audit records filtered by owner or explicit identifiers.
    #>
    [CmdletBinding()]
    param(
        [guid[]] $ImportId = @(),

        [string[]] $SerialNumber = @(),

        [string[]] $DeviceHashSha256 = @(),

        [string] $ActorObjectId,

        [Parameter(Mandatory)]
        [datetimeoffset] $SinceUtc,

        [ValidateRange(1, 1000)]
        [int] $Top = 100,

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken
    )

    $tableUri = Get-ImportAuditTableUri
    $sinceValue = $SinceUtc.UtcDateTime.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffffffZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $filters = @(
        "PartitionKey eq 'imports'"
        "requestReceivedAtUtc ge '$sinceValue'"
    )
    $identifierFilters = @(
        @($ImportId | Select-Object -Unique | ForEach-Object {
            "RowKey eq '$($_.ToString())'"
        })
        @($SerialNumber | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Unique | ForEach-Object {
            "serialNumber eq '$($_.Replace("'", "''"))'"
        })
        @($DeviceHashSha256 | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Unique | ForEach-Object {
            "deviceHashSha256 eq '$($_.Replace("'", "''"))'"
        })
    )
    if ($identifierFilters.Count -gt 0) {
        $filters += "($($identifierFilters -join ' or '))"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ActorObjectId)) {
        $escapedActorObjectId = $ActorObjectId.Replace("'", "''")
        $filters += "actorObjectId eq '$escapedActorObjectId'"
    }
    $filter = $filters -join ' and '
    $headers = @{
        Accept         = 'application/json;odata=nometadata'
        'x-ms-date'    = [datetime]::UtcNow.ToString(
            'R', [Globalization.CultureInfo]::InvariantCulture)
        'x-ms-version' = '2019-02-02'
    }
    $records = [Collections.Generic.List[object]]::new()
    $nextPartitionKey = $null
    $nextRowKey = $null

    do {
        $requestUri = "$tableUri()?`$filter=$([uri]::EscapeDataString($filter))&`$top=1000"
        if (-not [string]::IsNullOrWhiteSpace($nextPartitionKey)) {
            $requestUri += "&NextPartitionKey=$([uri]::EscapeDataString($nextPartitionKey))"
        }
        if (-not [string]::IsNullOrWhiteSpace($nextRowKey)) {
            $requestUri += "&NextRowKey=$([uri]::EscapeDataString($nextRowKey))"
        }
        $responseHeaders = $null
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $requestUri `
            -Authentication Bearer `
            -Token $AccessToken `
            -Headers $headers `
            -ResponseHeadersVariable responseHeaders `
            -ErrorAction Stop
        foreach ($record in @($response.value)) {
            $records.Add($record)
        }
        $nextPartitionKey = if ($responseHeaders) {
            [string] $responseHeaders['x-ms-continuation-NextPartitionKey']
        }
        else {
            $null
        }
        $nextRowKey = if ($responseHeaders) {
            [string] $responseHeaders['x-ms-continuation-NextRowKey']
        }
        else {
            $null
        }
    } while (-not [string]::IsNullOrWhiteSpace($nextPartitionKey))

    return @($records | Sort-Object {
        $recordedAt = if (-not [string]::IsNullOrWhiteSpace(
                [string] $_.requestReceivedAtUtc)) {
            [datetimeoffset] $_.requestReceivedAtUtc
        }
        else {
            [datetimeoffset] $_.Timestamp
        }
        $recordedAt
    } -Descending | Select-Object -First $Top)
}

function Remove-ExpiredImportAuditRecords {
    <#
    .SYNOPSIS
    Deletes import audit records older than the supplied UTC cutoff.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetimeoffset] $BeforeUtc,

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken
    )

    $tableUri = Get-ImportAuditTableUri
    $beforeValue = $BeforeUtc.UtcDateTime.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffffffZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $filter = "PartitionKey eq 'imports' and requestReceivedAtUtc lt '$beforeValue'"
    $headers = @{
        Accept         = 'application/json;odata=nometadata'
        'If-Match'     = '*'
        'x-ms-date'    = [datetime]::UtcNow.ToString(
            'R', [Globalization.CultureInfo]::InvariantCulture)
        'x-ms-version' = '2019-02-02'
    }
    $removedCount = 0

    do {
        $requestUri = "$tableUri()?`$filter=$([uri]::EscapeDataString($filter))&`$top=1000"
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $requestUri `
            -Authentication Bearer `
            -Token $AccessToken `
            -Headers $headers `
            -ErrorAction Stop
        $expiredRecords = @($response.value)
        foreach ($record in $expiredRecords) {
            $rowKey = [uri]::EscapeDataString([string] $record.RowKey)
            Invoke-RestMethod `
                -Method Delete `
                -Uri "$tableUri(PartitionKey='imports',RowKey='$rowKey')" `
                -Authentication Bearer `
                -Token $AccessToken `
                -Headers $headers `
                -ErrorAction Stop | Out-Null
            $removedCount++
        }
    } while ($expiredRecords.Count -eq 1000)

    return $removedCount
}

function ConvertTo-TagAuthorizationPolicy {
    <#
    .SYNOPSIS
    Converts group-to-tag rules into a normalized authorization policy.

    .PARAMETER Rules
    Rules in the form <group-object-id>=<tag1>,<tag2>, or rule objects with
    groupId, tags, and an optional administrativeUnitName.

    .PARAMETER AdministrativeUnitName
    Optional display name of the administrative unit to associate with every
    generated policy entry. Imported devices using a matching Group Tag are
    added to this regular or restricted management unit after their Entra
    device becomes available. Leave empty to disable automatic membership.

    .OUTPUTS
    PSCustomObject entries with groupId and tags properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Rules,

        [string] $AdministrativeUnitName
    )

    if (-not [string]::IsNullOrWhiteSpace(
            $AdministrativeUnitName) -and
        $AdministrativeUnitName.Trim().Length -gt 256) {
        throw 'Administrative unit name must not exceed 256 characters.'
    }

    $enteredRules = @($Rules | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($enteredRules.Count -eq 0) {
        throw 'At least one group and tag rule is required.'
    }

    $rulesByGroup = @{}
    $mauByGroup = @{}
    foreach ($rule in $enteredRules) {
        if ($rule -is [string]) {
            $separatorIndex = $rule.IndexOf('=')
            if ($separatorIndex -lt 1 -or $separatorIndex -eq $rule.Length - 1) {
                throw "Invalid TagAuthorizationRule '$rule'. Expected '<group-object-id>=<tag1>,<tag2>'."
            }
            $groupId = $rule.Substring(0, $separatorIndex).Trim()
            $tags = @($rule.Substring($separatorIndex + 1).Split(','))
            $ruleMauName = $AdministrativeUnitName
        }
        elseif ($rule -is [Collections.IDictionary]) {
            if (-not $rule.Contains('groupId') -or
                -not $rule.Contains('tags')) {
                throw 'Policy rule objects must contain groupId and tags properties.'
            }
            $groupId = [string] $rule['groupId']
            $tags = @($rule['tags'])
            $ruleMauName = if ($rule.Contains('administrativeUnitName')) {
                [string] $rule['administrativeUnitName']
            }
            else {
                $AdministrativeUnitName
            }
        }
        else {
            if (-not $rule.PSObject.Properties['groupId'] -or
                -not $rule.PSObject.Properties['tags']) {
                throw 'Policy rule objects must contain groupId and tags properties.'
            }
            $groupId = [string] $rule.groupId
            $tags = @($rule.tags)
            $ruleMauName = if ($rule.PSObject.Properties[
                    'administrativeUnitName']) {
                [string] $rule.administrativeUnitName
            }
            else {
                $AdministrativeUnitName
            }
        }

        $parsedGroupId = [guid]::Empty
        if (-not [guid]::TryParse($groupId, [ref] $parsedGroupId)) {
            throw "Group Object ID '$groupId' must be a GUID."
        }
        $normalizedGroupId = $parsedGroupId.ToString()

        $tags = @($tags | ForEach-Object {
            $_.Trim()
        } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Unique)
        if ($tags.Count -eq 0) {
            throw "At least one Device Tag is required for group '$normalizedGroupId'."
        }
        foreach ($tag in $tags) {
            if ($tag.Length -gt 128) {
                throw "Device Tag '$tag' must not exceed 128 characters."
            }
            if ($tag.Contains(',')) {
                throw "Device Tag '$tag' must not contain a comma."
            }
        }

        $normalizedMauName = ([string] $ruleMauName).Trim()
        if ($normalizedMauName.Length -gt 256) {
            throw 'Administrative unit name must not exceed 256 characters.'
        }
        if ($mauByGroup.ContainsKey($normalizedGroupId) -and
            $mauByGroup[$normalizedGroupId] -ne $normalizedMauName) {
            throw "Group '$normalizedGroupId' has conflicting administrative units."
        }

        $rulesByGroup[$normalizedGroupId] = @(
            @($rulesByGroup[$normalizedGroupId]) + $tags | Select-Object -Unique
        )
        $mauByGroup[$normalizedGroupId] = $normalizedMauName
    }

    return ,@($rulesByGroup.Keys | Sort-Object | ForEach-Object {
        $policyEntry = [ordered]@{
            groupId = $_
            tags    = @($rulesByGroup[$_] | Sort-Object)
        }
        if (-not [string]::IsNullOrWhiteSpace($mauByGroup[$_])) {
            $policyEntry.administrativeUnitName =
            $mauByGroup[$_]
        }
        [pscustomobject] $policyEntry
    })
}

function Resolve-AdministrativeUnitName {
    <#
    .SYNOPSIS
    Resolves the optional administrative unit for a tag.

    .PARAMETER Policy
    Collection of tag authorization policy entries containing tags and an
    optional administrativeUnitName property.

    .PARAMETER GroupTag
    Group Tag whose administrative unit name is resolved.

    .PARAMETER Principal
    Optional decoded Easy Auth principal. When supplied, only policy rules for
    the caller's Entra groups participate in RMAU resolution.

    .OUTPUTS
    System.String, or null when no administrative unit is configured for the
    Group Tag.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Policy = @(),

        [Parameter(Mandatory)]
        [string] $GroupTag,

        [object] $Principal
    )

    $callerGroupIds = if ($null -ne $Principal) {
        $groupClaimTypes = @(
            'groups',
            'http://schemas.microsoft.com/ws/2008/06/identity/claims/groups'
        )
        @($Principal.claims | Where-Object {
            $_.typ -in $groupClaimTypes
        } | ForEach-Object {
            [string] $_.val
        })
    }
    else {
        @()
    }
    $administrativeUnitNames = @($Policy | Where-Object {
        @($_.tags) -contains $GroupTag -and
        ($null -eq $Principal -or [string] $_.groupId -in $callerGroupIds) -and
        $_.PSObject.Properties['administrativeUnitName'] -and
        -not [string]::IsNullOrWhiteSpace(
            [string] $_.administrativeUnitName)
    } | ForEach-Object {
        ([string] $_.administrativeUnitName).Trim()
    } | Select-Object -Unique)

    if ($administrativeUnitNames.Count -gt 1) {
        throw "Group Tag '$GroupTag' maps to multiple administrative units."
    }
    return $administrativeUnitNames | Select-Object -First 1
}

function Resolve-EffectiveAdministrativeUnitName {
    <#
    .SYNOPSIS
    Resolves the effective administrative unit for queued work.

    .PARAMETER Policy
    Current tag authorization policy loaded when the queue item is processed.

    .PARAMETER GroupTag
    Authorized Group Tag stored in the queue item.

    .PARAMETER QueuedAdministrativeUnitName
    Optional administrative unit resolved when the import was accepted.

    .OUTPUTS
    System.String, or null when neither the current policy nor the queue item
    configures an administrative unit.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Policy = @(),

        [Parameter(Mandatory)]
        [string] $GroupTag,

        [string] $QueuedAdministrativeUnitName
    )

    $queuedName = $QueuedAdministrativeUnitName.Trim()
    $currentNames = @($Policy | Where-Object {
        @($_.tags) -contains $GroupTag -and
        $_.PSObject.Properties[
            'administrativeUnitName'] -and
        -not [string]::IsNullOrWhiteSpace(
            [string] $_.administrativeUnitName)
    } | ForEach-Object {
        ([string] $_.administrativeUnitName).Trim()
    } | Select-Object -Unique)

    if ($currentNames.Count -eq 1) {
        return $currentNames[0]
    }
    if ($currentNames.Count -gt 1) {
        $queuedMatch = @($currentNames | Where-Object {
            [string]::Equals(
                $_,
                $queuedName,
                [StringComparison]::OrdinalIgnoreCase)
        }) | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($queuedMatch)) {
            return $queuedMatch
        }
        throw "Group Tag '$GroupTag' maps to multiple administrative units and the queued value cannot disambiguate them."
    }
    if (-not [string]::IsNullOrWhiteSpace($queuedName)) {
        return $queuedName
    }
    return $null
}

function Resolve-EntraAdministrativeUnit {
    <#
    .SYNOPSIS
    Resolves a uniquely named Entra administrative unit.

    .PARAMETER AdministrativeUnitName
    Display name of the administrative unit. The name must uniquely identify
    an existing regular or restricted management administrative unit.

    .PARAMETER AccessToken
    Microsoft Graph access token used to resolve the administrative unit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateLength(1, 256)]
        [string] $AdministrativeUnitName,

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken
    )

    $escapedName = $AdministrativeUnitName.Trim().Replace("'", "''")
    $filter = [uri]::EscapeDataString("displayName eq '$escapedName'")
    $administrativeUnitResponse = Invoke-RestMethod `
        -Method Get `
        -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits?`$filter=$filter&`$select=id,displayName,isMemberManagementRestricted" `
        -Authentication Bearer `
        -Token $AccessToken `
        -ErrorAction Stop
    $matchingUnits = @($administrativeUnitResponse.value | Where-Object {
        [string]::Equals(
            [string] $_.displayName,
            $AdministrativeUnitName.Trim(),
            [StringComparison]::OrdinalIgnoreCase)
    })
    if ($matchingUnits.Count -eq 0) {
        throw "Administrative unit '$AdministrativeUnitName' was not found."
    }
    if ($matchingUnits.Count -gt 1) {
        throw "Administrative unit name '$AdministrativeUnitName' is not unique."
    }

    return $matchingUnits[0]
}

function Add-EntraDeviceToAdministrativeUnit {
    <#
    .SYNOPSIS
    Adds an Entra device to a named administrative unit.

    .PARAMETER AdministrativeUnitName
    Display name of the regular or restricted management administrative unit.
    The name must uniquely identify an existing unit.

    .PARAMETER DeviceObjectId
    Entra object ID of the device to add to the administrative unit.

    .PARAMETER AccessToken
    Microsoft Graph access token used to resolve the administrative unit,
    inspect its members, and add the device when required.

    .PARAMETER TestOnly
    Checks the administrative unit and current membership without adding the
    device.

    .OUTPUTS
    PSCustomObject containing the resolved administrative unit ID and whether
    membership was added.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateLength(1, 256)]
        [string] $AdministrativeUnitName,

        [Parameter(Mandatory)]
        [guid] $DeviceObjectId,

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken,

        [switch] $TestOnly
    )

    $administrativeUnit = Resolve-EntraAdministrativeUnit `
        -AdministrativeUnitName $AdministrativeUnitName `
        -AccessToken $AccessToken

    $deviceId = $DeviceObjectId.ToString()
    $memberFilter = [uri]::EscapeDataString("id eq '$deviceId'")
    $memberResponse = Invoke-RestMethod `
        -Method Get `
        -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits/$($administrativeUnit.id)/members?`$filter=$memberFilter&`$count=true&`$select=id" `
        -Headers @{ ConsistencyLevel = 'eventual' } `
        -Authentication Bearer `
        -Token $AccessToken `
        -ErrorAction Stop
    $isMember = @($memberResponse.value | Where-Object {
        [string] $_.id -eq $deviceId
    }).Count -gt 0
    if (-not $isMember -and -not $TestOnly) {
        Invoke-RestMethod `
            -Method Post `
            -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits/$($administrativeUnit.id)/members/`$ref" `
            -Authentication Bearer `
            -Token $AccessToken `
            -ContentType 'application/json' `
            -Body (@{
                '@odata.id' = "https://graph.microsoft.com/v1.0/devices/$deviceId"
            } | ConvertTo-Json -Compress) `
            -ErrorAction Stop | Out-Null
    }

    return [pscustomobject]@{
        AdministrativeUnitId = [string] $administrativeUnit.id
        IsMember             = $isMember
        MembershipAdded      = -not $isMember -and -not $TestOnly
    }
}

function ConvertTo-EntraDeviceExtensionAttributes {
    <#
    .SYNOPSIS
    Creates a Microsoft Graph device extensionAttributes update payload.

    .PARAMETER ExtensionAttribute
    Target attribute from extensionAttribute1 through extensionAttribute15.

    .PARAMETER GroupTag
    Authorized Autopilot Group Tag written to the selected attribute.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^extensionAttribute(?:[1-9]|1[0-5])$')]
        [string] $ExtensionAttribute,

        [Parameter(Mandatory)]
        [ValidateLength(1, 128)]
        [string] $GroupTag
    )

    return [ordered]@{
        extensionAttributes = [ordered]@{
            $ExtensionAttribute = $GroupTag
        }
    }
}

function Get-AutoPilotDeviceRegistrationId {
    <#
    .SYNOPSIS
    Returns the registered Autopilot identity ID from a completed import.

    .PARAMETER ImportedDevice
    Imported Windows Autopilot device identity whose state contains the
    deviceRegistrationId returned by Microsoft Graph.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $ImportedDevice)

    $registrationId = [guid]::Empty
    if (-not $ImportedDevice.state -or
        $null -eq $ImportedDevice.state.PSObject.Properties['deviceRegistrationId'] -or
        -not [guid]::TryParse(
            [string] $ImportedDevice.state.deviceRegistrationId,
            [ref] $registrationId)) {
        throw 'The Autopilot device registration is not available yet.'
    }
    return $registrationId
}

function Compare-TagAuthorizationPolicyGroups {
    <#
    .SYNOPSIS
    Compares group membership between two tag authorization policies.

    .PARAMETER PreviousPolicy
    Existing tag authorization policy whose group IDs form the comparison
    baseline.

    .PARAMETER UpdatedPolicy
    Updated tag authorization policy whose group IDs are compared with the
    previous policy.

    .OUTPUTS
    PSCustomObject containing AddedGroupIds and RemovedGroupIds.
    #>
    [CmdletBinding()]
    param(
        [object[]] $PreviousPolicy = @(),

        [object[]] $UpdatedPolicy = @()
    )

    $previousGroupIds = @($PreviousPolicy.groupId | ForEach-Object {
        ([guid] $_).ToString()
    })
    $updatedGroupIds = @($UpdatedPolicy.groupId | ForEach-Object {
        ([guid] $_).ToString()
    })

    return [pscustomobject]@{
        AddedGroupIds = @($updatedGroupIds | Where-Object { $_ -notin $previousGroupIds })
        RemovedGroupIds = @($previousGroupIds | Where-Object { $_ -notin $updatedGroupIds })
    }
}

function Test-TagPolicyManagerPrincipal {
    <#
    .SYNOPSIS
    Tests whether a caller is an explicitly configured tag-policy manager.

    .PARAMETER Principal
    Decoded Easy Auth principal containing object and group claims.

    .PARAMETER ManagerPolicy
    Policy containing a principalIds collection of user or group object IDs.

    .OUTPUTS
    System.Boolean. True when the caller or one of its claimed groups is listed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Principal,

        [Parameter(Mandatory)]
        [object] $ManagerPolicy
    )

    $configuredPrincipalIds = @('principalIds', 'installerPrincipalId', 'additionalPrincipalIds' |
        Where-Object { $ManagerPolicy.PSObject.Properties.Name -contains $_ } |
        ForEach-Object { @($ManagerPolicy.$_) })
    $allowedPrincipalIds = @($configuredPrincipalIds | ForEach-Object {
        $parsedId = [guid]::Empty
        if ([guid]::TryParse([string] $_, [ref] $parsedId)) {
            $parsedId.ToString()
        }
    } | Select-Object -Unique)
    $callerPrincipalIds = @($Principal.claims | Where-Object {
        $_.typ -in @(
            'oid',
            'groups',
            'http://schemas.microsoft.com/identity/claims/objectidentifier',
            'http://schemas.microsoft.com/ws/2008/06/identity/claims/groups'
        )
    } | ForEach-Object {
        $parsedId = [guid]::Empty
        if ([guid]::TryParse([string] $_.val, [ref] $parsedId)) {
            $parsedId.ToString()
        }
    })

    return @($callerPrincipalIds | Where-Object {
        $_ -in $allowedPrincipalIds
    }).Count -gt 0
}

function Test-IntuneRoleAdministrator {
    <#
    .SYNOPSIS
    Tests whether a caller has an Intune Role Administrator assignment.

    .PARAMETER Principal
    Decoded Easy Auth principal containing object and group claims.

    .OUTPUTS
    System.Boolean. True when an Intune Role Administrator assignment covers
    the caller or one of its claimed groups.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Principal
    )

    $tokenResult = Get-AzAccessToken `
        -ResourceUrl 'https://graph.microsoft.com/' `
        -ErrorAction Stop
    $accessToken = if ($tokenResult.Token -is [Security.SecureString]) {
        ConvertFrom-SecureString -SecureString $tokenResult.Token -AsPlainText
    }
    else {
        [string] $tokenResult.Token
    }
    $headers = @{ Authorization = "Bearer $accessToken" }

    $roleAssignments = @()
    $requestUri = "https://graph.microsoft.com/v1.0/deviceManagement/roleAssignments?`$expand=roleDefinition(`$select=id,displayName)&`$select=id,members"
    while ($requestUri) {
        $assignmentResponse = Invoke-RestMethod `
            -Method Get `
            -Uri $requestUri `
            -Headers $headers
        $roleAssignments += @($assignmentResponse.value)
        $requestUri = if ($assignmentResponse.PSObject.Properties.Name -contains '@odata.nextLink') {
            [string] $assignmentResponse.'@odata.nextLink'
        }
        else {
            $null
        }
    }

    return Test-IntuneRoleAdministratorAssignment `
        -Principal $Principal `
        -RoleAssignment $roleAssignments
}

function Test-TagManagerPolicyAdministratorRole {
    <#
    .SYNOPSIS
    Tests whether Azure role assignments permit changing the manager policy.

    .PARAMETER RoleAssignment
    Effective Azure role assignments for the current principal and its groups.

    .PARAMETER FunctionResourceId
    Full Azure resource ID of the Function App.

    .OUTPUTS
    System.Boolean. True only for Owner or Contributor at the Function scope or
    an ancestor scope.
    #>
    [CmdletBinding()]
    param(
        [object[]] $RoleAssignment = @(),

        [Parameter(Mandatory)]
        [string] $FunctionResourceId
    )

    $normalizedResourceId = $FunctionResourceId.TrimEnd('/')
    return @($RoleAssignment | Where-Object {
        $assignmentScope = ([string] $_.Scope).TrimEnd('/')
        $_.RoleDefinitionName -in @('Owner', 'Contributor') -and
        ($normalizedResourceId -eq $assignmentScope -or
            $normalizedResourceId.StartsWith("$assignmentScope/", [StringComparison]::OrdinalIgnoreCase))
    }).Count -gt 0
}

function Test-IntuneRoleAdministratorAssignment {
    <#
    .SYNOPSIS
    Tests whether a caller is covered by an Intune Role Administrator assignment.

    .PARAMETER Principal
    Decoded Easy Auth principal containing object and group claims.

    .PARAMETER RoleAssignment
    Intune deviceAndAppManagementRoleAssignment objects with roleDefinition and
    members properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Principal,

        [object[]] $RoleAssignment = @()
    )

    $callerPrincipalIds = @($Principal.claims | Where-Object {
        $_.typ -in @(
            'oid',
            'groups',
            'http://schemas.microsoft.com/identity/claims/objectidentifier',
            'http://schemas.microsoft.com/ws/2008/06/identity/claims/groups'
        )
    } | ForEach-Object { [string] $_.val })
    $assignedPrincipalIds = @($RoleAssignment | Where-Object {
        $roleDefinitionProperty = $_.PSObject.Properties['roleDefinition']
        $roleDefinitionProperty -and
            $roleDefinitionProperty.Value -and
            $roleDefinitionProperty.Value.PSObject.Properties['displayName'] -and
            $roleDefinitionProperty.Value.displayName -eq 'Intune Role Administrator'
    } | ForEach-Object {
        @($_.members) | ForEach-Object { [string] $_ }
    })

    return @($callerPrincipalIds | Where-Object {
        $_ -in $assignedPrincipalIds
    }).Count -gt 0
}

function ConvertFrom-ClientPrincipalHeader {
    <#
    .SYNOPSIS
    Decodes an Azure App Service Easy Auth client-principal header.

    .PARAMETER HeaderValue
    Base64-encoded UTF-8 JSON value from the x-ms-client-principal header.

    .OUTPUTS
    PSCustomObject containing the decoded Easy Auth principal and claims.

    .NOTES
    Throws ArgumentException when Base64, JSON, or claims are invalid.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $HeaderValue
    )

    try {
        $json = [System.Text.Encoding]::UTF8.GetString(
            [System.Convert]::FromBase64String($HeaderValue)
        )
        $principal = $json | ConvertFrom-Json
    }
    catch {
        throw [System.ArgumentException]::new('The client principal header is invalid.')
    }

    if (-not $principal.claims) {
        throw [System.ArgumentException]::new('The client principal does not contain claims.')
    }

    return $principal
}

function Test-ClientPrincipalRole {
    <#
    .SYNOPSIS
    Tests whether an Easy Auth principal has a required app role.

    .PARAMETER Principal
    Decoded Easy Auth principal containing a claims collection.

    .PARAMETER RequiredRole
    Exact app-role value required for authorization.

    .OUTPUTS
    System.Boolean. True when a matching role claim exists; otherwise false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Principal,

        [Parameter(Mandatory)]
        [string] $RequiredRole
    )

    $roleClaimTypes = @(
        'roles',
        'http://schemas.microsoft.com/ws/2008/06/identity/claims/role'
    )

    if ($Principal.role_typ) {
        $roleClaimTypes += [string] $Principal.role_typ
    }

    return @($Principal.claims | Where-Object {
        $_.typ -in $roleClaimTypes -and $_.val -eq $RequiredRole
    }).Count -gt 0
}

function Get-CurrentPolicyPrincipal {
    <#
    .SYNOPSIS
    Resolves the caller's current memberships in policy groups.

    .PARAMETER Principal
    Decoded Easy Auth principal containing the caller object ID.

    .PARAMETER Policy
    Collection of rules whose group IDs are checked through Microsoft Graph.

    .PARAMETER AccessToken
    Microsoft Graph token acquired by the Function managed identity.

    .OUTPUTS
    PSCustomObject containing the original non-group claims and current group
    claims returned by Microsoft Graph.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Principal,

        [Parameter(Mandatory)]
        [object[]] $Policy,

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken
    )

    $objectIdClaimTypes = @(
        'oid',
        'http://schemas.microsoft.com/identity/claims/objectidentifier'
    )
    $objectId = @($Principal.claims | Where-Object {
        $_.typ -in $objectIdClaimTypes
    } | Select-Object -First 1).val
    $parsedObjectId = [guid]::Empty
    if (-not [guid]::TryParse([string] $objectId, [ref] $parsedObjectId)) {
        throw [System.ArgumentException]::new(
            'The client principal does not contain a valid object ID.'
        )
    }

    $policyGroupIds = @($Policy | ForEach-Object {
        $parsedGroupId = [guid]::Empty
        if (-not [guid]::TryParse([string] $_.groupId, [ref] $parsedGroupId)) {
            throw [System.ArgumentException]::new(
                "Policy group ID '$($_.groupId)' is invalid."
            )
        }
        $parsedGroupId.ToString()
    } | Select-Object -Unique)

    $currentGroupIds = @()
    for ($offset = 0; $offset -lt $policyGroupIds.Count; $offset += 20) {
        $lastIndex = [Math]::Min($offset + 19, $policyGroupIds.Count - 1)
        $groupIdBatch = @($policyGroupIds[$offset..$lastIndex])
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri "https://graph.microsoft.com/v1.0/users/$($parsedObjectId.ToString())/checkMemberGroups" `
            -Authentication Bearer `
            -Token $AccessToken `
            -ContentType 'application/json' `
            -Body (@{ groupIds = $groupIdBatch } | ConvertTo-Json -Compress) `
            -ErrorAction Stop
        $currentGroupIds += @($response.value | Where-Object {
            [string] $_ -in $groupIdBatch
        })
    }

    $groupClaimTypes = @(
        'groups',
        'http://schemas.microsoft.com/ws/2008/06/identity/claims/groups'
    )
    $resolvedClaims = @($Principal.claims | Where-Object {
        $_.typ -notin $groupClaimTypes
    }) + @($currentGroupIds | Select-Object -Unique | ForEach-Object {
        [pscustomobject]@{ typ = 'groups'; val = [string] $_ }
    })
    $resolvedPrincipal = [ordered]@{}
    foreach ($property in $Principal.PSObject.Properties) {
        $resolvedPrincipal[$property.Name] = if ($property.Name -eq 'claims') {
            $resolvedClaims
        }
        else {
            $property.Value
        }
    }
    return [pscustomobject] $resolvedPrincipal
}

function Resolve-AuthorizedGroupTag {
    <#
    .SYNOPSIS
    Resolves a requested Group Tag authorized for the caller's groups.

    .PARAMETER Principal
    Decoded Easy Auth principal containing Entra security-group claims.

    .PARAMETER Policy
    Collection of rules with groupId and tags properties.

    .PARAMETER RequestedGroupTag
    Group Tag requested by the API caller. Matching is case-insensitive.

    .OUTPUTS
    System.String. Returns the configured Group Tag with its canonical casing.

    .NOTES
    Throws UnauthorizedAccessException when no caller group permits the tag.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Principal,

        [Parameter(Mandatory)]
        [object[]] $Policy,

        [Parameter(Mandatory)]
        [string] $RequestedGroupTag
    )

    $requestedTag = $RequestedGroupTag.Trim()
    if ([string]::IsNullOrWhiteSpace($requestedTag) -or $requestedTag.Length -gt 128) {
        throw [System.ArgumentException]::new('groupTag is invalid.')
    }

    $groupClaimTypes = @(
        'groups',
        'http://schemas.microsoft.com/ws/2008/06/identity/claims/groups'
    )
    $callerGroupIds = @($Principal.claims | Where-Object {
        $_.typ -in $groupClaimTypes
    } | ForEach-Object {
        [string] $_.val
    })

    foreach ($rule in $Policy) {
        $configuredTag = @($rule.tags | Where-Object {
            [string] $_ -ieq $requestedTag
        } | Select-Object -First 1)
        if ([string] $rule.groupId -in $callerGroupIds -and $configuredTag.Count -gt 0) {
            return [string] $configuredTag[0]
        }
    }

    throw [System.UnauthorizedAccessException]::new(
        'The requested groupTag is not allowed for the caller groups.'
    )
}

function Get-AuthorizedGroupTags {
    <#
    .SYNOPSIS
    Returns all Group Tags authorized for the caller's Entra groups.

    .PARAMETER Principal
    Decoded Easy Auth principal containing Entra security-group claims.

    .PARAMETER Policy
    Collection of rules with groupId and tags properties.

    .OUTPUTS
    System.String values sorted by their configured Group Tag names.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Principal,

        [Parameter(Mandatory)]
        [object[]] $Policy
    )

    $groupClaimTypes = @(
        'groups',
        'http://schemas.microsoft.com/ws/2008/06/identity/claims/groups'
    )
    $callerGroupIds = @($Principal.claims | Where-Object {
        $_.typ -in $groupClaimTypes
    } | ForEach-Object {
        [string] $_.val
    })

    return @($Policy | Where-Object {
        [string] $_.groupId -in $callerGroupIds
    } | ForEach-Object {
        @($_.tags)
    } | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string] $_)
    } | ForEach-Object {
        ([string] $_).Trim()
    } | Sort-Object -Unique)
}

function ConvertTo-AutoPilotImportPayload {
    <#
    .SYNOPSIS
    Creates a validated Microsoft Graph Autopilot import payload.

    .PARAMETER RequestBody
    Request object containing serialNumber and Base64 hardwareIdentifier.

    .PARAMETER GroupTag
    Server-authorized Group Tag. Any Group Tag in RequestBody is ignored.

    .OUTPUTS
    OrderedDictionary suitable for the importedWindowsAutopilotDeviceIdentities
    Microsoft Graph endpoint.

    .NOTES
    Validates required fields, size limits, and Base64 encoding before returning
    the payload.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $RequestBody,

        [Parameter(Mandatory)]
        [ValidateLength(1, 128)]
        [string] $GroupTag
    )

    $serialNumber = [string] $RequestBody.serialNumber
    $hardwareIdentifier = [string] $RequestBody.hardwareIdentifier

    if ([string]::IsNullOrWhiteSpace($serialNumber)) {
        throw [System.ArgumentException]::new('serialNumber is required.')
    }

    $serialNumber = $serialNumber.Trim()
    if ($serialNumber.Length -gt 128) {
        throw [System.ArgumentException]::new('serialNumber must not exceed 128 characters.')
    }

    if ([string]::IsNullOrWhiteSpace($hardwareIdentifier)) {
        throw [System.ArgumentException]::new('hardwareIdentifier is required.')
    }

    if ($hardwareIdentifier.Length -gt 65536) {
        throw [System.ArgumentException]::new('hardwareIdentifier is too large.')
    }

    try {
        $decodedHash = [System.Convert]::FromBase64String($hardwareIdentifier)
    }
    catch {
        throw [System.ArgumentException]::new('hardwareIdentifier must be valid Base64.')
    }

    if ($decodedHash.Length -eq 0) {
        throw [System.ArgumentException]::new('hardwareIdentifier must not be empty.')
    }

    return [ordered]@{
        '@odata.type'      = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
        groupTag          = $GroupTag
        serialNumber      = $serialNumber
        hardwareIdentifier = $hardwareIdentifier
    }
}

Export-ModuleMember -Function @(
    'ConvertFrom-BlobBindingContent',
    'Get-ImportAuditTableUri',
    'Get-ImportAuditAccessToken',
    'Get-DeviceHashSha256',
    'Set-ImportAuditRecord',
    'Get-ImportAuditRecords',
    'Get-ImportAuditRetentionCutoffUtc',
    'Get-ImportAuditHistory',
    'Remove-ExpiredImportAuditRecords',
    'ConvertTo-TagAuthorizationPolicy',
    'ConvertTo-EntraDeviceExtensionAttributes',
    'Resolve-AdministrativeUnitName',
    'Resolve-EffectiveAdministrativeUnitName',
    'Resolve-EntraAdministrativeUnit',
    'Add-EntraDeviceToAdministrativeUnit',
    'Get-AutoPilotDeviceRegistrationId',
    'Compare-TagAuthorizationPolicyGroups',
    'Test-TagPolicyManagerPrincipal',
    'Test-IntuneRoleAdministrator',
    'Test-TagManagerPolicyAdministratorRole',
    'Test-IntuneRoleAdministratorAssignment',
    'ConvertFrom-ClientPrincipalHeader',
    'Test-ClientPrincipalRole',
    'Get-CurrentPolicyPrincipal',
    'Resolve-AuthorizedGroupTag',
    'Get-AuthorizedGroupTags',
    'ConvertTo-AutoPilotImportPayload'
)