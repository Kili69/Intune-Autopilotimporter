# Project-Version: 1.0.20260812.2
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

function ConvertTo-TagAuthorizationPolicy {
    <#
    .SYNOPSIS
    Converts group-to-tag rules into a normalized authorization policy.

    .PARAMETER Rules
    Rules in the form <group-object-id>=<tag1>,<tag2>.

    .OUTPUTS
    PSCustomObject entries with groupId and tags properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Rules
    )

    $enteredRules = @($Rules | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($enteredRules.Count -eq 0) {
        throw 'At least one group and tag rule is required.'
    }

    $rulesByGroup = @{}
    foreach ($rule in $enteredRules) {
        $separatorIndex = $rule.IndexOf('=')
        if ($separatorIndex -lt 1 -or $separatorIndex -eq $rule.Length - 1) {
            throw "Invalid TagAuthorizationRule '$rule'. Expected '<group-object-id>=<tag1>,<tag2>'."
        }

        $groupId = $rule.Substring(0, $separatorIndex).Trim()
        $parsedGroupId = [guid]::Empty
        if (-not [guid]::TryParse($groupId, [ref] $parsedGroupId)) {
            throw "Group Object ID '$groupId' must be a GUID."
        }
        $normalizedGroupId = $parsedGroupId.ToString()

        $tags = @($rule.Substring($separatorIndex + 1).Split(',') | ForEach-Object {
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
        }

        $rulesByGroup[$normalizedGroupId] = @(
            @($rulesByGroup[$normalizedGroupId]) + $tags | Select-Object -Unique
        )
    }

    return ,@($rulesByGroup.Keys | Sort-Object | ForEach-Object {
        [pscustomobject]@{
            groupId = $_
            tags    = @($rulesByGroup[$_] | Sort-Object)
        }
    })
}

function Compare-TagAuthorizationPolicyGroups {
    <#
    .SYNOPSIS
    Compares group membership between two tag authorization policies.

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
        ([guid] $_).ToString()
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
        $_.roleDefinition.displayName -eq 'Intune Role Administrator'
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

function ConvertTo-AutopilotImportPayload {
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
    'ConvertTo-TagAuthorizationPolicy',
    'Compare-TagAuthorizationPolicyGroups',
    'Test-TagPolicyManagerPrincipal',
    'Test-TagManagerPolicyAdministratorRole',
    'Test-IntuneRoleAdministratorAssignment',
    'ConvertFrom-ClientPrincipalHeader',
    'Test-ClientPrincipalRole',
    'Resolve-AuthorizedGroupTag',
    'ConvertTo-AutopilotImportPayload'
)