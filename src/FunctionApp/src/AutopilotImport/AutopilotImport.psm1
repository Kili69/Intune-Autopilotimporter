# Project-Version: 1.4.20261020.15
# Author: andreas.lucas@outlook.com (aka Kili)

# Copyright 2026 Andreas Lucas
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the project root for license information.

<#
.SYNOPSIS
Provides validation and authorization helpers for the Autopilot import API.

.DESCRIPTION
Shared core for HTTP triggers, queued device processing and audit retention.
Includes blob decoding, Storage Table audit/state access, policy normalization,
Easy Auth claim handling, current Graph membership checks, Autopilot payload
validation and synchronization of policy-managed device groups and AUs.

Pure transformation/authorization functions do not call external services.
Graph and Storage helpers require appropriately scoped access tokens; token
acquisition uses the current Az context, normally the Function managed identity.

.NOTES
Functions use named parameters rather than pipeline parameter binding.
Network/validation errors generally propagate to the calling Function, which
maps them to HTTP responses or queue retries. This module does not establish
an Azure sign-in or validate the authenticity of an Easy Auth header.
Importing it enables strict mode in the module scope. Import alone does not
perform network requests or mutate Azure resources.
#>

Set-StrictMode -Version Latest

function ConvertFrom-BlobBindingContent {
    <#
    .SYNOPSIS
    Converts an Azure Functions blob input binding value to text.

    .DESCRIPTION
    Accepts worker representations of the same blob: strings, UTF-8 bytes,
    streams or nested Content wrappers. Dictionaries, custom objects and other
    enumerables are serialized as JSON at depth 20; other values use ToString().

    .PARAMETER Value
    Blob binding value represented as text, bytes, a stream, or a content
    wrapper supplied by the Functions PowerShell worker.

    .OUTPUTS
    System.String, or null when the binding has no value.

    .EXAMPLE
    ConvertFrom-BlobBindingContent -Value ([Text.Encoding]::UTF8.GetBytes('[]'))

    Returns the JSON text [] from a byte-array binding.

    .NOTES
    Seekable streams are rewound and consumed, but remain open. Text is not
    validated as JSON. Conversion, stream and serialization errors propagate.
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
        # Bindings may reuse a stream whose cursor is no longer at the start.
        # leaveOpen below keeps ownership with the Functions worker.
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
        # Unwrap recursively because worker binding wrappers can be nested.
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

    .DESCRIPTION
    Builds a public-cloud Table Storage URI from
    AzureWebJobsStorage__accountName and IMPORT_AUDIT_TABLE_NAME. The table
    defaults to importaudit. This helper does not create or contact the table.

    .OUTPUTS
    System.String. HTTPS table URI without entity keys or a query string.

    .EXAMPLE
    $tableUri = Get-ImportAuditTableUri

    Resolves the table endpoint using the Function's current settings.

    .NOTES
    Throws when the account name is blank or the table name is not 3..63
    alphanumeric characters beginning with a letter. The account name is not
    otherwise validated here.
    #>
    [CmdletBinding()]
    param()

    $storageAccountName = $env:AzureWebJobsStorage__accountName
    if ([string]::IsNullOrWhiteSpace($storageAccountName)) {
        throw 'AzureWebJobsStorage__accountName is required for import audit history.'
    }

    # Keep audit reads/writes and device-policy state on the same table.
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
    Acquires an Azure Storage token through the current Azure context.

    .DESCRIPTION
    Requests the https://storage.azure.com/ audience through Get-AzAccessToken.
    Returns SecureString consistently across Az.Accounts versions. In Azure,
    profile.ps1 normally establishes the managed-identity context beforehand.

    .OUTPUTS
    System.Security.SecureString containing the Storage access token.

    .EXAMPLE
    $storageToken = Get-ImportAuditAccessToken

    Acquires a token for the audit/state Storage helpers.

    .NOTES
    Requires Az.Accounts and an authenticated context. Token acquisition
    failures propagate; this helper does not sign in or assign data roles.
    #>
    [CmdletBinding()]
    param()

    $tokenResult = Get-AzAccessToken `
        -ResourceUrl 'https://storage.azure.com/' `
        -ErrorAction Stop
    if ($tokenResult.Token -is [Security.SecureString]) {
        return $tokenResult.Token
    }
    # Older Az.Accounts releases return text rather than SecureString.
    return ConvertTo-SecureString `
        ([string] $tokenResult.Token) `
        -AsPlainText `
        -Force
}

function Get-DeviceHashSha256 {
    <#
    .SYNOPSIS
    Returns a stable SHA-256 index for a Base64 Autopilot device hash.

    .DESCRIPTION
    Decodes the Base64 hardware hash and hashes the decoded bytes rather than
    its textual representation. Formats the digest as lowercase hexadecimal.

    .PARAMETER DeviceHash
    Nonempty Base64 device hash, limited to 65,536 input characters.

    .OUTPUTS
    System.String. Exactly 64 lowercase hexadecimal characters.

    .EXAMPLE
    Get-DeviceHashSha256 -DeviceHash 'AQID'

    Computes the index for the three decoded bytes 1, 2 and 3.

    .NOTES
    Throws ArgumentException for invalid Base64 or an empty decoded value.
    The result is a lookup index, not a replacement hardware hash for Graph.
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

    # Index the underlying bytes so permitted Base64 whitespace does not
    # produce different lookup keys for the same hardware hash.
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($deviceHashBytes)
    ).ToLowerInvariant()
}

function Test-ImportAuditHttpStatus {
    <#
    .SYNOPSIS
    Tests an audit request error for a particular HTTP status code.

    .DESCRIPTION
    Reads Exception.Response.StatusCode when present; otherwise checks the
    Exception.Data StatusCode entry. Supports REST errors and synthetic errors
    used by tests without depending on one concrete HTTP exception type.

    .PARAMETER ErrorRecord
    PowerShell error record, normally the current catch variable.

    .PARAMETER StatusCode
    Integer HTTP status to compare, such as 404 or 409.

    .OUTPUTS
    System.Boolean. False when neither supported status representation exists.

    .EXAMPLE
    Test-ImportAuditHttpStatus -ErrorRecord $errorRecord -StatusCode 404

    Checks whether a failed audit operation reported a missing entity.

    .NOTES
    Internal helper, not exported. Response status takes precedence over Data.
    Values must be convertible to an integer; this helper does not retry.
    #>
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

    .DESCRIPTION
    Uses PartitionKey imports and the GUID ImportId as RowKey. MERGE preserves
    unrelated existing properties. A missing entity is inserted with POST; an
    insertion conflict retries the merge to handle a concurrent creator.

    .PARAMETER ImportId
    Individual import or tag-change operation GUID, not a batch import ID.

    .PARAMETER Properties
    Dictionary of properties to merge. Null values and attempted PartitionKey/
    RowKey overrides are ignored; null does not delete an existing property.

    .PARAMETER AccessToken
    SecureString Storage token with permission to write table entities.

    .OUTPUTS
    None. REST response bodies are suppressed.

    .EXAMPLE
    Set-ImportAuditRecord -ImportId $importId -Properties @{
        processingCompletedAtUtc = [datetime]::UtcNow.ToString('o')
    } -AccessToken $storageToken

    Adds the worker completion marker without replacing the whole audit row.

    .NOTES
    Uses If-Match * rather than ETag concurrency checks. Only a 404 triggers
    insertion and a 409 on insertion triggers another merge; other errors
    propagate. Recursive conflict retries have no explicit attempt limit.
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
        # Keys belong to the audit schema, and null means "leave unchanged".
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
        # A new entity cannot use the conditional merge header.
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

function Get-ProcessingFailureAudit {
    <#
    .SYNOPSIS
    Converts a queue-worker failure into audit properties.

    .DESCRIPTION
    Extracts the HTTP status and Microsoft Graph error message from an error
    record, adds remediation guidance for restricted management administrative
    units, and returns the audit properties for the failed attempt. Expected
    waits for asynchronous Intune objects are only recorded on the final
    attempt so normal imports do not show errors while they are retried.

    .PARAMETER ErrorRecord
    PowerShell error record raised by the worker.

    .PARAMETER Step
    Processing step that failed, for example extensionAttributes.

    .PARAMETER Attempt
    Queue dequeue count of the current invocation.

    .PARAMETER MaxAttempts
    Configured queue maxDequeueCount. The attempt reaching this value is final.

    .OUTPUTS
    PSCustomObject with Message, StatusCode, IsFinal, IsFailed and Properties.
    Properties is empty when the failure should not be audited.

    .EXAMPLE
    $failure = Get-ProcessingFailureAudit -ErrorRecord $_ -Step 'extensionAttributes' -Attempt 1

    .NOTES
    HTTP 400, 401 and 403 errors require administrator action and mark the
    operation as failed immediately, while the queue still retries the
    message so a later permission fix can complete it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord] $ErrorRecord,

        [Parameter(Mandatory)]
        [string] $Step,

        [ValidateRange(1, [int]::MaxValue)]
        [int] $Attempt = 1,

        [ValidateRange(1, [int]::MaxValue)]
        [int] $MaxAttempts = 24
    )

    $statusCode = $null
    $exception = $ErrorRecord.Exception
    if ($exception.PSObject.Properties['Response'] -and $exception.Response -and
        $exception.Response.PSObject.Properties['StatusCode']) {
        $statusCode = [int] $exception.Response.StatusCode
    }
    elseif ($exception.Data.Contains('StatusCode')) {
        $statusCode = [int] $exception.Data['StatusCode']
    }

    $detail = $null
    if ($ErrorRecord.ErrorDetails -and
        -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
        try {
            $graphError = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
            if ($graphError.PSObject.Properties['error'] -and $graphError.error.message) {
                $detail = [string] $graphError.error.message
            }
        }
        catch {
            $detail = [string] $ErrorRecord.ErrorDetails.Message
        }
    }
    if ([string]::IsNullOrWhiteSpace($detail)) {
        $detail = [string] $exception.Message
    }
    $message = if ($statusCode) { "HTTP ${statusCode}: $($detail.Trim())" } else { $detail.Trim() }
    if ($statusCode -eq 403 -and $detail -match 'restricted management administrative unit') {
        $message += ' Assign the Function managed identity the custom role ''Autopilot Import Device Attribute Writer'' scoped to the restricted management administrative unit that contains the device. Install-AutopilotImport.ps1, Update-AutopilotImport.ps1 and Grant-ManagedIdentityAdministrativeUnitRole.ps1 create and assign it automatically for restricted administrative units used by rules; new assignments can take up to 24 hours to reach the managed identity token.'
    }
    if ($message.Length -gt 2000) {
        $message = $message.Substring(0, 2000)
    }

    $isFinal = $Attempt -ge $MaxAttempts
    $isFailed = $isFinal -or $statusCode -in @(400, 401, 403)
    $isExpectedWait = $null -eq $statusCode -and $detail -match 'is not available yet'
    $properties = [ordered]@{}
    if ($isFinal -or -not $isExpectedWait) {
        $now = [datetime]::UtcNow.ToString('o')
        $properties.processingErrorAtUtc = $now
        $properties.processingError = $message
        $properties.processingErrorStep = $Step
        $properties.processingAttempt = $Attempt
        $properties.processingMaxAttempts = $MaxAttempts
        $properties.processingErrorStatusCode = if ($statusCode) { $statusCode } else { 0 }
        if ($isFailed) {
            $properties.processingFailedAtUtc = $now
        }
    }

    return [pscustomobject]@{
        Message    = $message
        StatusCode = $statusCode
        IsFinal    = $isFinal
        IsFailed   = $isFailed -and $properties.Count -gt 0
        Properties = $properties
    }
}

function Test-ProcessingFailed {
    <#
    .SYNOPSIS
    Tests whether an audit record reports an unresolved processing failure.

    .PARAMETER AuditRecord
    Audit table entity, or null when no record exists.

    .OUTPUTS
    System.Boolean. True when processingFailedAtUtc is set and no later
    processingCompletedAtUtc supersedes it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] $AuditRecord)

    if (-not $AuditRecord -or -not $AuditRecord.PSObject.Properties['processingFailedAtUtc'] -or
        [string]::IsNullOrWhiteSpace([string] $AuditRecord.processingFailedAtUtc)) {
        return $false
    }
    if (-not $AuditRecord.PSObject.Properties['processingCompletedAtUtc'] -or
        [string]::IsNullOrWhiteSpace([string] $AuditRecord.processingCompletedAtUtc)) {
        return $true
    }
    return [datetimeoffset] [string] $AuditRecord.processingCompletedAtUtc -lt
        [datetimeoffset] [string] $AuditRecord.processingFailedAtUtc
}

function Get-ImportAuditRecords {
    <#
    .SYNOPSIS
    Returns audit records indexed by Autopilot import ID.

    .DESCRIPTION
    Deduplicates IDs and queries the imports partition in batches of up to 20
    RowKey comparisons. Missing IDs are omitted from the returned dictionary.

    .PARAMETER ImportId
    Individual import/tag-change operation GUIDs whose audit rows are needed.

    .PARAMETER AccessToken
    SecureString Storage token with table-entity read access.

    .OUTPUTS
    System.Collections.Hashtable keyed by the returned records' RowKey strings.
    Values are raw Storage entities, including internal audit properties.

    .EXAMPLE
    $records = Get-ImportAuditRecords -ImportId $importId -AccessToken $storageToken
    $record = $records[$importId.ToString()]

    Looks up one audit entity by its normalized operation GUID.

    .NOTES
    Does not enforce retention, owner authorization or public-field projection.
    Callers must apply those checks. REST/configuration errors propagate.
    Each batch uses one request and does not follow Storage continuation.
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
    # Bound the number of OR clauses per request rather than issuing one
    # network request for every individual import.
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

    .DESCRIPTION
    Subtracts the requested number of days from ReferenceUtc. No records are
    queried or deleted; callers use the result for history and cleanup filters.

    .PARAMETER RetentionDays
    Number of retained days, 1..3650. Defaults to 30.

    .PARAMETER ReferenceUtc
    Reference instant, normally UTC now. Accepts DateTimeOffset; its offset
    is preserved by AddDays, and Storage callers convert it to UTC text.

    .OUTPUTS
    System.DateTimeOffset representing the cutoff instant.

    .EXAMPLE
    Get-ImportAuditRetentionCutoffUtc -RetentionDays 30 `
        -ReferenceUtc ([datetimeoffset]'2026-10-16T12:00:00Z')

    Returns the instant 2026-09-16T12:00:00Z.
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

    .DESCRIPTION
    Queries the imports partition at or after SinceUtc. Explicit import,
    serial-number, user and hardware-hash-index predicates are combined with
    OR. Only when none are supplied is ActorObjectId applied. Without either,
    all records within the time window are eligible.

    Reads all Storage pages before sorting by requestReceivedAtUtc (falling
    back to Timestamp) descending and returning at most Top entries.

    .PARAMETER ImportId
    Optional individual import/tag-change GUID filters.

    .PARAMETER SerialNumber
    Optional serial-number equality filters. Blank entries are ignored.

    .PARAMETER ActorUserPrincipalName
    Optional requester-UPN equality filters. Blank entries are ignored.

    .PARAMETER DeviceHashSha256
    Optional SHA-256 index equality filters, not raw hardware hashes.

    .PARAMETER ActorObjectId
    Default owner restriction, ignored when any explicit identifier filter is
    present. The HTTP caller must authorize broader lookup modes beforehand.

    .PARAMETER SinceUtc
    Inclusive lower bound for requestReceivedAtUtc, formatted as UTC text.

    .PARAMETER Top
    Final result limit, 1..1000. Defaults to 100; not the Storage page size.

    .PARAMETER AccessToken
    SecureString Storage token with table-entity read access.

    .OUTPUTS
    Raw audit entities, newest first, emitted to the pipeline. Call with @()
    when a stable zero/one/many array is required.

    .EXAMPLE
    $history = @(Get-ImportAuditHistory -ActorObjectId $actorId `
        -SinceUtc (Get-ImportAuditRetentionCutoffUtc) -Top 100 `
        -AccessToken $storageToken)

    Retrieves the actor's most recent retained operations.

    .NOTES
    Does not authorize callers or redact internal properties. HTTP handlers
    perform authorization and response projection. REST/configuration errors
    and invalid sortable timestamps propagate.
    #>
    [CmdletBinding()]
    param(
        [guid[]] $ImportId = @(),

        [string[]] $SerialNumber = @(),

        [string[]] $ActorUserPrincipalName = @(),

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
        @($ActorUserPrincipalName | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Unique | ForEach-Object {
            "actorUserPrincipalName eq '$($_.Replace("'", "''"))'"
        })
        @($DeviceHashSha256 | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Unique | ForEach-Object {
            "deviceHashSha256 eq '$($_.Replace("'", "''"))'"
        })
    )
    # Explicit filters are alternatives, not an intersection with the owner
    # filter. The calling endpoint is responsible for authorizing that scope.
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

    # Table Storage continuation uses response headers, not Graph nextLink.
    # Fetch all matching pages so the final Top is globally newest-first.
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

function ConvertTo-AuditTimestamp {
    <#
    .SYNOPSIS
    Formats an audit timestamp as an ISO 8601 UTC string.

    .DESCRIPTION
    Table Storage responses deserialized by Invoke-RestMethod turn ISO strings
    into DateTime values whose default string form is culture-style and has no
    time zone, which browsers interpret as local time. This helper returns a
    round-trip UTC string for DateTime, DateTimeOffset and parseable text.
    Unspecified DateTime kinds and zone-less text are treated as UTC.

    .PARAMETER Value
    Raw audit property value.

    .OUTPUTS
    System.String in round-trip format, the original text when it cannot be
    parsed, or null for null/blank input.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [datetimeoffset]) {
        return $Value.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [datetime]) {
        $dateTime = if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
            [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)
        }
        else {
            $Value.ToUniversalTime()
        }
        return $dateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    $text = [string] $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref] $parsed)) {
        return $parsed.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    return $text
}

function Get-TagChangeProcessingStage {
    <#
    .SYNOPSIS
    Returns the current processing stage of an audit record.

    .PARAMETER AuditRecord
    Raw audit entity of an import or tag-change operation.

    .OUTPUTS
    System.String: error, complete, processing (the queue worker has started)
    or queued.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $AuditRecord)

    if (Test-ProcessingFailed -AuditRecord $AuditRecord) {
        return 'error'
    }
    if ($AuditRecord.PSObject.Properties['processingCompletedAtUtc'] -and
        -not [string]::IsNullOrWhiteSpace([string] $AuditRecord.processingCompletedAtUtc)) {
        return 'complete'
    }
    if ($AuditRecord.PSObject.Properties['processingStartedAtUtc'] -and
        -not [string]::IsNullOrWhiteSpace([string] $AuditRecord.processingStartedAtUtc)) {
        return 'processing'
    }
    return 'queued'
}

function Resolve-RecentTagChangeGroupTag {
    <#
    .SYNOPSIS
    Applies recently completed tag changes that Autopilot does not yet report.

    .DESCRIPTION
    Intune updates the windowsAutopilotDeviceIdentities groupTag property
    asynchronously after updateDeviceProperties succeeds, so a device list
    read shortly after a completed change can still show the previous tag.
    For each device, selects the newest successfully completed tagChange audit
    record for its registered Autopilot ID with processingCompletedAtUtc at or
    after CompletedAfterUtc. When the device still reports that record's
    previousGroupTag, the destination groupTag is returned instead. A device
    reporting any other tag is left unchanged, so later external changes win.

    .PARAMETER Device
    Device-list entries with id (registered Autopilot ID) and groupTag.

    .PARAMETER AuditRecord
    Raw audit entities. Non-tagChange, failed and incomplete records are ignored.

    .PARAMETER CompletedAfterUtc
    Oldest completion instant for which Autopilot propagation lag is assumed.

    .OUTPUTS
    The supplied device objects in input order; groupTag is updated in place.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Device = @(),

        [AllowEmptyCollection()]
        [object[]] $AuditRecord = @(),

        [Parameter(Mandatory)]
        [datetimeoffset] $CompletedAfterUtc
    )

    $latestByDevice = @{}
    foreach ($record in @($AuditRecord)) {
        if (-not $record -or [string] $record.operationType -ne 'tagChange' -or
            [string]::IsNullOrWhiteSpace([string] $record.registeredDeviceId) -or
            [string]::IsNullOrWhiteSpace([string] $record.processingCompletedAtUtc) -or
            (Test-ProcessingFailed -AuditRecord $record)) {
            continue
        }
        $completedAt = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse(
                [string] $record.processingCompletedAtUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal,
                [ref] $completedAt) -or $completedAt -lt $CompletedAfterUtc) {
            continue
        }
        $key = ([string] $record.registeredDeviceId).ToLowerInvariant()
        if (-not $latestByDevice.ContainsKey($key) -or
            $latestByDevice[$key].CompletedAt -lt $completedAt) {
            $latestByDevice[$key] = [pscustomobject]@{
                CompletedAt = $completedAt
                Record      = $record
            }
        }
    }

    foreach ($item in @($Device)) {
        if (-not $item) {
            continue
        }
        $key = ([string] $item.id).ToLowerInvariant()
        if ($latestByDevice.ContainsKey($key)) {
            $record = $latestByDevice[$key].Record
            if ([string] $item.groupTag -ieq [string] $record.previousGroupTag -and
                [string] $item.groupTag -ine [string] $record.groupTag) {
                $item.groupTag = [string] $record.groupTag
            }
        }
        $item
    }
}

function Remove-ExpiredImportAuditRecords {
    <#
    .SYNOPSIS
    Deletes import audit records older than the supplied UTC cutoff.

    .DESCRIPTION
    Queries the imports partition for requestReceivedAtUtc strictly before
    BeforeUtc, follows Storage continuation headers, and deletes each match.
    Entries in other partitions, including devicePolicies, are not selected.

    .PARAMETER BeforeUtc
    Exclusive upper bound for expired request timestamps, formatted as UTC.

    .PARAMETER AccessToken
    SecureString Storage token with table read and delete permissions.

    .OUTPUTS
    System.Int32. Count of successfully deleted entities after all pages finish.

    .EXAMPLE
    $removed = Remove-ExpiredImportAuditRecords `
        -BeforeUtc (Get-ImportAuditRetentionCutoffUtc) -AccessToken $storageToken

    Permanently deletes expired audit history. Intended for the retention job.

    .NOTES
    Destructive: no confirmation, WhatIf, rollback or ETag concurrency check.
    Errors propagate; prior successful deletions remain applied if a later
    request fails, and a final count is not returned in that case.
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
    # Keep retention cleanup separate from persistent per-device policy state.
    $filter = "PartitionKey eq 'imports' and requestReceivedAtUtc lt '$beforeValue'"
    $headers = @{
        Accept         = 'application/json;odata=nometadata'
        'If-Match'     = '*'
        'x-ms-date'    = [datetime]::UtcNow.ToString(
            'R', [Globalization.CultureInfo]::InvariantCulture)
        'x-ms-version' = '2019-02-02'
    }
    $removedCount = 0
    $continuation = ''

    do {
        $requestUri = "$tableUri()?`$filter=$([uri]::EscapeDataString($filter))&`$top=1000$continuation"
        $pageHeaders = $null
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $requestUri `
            -Authentication Bearer `
            -Token $AccessToken `
            -Headers $headers `
            -ResponseHeadersVariable pageHeaders `
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
        $continuation = if ($pageHeaders -and $pageHeaders['x-ms-continuation-NextPartitionKey']) {
            "&NextPartitionKey=$([uri]::EscapeDataString([string] $pageHeaders['x-ms-continuation-NextPartitionKey']))&NextRowKey=$([uri]::EscapeDataString([string] $pageHeaders['x-ms-continuation-NextRowKey']))"
        } else { '' }
    } while ($continuation)

    return $removedCount
}

function Get-TagPolicyRuleId {
    <#
    .SYNOPSIS
    Returns the persistent rule ID or a deterministic ID for pre-ID rules.
    .DESCRIPTION
    Legacy identity uses the authorization group and rule name, not mutable
    action values. Once returned, clients must preserve ruleId on replacements.
    #>
    param([Parameter(Mandatory)][object] $Rule)
    $data = if ($Rule -is [Collections.IDictionary]) { $Rule } else {
        $map = @{}
        foreach ($property in $Rule.PSObject.Properties) { $map[$property.Name] = $property.Value }
        $map
    }
    if ($data.Contains('ruleId')) {
        $id = [guid]::Empty
        if (-not [guid]::TryParse([string] $data['ruleId'], [ref] $id) -or $id -eq [guid]::Empty) {
            throw [ArgumentException]::new('ruleId must be a non-empty GUID.')
        }
        return $id.ToString()
    }
    $group = ([guid] $data['groupId']).ToString()
    $name = ([string] $data['name']).Trim()
    if (-not $name) { $name = "Policy $group" }
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$group|$name".ToLowerInvariant()))
    return [guid]::new([byte[]] $hash[0..15]).ToString()
}

function Write-ManagementAuditEvent {
    <#
    .SYNOPSIS
    Inserts an append-only management change event in a non-expiring partition.
    .DESCRIPTION
    Inserts, never merges or deletes. A requested event must persist before a
    configuration write; a separate applied event confirms completion. Missing
    completion is deliberately not interpreted as success. Payload chunks stay
    below Table string/entity limits; oversized changes fail before mutation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('policies','managers')][string] $Kind,
        [Parameter(Mandatory)][guid] $OperationId,
        [Parameter(Mandatory)][ValidateSet('requested','applied','failed')][string] $Stage,
        [Parameter(Mandatory)][object] $Principal,
        [AllowNull()][object] $Before,
        [AllowNull()][object] $After
    )
    $actorId = [string] (@($Principal.claims | Where-Object {
        $_.typ -in @('oid','http://schemas.microsoft.com/identity/claims/objectidentifier')
    } | Select-Object -First 1).val)
    if ([guid] $actorId -eq [guid]::Empty) { throw 'Management audit requires a caller object ID.' }
    $actorName = [string] ($Principal.claims | Where-Object {
        $_.typ -in @('preferred_username','upn','http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn','name')
    } | ForEach-Object val | Select-Object -First 1)
    $now = [datetime]::UtcNow
    $payload = ConvertTo-Json -InputObject @{
        operationId = $OperationId.ToString(); stage = $Stage
        atUtc = $now.ToString('o'); actorId = $actorId; actorName = $actorName
        before = $Before; after = $After
    } -Depth 20 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($payload) -gt 700000 -or $payload.Length -gt 350000) {
        throw 'Management audit payload exceeds the supported size; split the change into smaller updates.'
    }
    $entity = [ordered]@{
        PartitionKey = "management-$Kind"
        RowKey = '{0:d19}-{1}' -f ([datetime]::MaxValue.Ticks - $now.Ticks), [guid]::NewGuid().ToString()
        chunks = 0
    }
    for ($start = 0; $start -lt $payload.Length;) {
        $length = [Math]::Min(15000, $payload.Length - $start)
        if ($start + $length -lt $payload.Length -and [char]::IsHighSurrogate($payload[$start + $length - 1])) {
            $length--
        }
        $entity["payload$($entity.chunks)"] = $payload.Substring($start, $length)
        $entity.chunks++
        $start += $length
    }
    $headers = @{
        Accept = 'application/json;odata=nometadata'
        'x-ms-date' = $now.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
        'x-ms-version' = '2019-02-02'
    }
    $body = ConvertTo-Json -InputObject $entity -Depth 4 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($body) -gt 900000) { throw 'Management audit entity exceeds the supported size.' }
    Invoke-RestMethod -Method Post -Uri (Get-ImportAuditTableUri) -Authentication Bearer `
        -Token (Get-ImportAuditAccessToken) -Headers $headers -ContentType 'application/json' `
        -Body $body -ErrorAction Stop | Out-Null
}

function Get-ManagementAuditHistory {
    <#
    .SYNOPSIS
    Reads a bounded newest-first page of permanent management events.
    .DESCRIPTION
    Queries only the requested management partition. The opaque continuation
    row key is validated and the partition is always server-selected. Import
    audit retention never selects these partitions. No delete API is provided.
    With RuleId, policy events contain only changed snapshots of that rule.
    Legacy snapshots derive the same initial ID as current policy reads.
    Filtered pages can be empty with a continuation; never treat this as EOF.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('policies','managers')][string] $Kind,
        [string] $Continuation,
        [guid] $RuleId
    )
    if ($Continuation -and $Continuation -notmatch '^\d{19}-[0-9a-f-]{36}$') {
        throw [ArgumentException]::new('Invalid management history continuation.')
    }
    $partition = "management-$Kind"
    $filter = [uri]::EscapeDataString("PartitionKey eq '$partition'")
    $uri = "$(Get-ImportAuditTableUri)()?`$filter=$filter&`$top=25"
    if ($Continuation) {
        $uri += "&NextPartitionKey=$partition&NextRowKey=$([uri]::EscapeDataString($Continuation))"
    }
    $headers = @{
        Accept = 'application/json;odata=nometadata'
        'x-ms-date' = [datetime]::UtcNow.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
        'x-ms-version' = '2019-02-02'
    }
    $pageHeaders = $null
    $response = Invoke-RestMethod -Method Get -Uri $uri -Authentication Bearer `
        -Token (Get-ImportAuditAccessToken) -Headers $headers -ResponseHeadersVariable pageHeaders -ErrorAction Stop
    $events = @(
        foreach ($entity in $response.value) {
            if ($entity.PartitionKey -cne $partition -or $entity.chunks -lt 1 -or $entity.chunks -gt 24) {
                throw 'Invalid management audit entity.'
            }
            $payload = ''
            for ($index = 0; $index -lt $entity.chunks; $index++) { $payload += $entity."payload$index" }
            $event = $payload | ConvertFrom-Json -ErrorAction Stop
            if ($Kind -eq 'policies' -and $RuleId -ne [guid]::Empty) {
                $before = @($event.before | Where-Object { $null -ne $_ -and (Get-TagPolicyRuleId $_) -eq $RuleId.ToString() } |
                    ForEach-Object { (ConvertTo-TagAuthorizationPolicy -Rules @($_))[0] })
                $after = @($event.after | Where-Object { $null -ne $_ -and (Get-TagPolicyRuleId $_) -eq $RuleId.ToString() } |
                    ForEach-Object { (ConvertTo-TagAuthorizationPolicy -Rules @($_))[0] })
                if ($before.Count -eq 0 -and $after.Count -eq 0) { continue }
                $oldJson = ConvertTo-Json -InputObject $before -Depth 20 -Compress
                $newJson = ConvertTo-Json -InputObject $after -Depth 20 -Compress
                if ($oldJson -ceq $newJson) { continue }
                $event.before = if ($before.Count) { $before[0] } else { $null }
                $event.after = if ($after.Count) { $after[0] } else { $null }
            }
            $event
        }
    )
    $next = if ($pageHeaders -and $pageHeaders['x-ms-continuation-NextRowKey']) {
        [string] $pageHeaders['x-ms-continuation-NextRowKey']
    } else { '' }
    return @{ events = $events; continuation = $next }
}

function Set-ManagementPolicyBlob {
    <#
    .SYNOPSIS
    Writes validated policy JSON synchronously so audit completion is truthful.
    .DESCRIPTION
    Uses Storage identity authentication. If-Match protects against edits since
    the fresh read; a missing blob is created only if it still does not exist.
    The expected policy must match the current blob or deployment fallback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedJson,
        [Parameter(Mandatory)][string] $Json
    )
    $uri = "https://$($env:AzureWebJobsStorage__accountName).blob.core.windows.net/configuration/tag-authorization-policy.json"
    $token = Get-ImportAuditAccessToken
    $headers = @{
        'x-ms-date' = [datetime]::UtcNow.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
        'x-ms-version' = '2019-12-12'
    }
    $exists = $true
    try {
        $current = Invoke-WebRequest -Method Get -Uri $uri -Authentication Bearer -Token $token -Headers $headers -ErrorAction Stop
        $currentJson = if ($current.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($current.Content)
        } else { [string] $current.Content }
    } catch {
        if (-not (Test-ImportAuditHttpStatus -ErrorRecord $_ -StatusCode 404)) { throw }
        $exists = $false
        $currentJson = $env:TAG_AUTHORIZATION_POLICY
    }
    # The worker may deserialize/reformat the blob binding, so compare policy
    # content rather than whitespace or JSON property order. Keep the raw ETag.
    if ([string]::IsNullOrWhiteSpace($currentJson)) {
        throw 'The current tag authorization policy is missing.'
    }
    $currentPolicy = ConvertTo-TagAuthorizationPolicy -Rules @($currentJson | ConvertFrom-Json -ErrorAction Stop) -AllowEmpty
    $expectedPolicy = ConvertTo-TagAuthorizationPolicy -Rules @($ExpectedJson | ConvertFrom-Json -ErrorAction Stop) -AllowEmpty
    $currentCanonical = ConvertTo-Json -InputObject @($currentPolicy) -Depth 20 -Compress
    $expectedCanonical = ConvertTo-Json -InputObject @($expectedPolicy) -Depth 20 -Compress
    if ($currentCanonical -cne $expectedCanonical) { throw 'Policy changed on the server. Reload policies before saving.' }
    $headers['x-ms-blob-type'] = 'BlockBlob'
    if ($exists) {
        $etag = [string] $current.Headers.ETag
        if (-not $etag) { throw 'Policy response is missing its concurrency token.' }
        $headers['If-Match'] = $etag
    } else { $headers['If-None-Match'] = '*' }
    Invoke-RestMethod -Method Put -Uri $uri -Authentication Bearer -Token $token -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($Json)) -ErrorAction Stop | Out-Null
}

function ConvertTo-TagAuthorizationPolicy {
    <#
    .SYNOPSIS
    Converts group-to-tag rules into a normalized authorization policy.

    .DESCRIPTION
    Accepts legacy group=tag1,tag2 strings and object rules. Normalizes group
    GUIDs, tag lists, optional AU names and named device-action settings.
    Legacy rules merge by group ID; action rules merge by group ID plus name.
    Conflicting settings or AU assignments for the same key are rejected.
    The output is deterministic by rule key and tag name.

    .PARAMETER Rules
    Rules in the form <group-object-id>=<tag1>,<tag2>, or rule objects with
    groupId, tags, and an optional administrativeUnitName. Named device-action
    objects use name, groupId, groupTag, optional extensionAttributes
    (extensionAttribute1 through extensionAttribute15), and deviceGroupIds.
    Former scopeTag-only rules retain their effective Group Tag on migration;
    scopeTag is never included in the normalized policy.

    .PARAMETER AdministrativeUnitName
    Default administrative-unit display name for string rules and object rules
    without their own administrativeUnitName property. An explicit object
    property overrides this default, including an empty value. Imported devices
    using a matching Group Tag can be assigned to this regular or restricted
    management unit after their Entra device becomes available.

    .OUTPUTS
    PSCustomObject array returned as one collection, preserving legacy
    multi-tag authorization rules and normalized action properties.

    .PARAMETER AllowEmpty
    Allows an empty existing policy during initial setup. Submitted replacement
    policies must omit this switch so at least one valid rule remains required.

    .EXAMPLE
    $policy = ConvertTo-TagAuthorizationPolicy -Rules @(
        '11111111-1111-1111-1111-111111111111=BG-Default,BG-VIP'
    ) -AdministrativeUnitName 'Managed devices'

    Creates a legacy multi-tag rule with a default display name and AU target.

    .NOTES
    Pure normalization: does not query Graph or check that groups/AUs exist.
    Rejects invalid GUIDs, tags, attribute names/values and conflicting rules.
    Named actions require a name and Group Tag; scopeTag is migrated only as
    a legacy Group Tag fallback and never emitted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Rules,

        [string] $AdministrativeUnitName,

        [switch] $AllowEmpty
    )

    if (-not [string]::IsNullOrWhiteSpace(
            $AdministrativeUnitName) -and
        $AdministrativeUnitName.Trim().Length -gt 256) {
        throw 'Administrative unit name must not exceed 256 characters.'
    }

    if ($AllowEmpty -and $Rules.Count -eq 0) {
        return ,@()
    }
    $enteredRules = @($Rules | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($enteredRules.Count -eq 0) {
        throw 'At least one group and tag rule is required.'
    }

    # Track tags, AU and action settings separately so compatible duplicate
    # rules can merge without silently overwriting conflicting settings.
    $rulesByGroup = @{}
    $mauByGroup = @{}
    $settingsByGroup = @{}
    $groupIdsByRule = @{}
    foreach ($rule in $enteredRules) {
        $settings = [ordered]@{}
        $extended = $false
        if ($rule -isnot [string]) {
            # Map custom objects to dictionary access. Existing dictionaries
            # are reused, so the tags normalization below can update the input.
            $data = if ($rule -is [Collections.IDictionary]) { $rule } else {
                $map = @{}
                foreach ($property in $rule.PSObject.Properties) { $map[$property.Name] = $property.Value }
                $map
            }
            $name = ([string] $data['name']).Trim()
            $groupTag = ([string] $data['groupTag']).Trim()
            $scopeTag = ([string] $data['scopeTag']).Trim()
            $extended = $data.Contains('groupTag') -or $data.Contains('scopeTag') -or
                $data.Contains('extensionAttributes') -or $data.Contains('deviceGroupIds')
            if ($extended -and ($name.Length -eq 0 -or $name.Length -gt 128)) {
                throw 'Named policy rules require a name of 1..128 characters.'
            }
            if ($data.Contains('groupTag') -or $data.Contains('scopeTag')) {
                # Retain old scopeTag-only policies as effective Group Tags,
                # but expose only the current groupTag/tags representation.
                if (-not $groupTag -and -not $scopeTag) { throw 'A Group Tag is required.' }
                if (-not $groupTag) { $groupTag = $scopeTag }
                if ($groupTag.Length -gt 128 -or $groupTag.Contains(',')) {
                    throw 'Group Tag names must be at most 128 characters and must not contain commas.'
                }
                $settings.groupTag = $groupTag
                $data['tags'] = @($groupTag)
            }
            if ($extended -and -not $settings.Contains('groupTag')) {
                throw 'Named action rules require a Group Tag.'
            }
            if ($name) { $settings.name = $name }
            if ($data.Contains('description')) {
                if ($data['description'] -isnot [string] -or $data['description'].Length -gt 2048 -or
                    $data['description'] -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') {
                    throw 'Policy description must be text of at most 2048 characters without control characters.'
                }
                $settings.description = $data['description']
            }
            if ($data.Contains('extensionAttributes')) {
                # Attribute values are explicit strings, including empty ones.
                # Reject control characters rather than normalizing user data.
                $attributes = $data['extensionAttributes']
                if ($attributes -isnot [Collections.IDictionary] -and $attributes -isnot [pscustomobject]) {
                    throw 'extensionAttributes must be an object of attribute/value pairs.'
                }
                $attributeMap = [ordered]@{}
                $keys = if ($attributes -is [Collections.IDictionary]) {
                    $attributes.Keys
                } else {
                    @($attributes.PSObject.Properties) | ForEach-Object Name
                }
                foreach ($key in @($keys | Sort-Object)) {
                    $value = if ($attributes -is [Collections.IDictionary]) { $attributes[$key] } else { $attributes.$key }
                    if ($key -cnotmatch '^extensionAttribute(?:[1-9]|1[0-5])$' -or
                        $value -isnot [string] -or $value.Length -gt 1024 -or
                        $value -match '[\p{Cc}\p{Zl}\p{Zp}]') {
                        throw 'Extension attributes must be extensionAttribute1..15 with single-line string values of at most 1024 characters, without control characters.'
                    }
                    $attributeMap[$key] = $value
                }
                $settings.extensionAttributes = $attributeMap
            }
            elseif ($extended) {
                # An explicit empty map disables the legacy tag-to-attribute
                # default for action rules with no configured attributes.
                $settings.extensionAttributes = [ordered]@{}
            }
            if ($data.Contains('deviceGroupIds')) {
                $ids = @()
                foreach ($id in @($data['deviceGroupIds'])) {
                    $parsed = [guid]::Empty
                    if (-not [guid]::TryParse([string] $id, [ref] $parsed) -or $parsed -eq [guid]::Empty) {
                        throw "Device group ID '$id' must be a non-empty GUID."
                    }
                    $ids += $parsed.ToString()
                }
                $settings.deviceGroupIds = @($ids | Sort-Object -Unique)
            }
            $rule = $data
        }
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
        if (-not $settings.Contains('name')) { $settings.name = "Policy $normalizedGroupId" }
        $identityRule = @{ groupId = $normalizedGroupId; name = $settings.name }
        if ($rule -is [Collections.IDictionary] -and $rule.Contains('ruleId')) { $identityRule.ruleId = $rule['ruleId'] }
        $settings.ruleId = Get-TagPolicyRuleId $identityRule
        # One authorization group can own several independently named action
        # rules; legacy multi-tag rules retain their group-only merge identity.
        $policyKey = if ($extended) { "$normalizedGroupId|$($settings.name)" } else { $normalizedGroupId }
        $groupIdsByRule[$policyKey] = $normalizedGroupId
        if ($settingsByGroup.ContainsKey($policyKey) -and
            ($settingsByGroup[$policyKey] | ConvertTo-Json -Depth 6 -Compress) -cne
            ($settings | ConvertTo-Json -Depth 6 -Compress)) {
            throw "Group '$normalizedGroupId' has conflicting policy settings."
        }
        $settingsByGroup[$policyKey] = $settings

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
        if ($mauByGroup.ContainsKey($policyKey) -and
            $mauByGroup[$policyKey] -ne $normalizedMauName) {
            throw "Group '$normalizedGroupId' has conflicting administrative units."
        }

        $rulesByGroup[$policyKey] = @(
            @($rulesByGroup[$policyKey]) + $tags | Select-Object -Unique
        )
        $mauByGroup[$policyKey] = $normalizedMauName
    }

    $ids = @($settingsByGroup.Values | ForEach-Object { $_.ruleId })
    if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) { throw 'Each policy rule must have a unique ruleId.' }
    # Return the policy as one array object, including when it has one entry.
    return ,@($rulesByGroup.Keys | Sort-Object | ForEach-Object {
        $policyEntry = [ordered]@{
            groupId = $groupIdsByRule[$_]
            tags    = @($rulesByGroup[$_] | Sort-Object)
        }
        foreach ($key in $settingsByGroup[$_].Keys) { $policyEntry[$key] = $settingsByGroup[$_][$key] }
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

    .DESCRIPTION
    Finds nonblank AU names on matching tag rules. When Principal is supplied,
    considers only rules for its group claims. Repeated copies of the same AU
    name are consolidated; multiple distinct targets are an error.

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

    .EXAMPLE
    $auName = Resolve-AdministrativeUnitName -Policy $policy `
        -GroupTag 'BG-Default' -Principal $principal

    Resolves the target using only rules applicable to the caller's groups.

    .NOTES
    Throws when matching rules name multiple AUs. Does not check Graph or
    refresh claims; callers supply an already authorized tag/current principal.
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
    # Caller-specific resolution prevents another group's same-tag rule from
    # assigning an unrelated administrative unit during request acceptance.
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

    .DESCRIPTION
    Prefers a single target in the current policy. When several names match,
    uses the queued name only if it matches one of those targets ignoring case.
    When no current target exists, retains a nonblank queued name.

    .PARAMETER Policy
    Current tag authorization policy loaded when the queue item is processed.

    .PARAMETER GroupTag
    Authorized Group Tag stored in the queue item.

    .PARAMETER QueuedAdministrativeUnitName
    Optional administrative unit resolved when the import was accepted.

    .OUTPUTS
    System.String, or null when neither the current policy nor the queue item
    configures an administrative unit.

    .EXAMPLE
    Resolve-EffectiveAdministrativeUnitName -Policy $policy `
        -GroupTag 'BG-Default' -QueuedAdministrativeUnitName 'Managed devices'

    Reconciles an accepted request's AU snapshot with the current policy.

    .NOTES
    Throws when multiple current targets cannot be disambiguated by the queued
    name. Does not authorize a caller, resolve an AU ID or mutate memberships.
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

    # A policy edited after enqueue wins when unambiguous. The queued value
    # is a disambiguation/fallback value, not an unconditional override.
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

    .DESCRIPTION
    Queries Graph using an escaped displayName equality filter, selects basic
    identity/restriction properties, and requires exactly one case-insensitive
    exact match after trimming the requested name.

    .PARAMETER AdministrativeUnitName
    Display name of the administrative unit. The name must uniquely identify
    an existing regular or restricted management administrative unit.

    .PARAMETER AccessToken
    SecureString Microsoft Graph token with AU read permissions.

    .OUTPUTS
    Graph administrative-unit object containing id, displayName and
    isMemberManagementRestricted.

    .EXAMPLE
    $unit = Resolve-EntraAdministrativeUnit `
        -AdministrativeUnitName 'Managed devices' -AccessToken $graphToken

    Resolves a single existing regular or restricted management AU.

    .NOTES
    Throws for missing/ambiguous names and propagates Graph errors. Does not
    create an AU, validate write permissions or follow collection pagination.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateLength(1, 256)]
        [string] $AdministrativeUnitName,

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken
    )

    # Escape the OData string literal first, then encode the whole filter for
    # the URL so names containing apostrophes or reserved characters are safe.
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

    .DESCRIPTION
    Resolves the unique AU, checks current membership with an eventual-
    consistency query, and posts a device reference only if not already a
    member and TestOnly is absent. Does not remove other AU memberships.

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
    PSCustomObject with AdministrativeUnitId, IsMember (the pre-write check)
    and MembershipAdded. IsMember is not updated after a successful addition.

    .EXAMPLE
    Add-EntraDeviceToAdministrativeUnit -AdministrativeUnitName 'Managed devices' `
        -DeviceObjectId $deviceObjectId -AccessToken $graphToken -TestOnly

    Checks existing membership without writing to Graph.

    .NOTES
    Without TestOnly this changes directory membership without a confirmation
    prompt. AU resolution and Graph failures propagate; permission for a
    restricted AU may require additional Entra role assignments.
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

    # Directory membership endpoints require the object ID, not deviceId.
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
    # Add the reference rather than replacing the AU's membership collection.
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

function Sync-EntraDeviceAdministrativeUnits {
    <#
    .SYNOPSIS
    Synchronizes policy-managed administrative-unit membership for a device.

    .DESCRIPTION
    Removes the device from administrative units referenced by other policy
    rules and adds it to the target administrative unit when one is configured.
    Leaves memberships in AUs outside the supplied policy untouched.

    .PARAMETER Policy
    Current policy rules defining the set of managed administrative-unit names.

    .PARAMETER AdministrativeUnitName
    Target AU display name. Empty means remove other policy-managed memberships
    without adding a new target. Names are trimmed and compared ignoring case.

    .PARAMETER DeviceObjectId
    Entra directory object GUID of the device, not its deviceId alternate key.

    .PARAMETER AccessToken
    SecureString Graph token with AU read and membership write permissions.

    .OUTPUTS
    PSCustomObject with RemovedAdministrativeUnits (display names),
    TargetAdministrativeUnit and MembershipAdded.

    .EXAMPLE
    Sync-EntraDeviceAdministrativeUnits -Policy $policy `
        -AdministrativeUnitName 'Managed devices' -DeviceObjectId $deviceObjectId `
        -AccessToken $graphToken

    Removes other policy-managed AU memberships and ensures the target.

    .NOTES
    Mutates Graph without WhatIf or confirmation. Removals precede target
    addition; failures propagate and prior changes are not rolled back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Policy,

        [AllowEmptyString()]
        [string] $AdministrativeUnitName,

        [Parameter(Mandatory)]
        [guid] $DeviceObjectId,

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken
    )

    $targetName = $AdministrativeUnitName.Trim()
    $managedNames = @($Policy | ForEach-Object {
        if ($_.PSObject.Properties['administrativeUnitName'] -and
            -not [string]::IsNullOrWhiteSpace(
                [string] $_.administrativeUnitName)) {
            ([string] $_.administrativeUnitName).Trim()
        }
    } | Sort-Object -Unique)
    $deviceId = $DeviceObjectId.ToString()
    $removedNames = @()

    # Limit removal to current policy-managed names. Unrelated directory
    # memberships are intentionally not enumerated or removed.
    foreach ($managedName in $managedNames) {
        if ([string]::Equals(
                $managedName,
                $targetName,
                [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $administrativeUnit = Resolve-EntraAdministrativeUnit `
            -AdministrativeUnitName $managedName `
            -AccessToken $AccessToken
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
        if ($isMember) {
            Invoke-RestMethod `
                -Method Delete `
                -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits/$($administrativeUnit.id)/members/$deviceId/`$ref" `
                -Authentication Bearer `
                -Token $AccessToken `
                -ErrorAction Stop | Out-Null
            $removedNames += $managedName
        }
    }

    $targetResult = $null
    if (-not [string]::IsNullOrWhiteSpace($targetName)) {
        $targetResult = Add-EntraDeviceToAdministrativeUnit `
            -AdministrativeUnitName $targetName `
            -DeviceObjectId $DeviceObjectId `
            -AccessToken $AccessToken
    }

    return [pscustomobject]@{
        RemovedAdministrativeUnits = $removedNames
        TargetAdministrativeUnit   = $targetName
        MembershipAdded            = $targetResult -and
            $targetResult.MembershipAdded
    }
}

function ConvertTo-EntraDeviceExtensionAttributes {
    <#
    .SYNOPSIS
    Creates a Microsoft Graph device extensionAttributes update payload.

    .DESCRIPTION
    Wraps one authorized tag in the nested extensionAttributes map expected by
    a Graph device PATCH. Does not write to Graph or normalize the tag text.

    .PARAMETER ExtensionAttribute
    Target attribute from extensionAttribute1 through extensionAttribute15.

    .PARAMETER GroupTag
    Authorized Autopilot Group Tag written to the selected attribute.

    .OUTPUTS
    OrderedDictionary containing one nested ordered attribute/value map.

    .EXAMPLE
    ConvertTo-EntraDeviceExtensionAttributes `
        -ExtensionAttribute extensionAttribute1 -GroupTag 'BG-Default'

    Builds the payload for writing BG-Default to extensionAttribute1.

    .NOTES
    Parameter validation restricts attribute names to extensionAttribute1..15
    and tag length to 1..128. Caller must authorize the value before use.
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

function Get-PolicyGraphCollection {
    <#
    .SYNOPSIS
    Streams every page of a Microsoft Graph policy-related collection.

    .DESCRIPTION
    Performs GET requests and follows @odata.nextLink unchanged. Emits each
    page's value entries immediately rather than accumulating the entire
    collection in memory.

    .PARAMETER Uri
    Trusted absolute Graph collection URL, including any initial query.

    .PARAMETER AccessToken
    SecureString Graph token with read permission for the collection.

    .OUTPUTS
    Graph collection entries on the pipeline. Use @() at the call site for a
    stable array when zero or one entry is returned.

    .EXAMPLE
    $memberships = @(Get-PolicyGraphCollection `
        -Uri "https://graph.microsoft.com/v1.0/devices/$deviceObjectId/memberOf" `
        -AccessToken $graphToken)

    Collects all membership pages for one directory device.

    .NOTES
    REST errors propagate without retry. Earlier pages may already have been
    emitted when a later request fails. No filtering or deduplication occurs.
    #>
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][Security.SecureString] $AccessToken
    )
    do {
        # Continuation links already contain Graph's paging/query state.
        $page = Invoke-RestMethod -Method Get -Uri $Uri -Authentication Bearer -Token $AccessToken -ErrorAction Stop
        foreach ($item in @($page.value)) { $item }
        $Uri = if ($page.PSObject.Properties['@odata.nextLink']) { [string] $page.'@odata.nextLink' } else { '' }
    } while ($Uri)
}

function Get-DevicePolicyActions {
    <#
    .SYNOPSIS
    Resolves consistent device actions for a Group Tag.

    .DESCRIPTION
    Finds matching rules and compares their serialized extensionAttributes and
    deviceGroupIds settings. Returns a shallow copy of the first matching rule
    when those actions agree. Removes obsolete scopeTag from the returned copy.
    Named rules without attributes receive an explicit empty attribute object.

    .PARAMETER Policy
    Normalized authorization rules with tags and optional action settings.

    .PARAMETER GroupTag
    Tag to match using PowerShell's case-insensitive membership comparison.

    .OUTPUTS
    PSCustomObject containing the first matching rule and its action settings,
    or an empty PSCustomObject when no rule matches.

    .EXAMPLE
    $actions = Get-DevicePolicyActions -Policy $policy -GroupTag 'BG-Default'

    Resolves the attributes and device groups to apply for the authorized tag.

    .NOTES
    Throws for differing serialized action settings. It does not authorize
    user groups, compare every metadata field or query Graph.
    #>
    param(
        [Parameter(Mandatory)][object[]] $Policy,
        [Parameter(Mandatory)][string] $GroupTag
    )
    $matching = @($Policy | Where-Object { $GroupTag -in @($_.tags) })
    # Multiple authorization groups may expose the same tag, but the worker
    # must not choose between contradictory device actions for that tag.
    $actions = @($matching | ForEach-Object {
        $rule = $_
        $result = [ordered]@{}
        foreach ($key in @('extensionAttributes', 'deviceGroupIds')) {
            if ($rule.PSObject.Properties[$key]) { $result[$key] = $rule.$key }
            elseif ($key -eq 'extensionAttributes' -and $rule.PSObject.Properties['groupTag']) {
                $result[$key] = [ordered]@{}
            }
        }
        $result | ConvertTo-Json -Depth 6 -Compress
    } | Select-Object -Unique)
    if ($actions.Count -gt 1) {
        throw "Group Tag '$GroupTag' has conflicting device actions across authorization rules."
    }
    if ($matching.Count -eq 0) { return [pscustomobject]@{} }
    $copy = $matching[0].PSObject.Copy()
    $copy.PSObject.Properties.Remove('scopeTag')
    if ($copy.PSObject.Properties['groupTag'] -and -not $copy.PSObject.Properties['extensionAttributes']) {
        $copy | Add-Member -NotePropertyName extensionAttributes -NotePropertyValue ([pscustomobject]@{})
    }
    return $copy
}

function Assert-DevicePolicyGroups {
    <#
    .SYNOPSIS
    Validates that target groups support direct device membership management.

    .DESCRIPTION
    Reads each unique group from Graph and requires securityEnabled, no
    DynamicMembership type, no on-premises synchronization and no role-
    assignable flag. Does not change any membership.

    .PARAMETER GroupIds
    Directory group ID strings to inspect. Defaults to an empty list.

    .PARAMETER AccessToken
    SecureString Graph token permitted to read the requested group properties.

    .OUTPUTS
    None. Successful completion means all requested groups passed the checks.

    .EXAMPLE
    Assert-DevicePolicyGroups -GroupIds $targetGroupIds -AccessToken $graphToken

    Validates all configured device target groups before a membership change.

    .NOTES
    Throws for unsupported groups and propagates Graph lookup errors. This
    does not prove the token has permission to write memberships.
    #>
    param(
        [string[]] $GroupIds = @(),
        [Parameter(Mandatory)][Security.SecureString] $AccessToken
    )
    foreach ($id in @($GroupIds | Sort-Object -Unique)) {
        $group = Invoke-RestMethod -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/groups/${id}?`$select=id,securityEnabled,groupTypes,onPremisesSyncEnabled,isAssignableToRole" `
            -Authentication Bearer -Token $AccessToken -ErrorAction Stop
        if (-not $group.securityEnabled -or 'DynamicMembership' -in @($group.groupTypes) -or
            $group.onPremisesSyncEnabled -eq $true -or $group.isAssignableToRole -eq $true) {
            throw "Device target group '$id' must be a cloud-managed, static, non-role-assignable security group."
        }
    }
}

function Sync-DevicePolicyGroups {
    <#
    .SYNOPSIS
    Synchronizes a device's policy-managed group memberships.

    .DESCRIPTION
    Reads current direct memberships. The removal scope is the union of groups
    referenced by current Policy and PreviousGroupIds. Adds missing target
    groups first, then removes managed memberships not in TargetGroupIds.
    Unrelated group memberships remain unchanged.

    .PARAMETER Policy
    Current policy rules defining managed deviceGroupIds.

    .PARAMETER TargetGroupIds
    Desired device groups. Defaults to empty, meaning no target memberships.

    .PARAMETER PreviousGroupIds
    Previously tracked group IDs, allowing cleanup after policy groups have
    been removed from the current configuration.

    .PARAMETER DeviceObjectId
    Entra directory object GUID of the device, not the deviceId alternate key.

    .PARAMETER AccessToken
    SecureString Graph token with device/group read and membership write access.

    .PARAMETER PassThru
    Returns the planned successful additions/removals after writes complete.

    .OUTPUTS
    None by default. With PassThru, PSCustomObject with AddedGroupIds and
    RemovedGroupIds. Existing target memberships are not counted as additions.

    .EXAMPLE
    $changes = Sync-DevicePolicyGroups -Policy $policy `
        -TargetGroupIds $targets -PreviousGroupIds $previous `
        -DeviceObjectId $deviceObjectId -AccessToken $graphToken -PassThru

    Applies the target set and returns the IDs added and removed.

    .NOTES
    Validates affected removal/target groups before any writes. Changes have no
    confirmation, transaction or rollback. Errors propagate, and earlier writes
    may remain applied. This helper does not persist device-policy state.
    #>
    param(
        [Parameter(Mandatory)][object[]] $Policy,
        [string[]] $TargetGroupIds = @(),
        [string[]] $PreviousGroupIds = @(),
        [Parameter(Mandatory)][guid] $DeviceObjectId,
        [Parameter(Mandatory)][Security.SecureString] $AccessToken,
        [switch] $PassThru
    )
    # Include the persisted previous set so deleted policy references can
    # still be cleaned up without touching arbitrary device memberships.
    $managedIds = @(@($Policy | ForEach-Object {
        if ($_.PSObject.Properties['deviceGroupIds']) { $_.deviceGroupIds }
    }) + $PreviousGroupIds | Sort-Object -Unique)
    $memberships = @(Get-PolicyGraphCollection `
        -Uri "https://graph.microsoft.com/v1.0/devices/$DeviceObjectId/memberOf?`$select=id" -AccessToken $AccessToken)
    $memberIds = @($memberships | ForEach-Object { [string] $_.id })
    $removeIds = @($managedIds | Where-Object { $_ -in $memberIds -and $_ -notin $TargetGroupIds })
    $addIds = @($TargetGroupIds | Where-Object { $_ -notin $memberIds })
    # Check all affected groups before starting writes; a later Graph failure
    # can still leave partial changes, so worker retries must re-read state.
    Assert-DevicePolicyGroups -GroupIds @($removeIds + $TargetGroupIds | Sort-Object -Unique) -AccessToken $AccessToken
    foreach ($id in $TargetGroupIds) {
        if ($id -notin $memberIds) {
            Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/groups/$id/members/`$ref" `
                -Authentication Bearer -Token $AccessToken -ContentType 'application/json' `
                -Body (@{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$DeviceObjectId" } | ConvertTo-Json -Compress) `
                -ErrorAction Stop | Out-Null
        }
    }
    foreach ($id in $removeIds) {
            Invoke-RestMethod -Method Delete -Uri "https://graph.microsoft.com/v1.0/groups/$id/members/$DeviceObjectId/`$ref" `
                -Authentication Bearer -Token $AccessToken -ErrorAction Stop | Out-Null
    }
    if ($PassThru) {
        [pscustomobject]@{ AddedGroupIds = $addIds; RemovedGroupIds = $removeIds }
    }
}

function Get-DevicePolicyState {
    <#
    .SYNOPSIS
    Reads the last persisted policy-managed group set for a device.

    .DESCRIPTION
    Queries the audit table's devicePolicies partition by DeviceId. State is
    separate from imports history so retention cleanup does not select it.

    .PARAMETER DeviceId
    GUID used as the device-policy state RowKey. Use the same device identifier
    consistently when reading and writing state.

    .PARAMETER AccessToken
    SecureString Storage token with table-entity read access.

    .OUTPUTS
    Raw state entity when found. Otherwise a PSCustomObject with groupIdsJson
    equal to [] as JSON text. The JSON property is not deserialized here.

    .EXAMPLE
    $state = Get-DevicePolicyState -DeviceId $deviceId -AccessToken $storageToken
    $previous = @($state.groupIdsJson | ConvertFrom-Json)

    Reads the previously managed groups for subsequent synchronization.

    .NOTES
    A missing row is an empty state; HTTP/configuration errors propagate rather
    than being treated as missing. This helper does not read live memberships.
    #>
    param(
        [Parameter(Mandatory)][guid] $DeviceId,
        [Parameter(Mandatory)][Security.SecureString] $AccessToken
    )
    $filter = [uri]::EscapeDataString("PartitionKey eq 'devicePolicies' and RowKey eq '$DeviceId'")
    $response = Invoke-RestMethod -Method Get -Uri "$(Get-ImportAuditTableUri)()?`$filter=$filter" `
        -Authentication Bearer -Token $AccessToken -Headers @{
            Accept = 'application/json;odata=nometadata'
            'x-ms-version' = '2019-02-02'
        } -ErrorAction Stop
    $rows = @($response.value)
    # First-time processing has no previous managed group set to remove.
    if ($rows.Count -eq 0) { return [pscustomobject]@{ groupIdsJson = '[]' } }
    return $rows[0]
}

function Set-DevicePolicyState {
    <#
    .SYNOPSIS
    Persists a device's policy-managed group IDs in Table Storage.

    .DESCRIPTION
    PUTs a devicePolicies entity in the configured audit table. groupIdsJson
    stores the supplied group-ID array as JSON, including [] for no groups.
    Replaces/upserts the state entity rather than merging audit properties.

    .PARAMETER DeviceId
    GUID used as RowKey; must match the identifier used by the state reader.

    .PARAMETER GroupIds
    Group IDs to remember for later policy cleanup. Defaults to an empty array.
    This helper does not validate, sort or deduplicate the supplied IDs.

    .PARAMETER AccessToken
    SecureString Storage token with table-entity write access.

    .OUTPUTS
    None. REST response output is suppressed.

    .EXAMPLE
    Set-DevicePolicyState -DeviceId $deviceId -GroupIds $targetGroupIds `
        -AccessToken $storageToken

    Records the managed group set after the caller applies device actions.

    .NOTES
    Does not change Graph memberships. Storage/configuration errors propagate.
    Concurrent writes are not guarded by an ETag.
    #>
    param(
        [Parameter(Mandatory)][guid] $DeviceId,
        [string[]] $GroupIds = @(),
        [Parameter(Mandatory)][Security.SecureString] $AccessToken
    )
    $body = @{
        PartitionKey = 'devicePolicies'
        RowKey = $DeviceId.ToString()
        # InputObject preserves array JSON even for zero or one group ID.
        groupIdsJson = ConvertTo-Json -InputObject @($GroupIds) -Compress
    } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Put -Uri "$(Get-ImportAuditTableUri)(PartitionKey='devicePolicies',RowKey='$DeviceId')" `
        -Authentication Bearer -Token $AccessToken -ContentType 'application/json' `
        -Headers @{ Accept = 'application/json;odata=nometadata'; 'x-ms-version' = '2019-02-02' } `
        -Body $body -ErrorAction Stop | Out-Null
}

function Get-AutoPilotDeviceRegistrationId {
    <#
    .SYNOPSIS
    Returns the registered Autopilot identity ID from a completed import.

    .DESCRIPTION
    Reads state.deviceRegistrationId and parses it as a GUID. This bridges
    Graph's temporary imported identity and its registered Autopilot identity.

    .PARAMETER ImportedDevice
    Imported Windows Autopilot device identity whose state contains the
    deviceRegistrationId returned by Microsoft Graph.

    .OUTPUTS
    System.Guid. Registered Autopilot identity ID, not an Entra device object ID.

    .EXAMPLE
    $registrationId = Get-AutoPilotDeviceRegistrationId -ImportedDevice $import

    Extracts the ID for a windowsAutopilotDeviceIdentities lookup.

    .NOTES
    Throws if state, the property or a parseable GUID is unavailable. Does not
    query Graph, check deviceImportStatus or wait for registration completion.
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
    Compares authorization-group references between two policy versions.

    .DESCRIPTION
    Normalizes groupId values as GUID strings and calculates references added
    to or removed from the policy. Does not inspect actual group memberships,
    tags, device target groups or other policy settings.

    .PARAMETER PreviousPolicy
    Existing tag authorization policy whose group IDs form the comparison
    baseline.

    .PARAMETER UpdatedPolicy
    Updated tag authorization policy whose group IDs are compared with the
    previous policy.

    .OUTPUTS
    PSCustomObject containing AddedGroupIds and RemovedGroupIds.

    .EXAMPLE
    $delta = Compare-TagAuthorizationPolicyGroups `
        -PreviousPolicy $previousPolicy -UpdatedPolicy $updatedPolicy

    Finds authorization-group references requiring configuration updates.

    .NOTES
    GUID conversion errors propagate. Input duplicates are not explicitly
    removed; callers normally supply normalized policies.
    #>
    [CmdletBinding()]
    param(
        [object[]] $PreviousPolicy = @(),

        [object[]] $UpdatedPolicy = @()
    )

    # Normalize textual GUID representations before comparing references.
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

    .DESCRIPTION
    Combines the manager policy's legacy principalIds with installerPrincipalId
    and additionalPrincipalIds. Normalizes valid GUIDs and checks whether the
    caller's object or claimed group IDs intersect that allowlist.

    .PARAMETER Principal
    Decoded Easy Auth principal containing object and group claims.

    .PARAMETER ManagerPolicy
    Policy containing any of principalIds, installerPrincipalId and
    additionalPrincipalIds as user/group object IDs.

    .OUTPUTS
    System.Boolean. True when the caller or one of its claimed groups is listed.

    .EXAMPLE
    $allowed = Test-TagPolicyManagerPrincipal -Principal $principal `
        -ManagerPolicy $managerPolicy

    Evaluates explicit manager authorization without querying Graph.

    .NOTES
    Invalid GUID entries are ignored. This helper uses supplied claims only;
    it does not refresh memberships or check the optional Intune admin role.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Principal,

        [Parameter(Mandatory)]
        [object] $ManagerPolicy
    )

    # Accept both the original flat allowlist and the installer/additional
    # manager schema so older deployments remain readable.
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

    .DESCRIPTION
    Acquires a Graph token from the current Az context, retrieves all Intune
    role-assignment pages with expanded role definitions, and delegates the
    caller/assignment comparison to Test-IntuneRoleAdministratorAssignment.

    .PARAMETER Principal
    Decoded Easy Auth principal containing object and group claims.

    .OUTPUTS
    System.Boolean. True when an Intune Role Administrator assignment covers
    the caller or one of its claimed groups.

    .EXAMPLE
    $isIntuneAdmin = Test-IntuneRoleAdministrator -Principal $principal

    Checks current Intune assignments against the caller's supplied claims.

    .NOTES
    Requires Az.Accounts and Graph Intune RBAC read access. Token/Graph errors
    propagate; they are not converted into a negative authorization result.
    Does not resolve fresh group claims or evaluate Entra directory roles.
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

    # Intune application RBAC assignments are separate from Azure resource
    # roles and Entra directory roles; inspect the Intune collection directly.
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

    .DESCRIPTION
    Matches built-in role names Owner or Contributor at the Function resource
    or an ancestor scope. Normalizes trailing slashes and compares ancestor
    prefixes ignoring case with a path boundary.

    .PARAMETER RoleAssignment
    Effective Azure role assignments for the current principal and its groups.

    .PARAMETER FunctionResourceId
    Full Azure resource ID of the Function App.

    .OUTPUTS
    System.Boolean. True only for Owner or Contributor at the Function scope or
    an ancestor scope.

    .EXAMPLE
    Test-TagManagerPolicyAdministratorRole -RoleAssignment $assignments `
        -FunctionResourceId $functionResourceId

    Evaluates role assignments already resolved for the caller and its groups.

    .NOTES
    No Azure lookup occurs. Caller must provide effective assignments and a
    trusted resource ID. Custom-role permissions and deny assignments are not
    evaluated; matching is by the two role names and scope only.
    #>
    [CmdletBinding()]
    param(
        [object[]] $RoleAssignment = @(),

        [Parameter(Mandatory)]
        [string] $FunctionResourceId
    )

    # Include the slash boundary so a sibling resource with a common name
    # prefix cannot be mistaken for a parent scope.
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

    .DESCRIPTION
    Collects the caller's object/group claims and the members of assignments
    whose expanded roleDefinition displayName is Intune Role Administrator.
    Returns whether any IDs intersect.

    .PARAMETER Principal
    Decoded Easy Auth principal containing object and group claims.

    .PARAMETER RoleAssignment
    Intune deviceAndAppManagementRoleAssignment objects with roleDefinition and
    members properties.

    .OUTPUTS
    System.Boolean. False when there is no matching assignment member.

    .EXAMPLE
    Test-IntuneRoleAdministratorAssignment -Principal $principal `
        -RoleAssignment $intuneAssignments

    Performs the pure comparison after assignments have been fetched.

    .NOTES
    No network calls or group expansion occur. Requires expanded roleDefinition
    data; assignments without a displayName are not considered. Matching uses
    the role display name, not a role-definition GUID.
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
    # Skip incomplete/unexpanded assignments rather than assuming every role
    # in the response grants the administrative capability.
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

    .DESCRIPTION
    Base64-decodes the header as UTF-8 JSON and requires a nonempty claims
    property. Returns the principal without changing its other properties.

    .PARAMETER HeaderValue
    Base64-encoded UTF-8 JSON value from the x-ms-client-principal header.

    .OUTPUTS
    PSCustomObject containing the decoded Easy Auth principal and claims.

    .EXAMPLE
    $principal = ConvertFrom-ClientPrincipalHeader `
        -HeaderValue $Request.Headers['x-ms-client-principal']

    Decodes the trusted header passed to a Function by Easy Auth.

    .NOTES
    Converts Base64/JSON decoding errors and empty claims to ArgumentException.
    Does not validate signatures, tenant, audience, object IDs or individual
    claim values. Easy Auth must authenticate the request and protect the
    header boundary before this helper is used.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $HeaderValue
    )

    try {
        # This is an encoded principal description, not a JWT validation step.
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

    .DESCRIPTION
    Searches roles, the fully qualified role claim type and any principal
    role_typ alias for a value equal to RequiredRole. Uses PowerShell's default
    case-insensitive equality comparison.

    .PARAMETER Principal
    Decoded Easy Auth principal containing a claims collection.

    .PARAMETER RequiredRole
    App-role value required for authorization, compared without case sensitivity.

    .OUTPUTS
    System.Boolean. True when a matching role claim exists; otherwise false.

    .EXAMPLE
    Test-ClientPrincipalRole -Principal $principal -RequiredRole 'ImportDevices'

    Checks an application-role claim in an already decoded principal.

    .NOTES
    Does not fetch memberships/role assignments or authenticate the principal.
    Callers supply the expected Easy Auth schema, including role_typ when used.
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
        # Easy Auth can identify an issuer-specific role claim type.
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

    .DESCRIPTION
    Validates caller/group GUIDs and calls Graph users/{id}/checkMemberGroups
    with up to 20 distinct policy groups per request. Replaces all incoming
    group claims with matching IDs returned for those batches, preserving
    other claims and principal properties in a new principal object.

    .PARAMETER Principal
    Decoded Easy Auth principal containing the caller object ID.

    .PARAMETER Policy
    Collection of rules whose group IDs are checked through Microsoft Graph.

    .PARAMETER AccessToken
    Microsoft Graph token acquired by the Function managed identity.

    .OUTPUTS
    PSCustomObject containing the original non-group claims and current group
    claims returned by Microsoft Graph.

    .EXAMPLE
    $current = Get-CurrentPolicyPrincipal -Principal $principal `
        -Policy $policy -AccessToken $graphToken

    Refreshes only memberships relevant to the configured authorization rules.

    .NOTES
    Throws ArgumentException for an invalid caller object ID or policy group
    GUID. Graph errors propagate with no stale-claim fallback. Requires Graph
    permission to check the user's memberships; does not authenticate a token.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Principal,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
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

    # Graph accepts at most 20 checkMemberGroups IDs per request. Restrict
    # returned claims to IDs actually requested, not unrelated memberships.
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
    # Drop the original group claims entirely; unioning them with fresh data
    # would keep revoked memberships authorized until token expiry.
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

    .DESCRIPTION
    Trims and validates the requested tag, then finds the first policy rule
    whose groupId is in the caller's group claims and whose tags contain a
    case-insensitive match. Returns the configured spelling, not client casing.

    .PARAMETER Principal
    Decoded Easy Auth principal containing Entra security-group claims.

    .PARAMETER Policy
    Collection of rules with groupId and tags properties.

    .PARAMETER RequestedGroupTag
    Group Tag requested by the API caller. Matching is case-insensitive.

    .OUTPUTS
    System.String. Returns the configured Group Tag with its canonical casing.

    .EXAMPLE
    $tag = Resolve-AuthorizedGroupTag -Principal $principal -Policy $policy `
        -RequestedGroupTag ' bg-default '

    Resolves BG-Default when an applicable rule contains that configured tag.

    .NOTES
    Throws ArgumentException for blank tags or more than 128 trimmed characters,
    and UnauthorizedAccessException when no caller group permits the tag.
    Uses supplied claims only; refresh them beforehand when current membership
    is required.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Principal,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
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

    # Return the server-configured value so downstream writes use canonical
    # tag casing even when the request used different casing or whitespace.
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

    .DESCRIPTION
    Selects rules matching caller group claims, flattens their tags, removes
    blank entries, trims text and returns a sorted unique list.

    .PARAMETER Principal
    Decoded Easy Auth principal containing Entra security-group claims.

    .PARAMETER Policy
    Collection of rules with groupId and tags properties.

    .OUTPUTS
    System.String values, sorted and deduplicated after trimming. No output
    when no rule grants tags; callers can use @() for stable array semantics.

    .EXAMPLE
    $tags = @(Get-AuthorizedGroupTags -Principal $principal -Policy $policy)

    Builds the caller's allowed-tag list for API/frontend responses.

    .NOTES
    Does not refresh memberships, query Graph or validate the complete policy.
    Matching and uniqueness use PowerShell's default comparison behavior.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Principal,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
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

    # Several caller groups can grant the same tag; expose one normalized
    # choice rather than duplicate entries in the selection list.
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

    .DESCRIPTION
    Requires a nonblank serial number (trimmed, at most 128 characters) and
    hardwareIdentifier (at most 65,536 characters, nonempty decoded Base64).
    Creates only the Graph type marker and the three supported import fields.

    .PARAMETER RequestBody
    Request object containing serialNumber and Base64 hardwareIdentifier.

    .PARAMETER GroupTag
    Server-authorized Group Tag. Any Group Tag in RequestBody is ignored.

    .OUTPUTS
    OrderedDictionary suitable for the importedWindowsAutopilotDeviceIdentities
    Microsoft Graph endpoint.

    .EXAMPLE
    ConvertTo-AutoPilotImportPayload -RequestBody ([pscustomobject]@{
        serialNumber = 'SERIAL-001'
        hardwareIdentifier = 'AQID'
    }) -GroupTag 'BG-Default'

    Illustrates payload construction; the short sample hash is not intended
    to represent a real device accepted by Intune.

    .NOTES
    Throws ArgumentException for failed explicit field checks; parameter
    validation and missing-property errors can also propagate. Does not
    authorize the tag, import a device or verify hash semantics beyond Base64.
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

    # Limit encoded input before allocating decoded bytes for validation.
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

    # Whitelist Graph fields explicitly; never forward arbitrary request
    # properties or replace the server-authorized GroupTag with client input.
    return [ordered]@{
        '@odata.type'      = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
        groupTag          = $GroupTag
        serialNumber      = $serialNumber
        hardwareIdentifier = $hardwareIdentifier
    }
}

function Find-EntraPolicyGroups {
    <#
    .SYNOPSIS
    Searches Entra groups or administrative units for policy selection.

    .DESCRIPTION
    Treats a GUID search as an exact ID lookup and other input as a display-name
    prefix. For groups, requests at most 25 results and detects more via
    @odata.nextLink. For AUs, reads all pages and filters/sorts locally before
    selecting the first 25.

    .PARAMETER SearchText
    Search text of 2..128 characters. Trimmed text must still contain at least
    two characters. A parseable GUID selects ID equality instead of a prefix.

    .PARAMETER ObjectType
    groups (default) or administrativeUnits.

    .PARAMETER AccessToken
    SecureString Graph token with read permission for the selected object type.

    .OUTPUTS
    PSCustomObject with groups (array of id/displayName objects) and hasMore.
    The groups property name is retained even for administrative-unit results.

    .EXAMPLE
    Find-EntraPolicyGroups -SearchText 'Managed' `
        -ObjectType administrativeUnits -AccessToken $graphToken

    Returns up to 25 matching AUs for a policy picker.

    .NOTES
    Read-only. Does not authorize the caller or enforce device-target group
    eligibility; use Assert-DevicePolicyGroups separately. Validation and Graph
    errors propagate. Group pages beyond the first 25 are not fetched here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateLength(2, 128)]
        [string] $SearchText,

        [ValidateSet('groups', 'users', 'administrativeUnits')]
        [string] $ObjectType = 'groups',

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken
    )

    $query = $SearchText.Trim()
    if ($query.Length -lt 2) { throw 'Group search requires at least two characters.' }
    $groupId = [guid]::Empty
    if ($ObjectType -eq 'administrativeUnits') {
        $isId = [guid]::TryParse($query, [ref] $groupId)
        # AU list supports eq, not startswith; filter names locally across all pages.
        $units = @(Get-PolicyGraphCollection `
            -Uri 'https://graph.microsoft.com/v1.0/directory/administrativeUnits?$select=id,displayName' `
            -AccessToken $AccessToken | Where-Object {
                if ($isId) { [string] $_.id -eq $groupId.ToString() }
                else { ([string] $_.displayName).StartsWith($query, [StringComparison]::OrdinalIgnoreCase) }
            } | Sort-Object displayName, id)
        return [pscustomobject]@{
            groups = @($units | Select-Object -First 25 | ForEach-Object {
                [pscustomobject]@{ id = [string] $_.id; displayName = [string] $_.displayName }
            })
            hasMore = $units.Count -gt 25
        }
    }
    # Escape apostrophes inside OData literals before URL-encoding the filter.
    # Group search can use server-side startswith unlike the AU branch above.
    $filter = if ([guid]::TryParse($query, [ref] $groupId)) {
        "id eq '$($groupId.ToString())'"
    } else {
        $escaped = $query.Replace("'", "''")
        if ($ObjectType -eq 'users') {
            "(startswith(displayName,'$escaped') or startswith(userPrincipalName,'$escaped'))"
        } else {
            "startswith(displayName,'$escaped')"
        }
    }
    $select = if ($ObjectType -eq 'users') { 'id,displayName,userPrincipalName' } else { 'id,displayName' }
    try {
        $response = Invoke-RestMethod -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/${ObjectType}?`$filter=$([uri]::EscapeDataString($filter))&`$select=$select&`$top=25" `
            -Authentication Bearer -Token $AccessToken -ErrorAction Stop
    }
    catch {
        # Graph optimizes id eq into an entity lookup: a user ID on /groups
        # (or a group ID on /users) is 404, not an empty collection.
        if ($groupId -ne [guid]::Empty -and
            $_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException] -and
            $_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
            return [pscustomobject]@{ groups = @(); hasMore = $false }
        }
        throw
    }
    [pscustomobject]@{
        groups = @($response.value | Sort-Object displayName, id | ForEach-Object {
            $displayName = [string] $_.displayName
            if ($ObjectType -eq 'users' -and $_.PSObject.Properties['userPrincipalName']) {
                $displayName = "$displayName ($($_.userPrincipalName))"
            }
            [pscustomobject]@{ id = [string] $_.id; displayName = $displayName }
        })
        hasMore = $null -ne $response.PSObject.Properties['@odata.nextLink'] -and
            -not [string]::IsNullOrWhiteSpace([string] $response.'@odata.nextLink')
    }
}

Export-ModuleMember -Function @(
    'Find-EntraPolicyGroups',
    'ConvertFrom-BlobBindingContent',
    'Get-ImportAuditTableUri',
    'Get-ImportAuditAccessToken',
    'Get-DeviceHashSha256',
    'Set-ImportAuditRecord',
    'Get-ProcessingFailureAudit',
    'Test-ProcessingFailed',
    'Get-ImportAuditRecords',
    'Get-ImportAuditRetentionCutoffUtc',
    'Get-ImportAuditHistory',
    'ConvertTo-AuditTimestamp',
    'Get-TagChangeProcessingStage',
    'Resolve-RecentTagChangeGroupTag',
    'Remove-ExpiredImportAuditRecords',
    'Write-ManagementAuditEvent',
    'Get-TagPolicyRuleId',
    'Get-ManagementAuditHistory',
    'Set-ManagementPolicyBlob',
    'ConvertTo-TagAuthorizationPolicy',
    'ConvertTo-EntraDeviceExtensionAttributes',
    'Get-PolicyGraphCollection',
    'Get-DevicePolicyActions',
    'Assert-DevicePolicyGroups',
    'Sync-DevicePolicyGroups',
    'Get-DevicePolicyState',
    'Set-DevicePolicyState',
    'Resolve-AdministrativeUnitName',
    'Resolve-EffectiveAdministrativeUnitName',
    'Resolve-EntraAdministrativeUnit',
    'Add-EntraDeviceToAdministrativeUnit',
    'Sync-EntraDeviceAdministrativeUnits',
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