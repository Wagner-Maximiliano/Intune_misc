#requires -Version 5.1

<#
Restore-IntunePolicy.ps1

Phase 5: creates a brand new Settings Catalog policy in Intune from a JSON
snapshot written by Backup-IntunePolicies.ps1 / Get-IntuneSettingsCatalogSnapshot.ps1.

THIS IS THE FIRST WRITE OPERATION IN THIS PROJECT. Its scope is deliberately
narrow and was fixed by design discussion - do not deviate without confirming:

  1. CREATE-ONLY, NEVER OVERWRITE. This always POSTs a brand new policy
     (beta/deviceManagement/configurationPolicies) with its own new Id. It
     never PATCHes or replaces an existing policy, even if the original
     policy still exists. There is no "restore in place" mode.

  2. ASSIGNMENTS ARE NEVER TOUCHED VIA THE API. This script never calls
     .../assign and never creates an assignment. The new policy comes out
     completely unassigned - assigning it to groups is a manual step you do
     afterward in the Intune portal, on purpose (a safety boundary, not a
     missing feature).

  3. Instead, the original policy's assignments (from the JSON's Assignments
     array - already-resolved group/filter names, no extra Graph calls) are
     printed to the console so you know what to re-apply manually.

This is a single, self-contained file. There is nothing else to dot-source
and no other file it depends on.

MODULES REQUIRED - this script does NOT import them for you. Import this
yourself first, once per PowerShell session, before running the script:

    Import-Module Microsoft.Graph.Authentication

CONNECTION - this script does NOT force a new Graph connection. It checks
Get-MgContext first: if you're already connected (e.g. you ran Connect-MgGraph
yourself with a specific app registration/ClientId), it uses that connection
as-is and never calls Connect-MgGraph. It only connects itself when there is
no existing connection. Because this script WRITES to Intune, it requests
DeviceManagementConfiguration.ReadWrite.All (the other scripts in this
project only ever request .Read.All).

Usage (run the .ps1 file directly, don't paste it line-by-line):
    Connect-MgGraph -ClientId <your app id> -TenantId <your tenant id>
    .\Restore-IntunePolicy.ps1 -JsonFile .\output\json\2026-07-08_143022\MyPolicy__<id>.json
    .\Restore-IntunePolicy.ps1 -JsonFile <path> -NewName 'MyPolicy (recovered)'
    .\Restore-IntunePolicy.ps1 -JsonFile <path> -UseOriginalName
    .\Restore-IntunePolicy.ps1 -JsonFile <path> -WhatIf

Naming: by default the restored policy is named
"<original name> (restored yyyy-MM-dd)" so it's never confused with a still-
live original of the same name. Use -NewName to pick an exact name, or
-UseOriginalName to reproduce the original name verbatim.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$JsonFile,

    # Exact name to give the restored policy. Overrides the default naming
    # (and -UseOriginalName, if both are given).
    [string]$NewName,

    # Reproduce the original policy's name verbatim instead of appending the
    # default "(restored yyyy-MM-dd)" marker.
    [switch]$UseOriginalName,

    [string]$TenantId
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function ConvertFrom-JsonFile {
    <# Reads a JSON file, stripping a leading BOM if present (5.1's
       Set-Content -Encoding utf8 adds one, which breaks ConvertFrom-Json). #>
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -Path $Path -Raw
    if ($raw) { $raw = $raw.TrimStart([char]0xFEFF) }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Format-AssignmentList {
    <# Same rendering used by Backup-IntunePolicies.ps1 / Export-PolicySummary.ps1:
       "GroupName [filter: FilterName/FilterType], ...". #>
    param($Assignments, [switch]$Exclude)
    $items = @($Assignments) | Where-Object { $_.IsExclude -eq [bool]$Exclude -and $_.GroupId }
    if (-not $items) {
        if (-not $Exclude) {
            $special = @($Assignments) | Where-Object { -not $_.GroupId -and -not $_.IsExclude } | ForEach-Object { $_.AssignmentType }
            if ($special) { return ($special -join ', ') }
        }
        return ''
    }
    return (($items | ForEach-Object {
        if ($_.FilterName) { "$($_.GroupName) [filter: $($_.FilterName)/$($_.FilterType)]" } else { $_.GroupName }
    }) -join ', ')
}

# ----------------------------------------------------------------------------
# Load + validate the snapshot
# ----------------------------------------------------------------------------

if (-not (Test-Path $JsonFile -PathType Leaf)) {
    throw "JSON file not found: $JsonFile"
}

$Snapshot = ConvertFrom-JsonFile -Path $JsonFile
if (-not $Snapshot) {
    throw "'$JsonFile' is empty or not valid JSON."
}

if ($Snapshot.PolicyType -and $Snapshot.PolicyType -ne 'SettingsCatalog') {
    throw "Only Settings Catalog snapshots are supported by this script. Found PolicyType: '$($Snapshot.PolicyType)'."
}
if (-not $Snapshot.Name) {
    throw "'$JsonFile' has no Name property - this doesn't look like a policy snapshot from this project."
}

# @(...) wrap: a snapshot with exactly one setting would otherwise collapse
# to a scalar pscustomobject, and .Count on that still works, but downstream
# foreach/indexing assumptions elsewhere in this project have been bitten by
# this before - stay consistent and always wrap.
$originalSettings = @($Snapshot.Settings)

# ----------------------------------------------------------------------------
# Build the new policy name
# ----------------------------------------------------------------------------

if ($NewName) {
    $newPolicyName = $NewName
}
elseif ($UseOriginalName) {
    $newPolicyName = $Snapshot.Name
}
else {
    $newPolicyName = "{0} (restored {1})" -f $Snapshot.Name, (Get-Date).ToString('yyyy-MM-dd')
}

# ----------------------------------------------------------------------------
# Build the create payload
#
# Graph's create endpoint (POST /deviceManagement/configurationPolicies) wants
# each settings[] entry as { "@odata.type": "#microsoft.graph.deviceManagementConfigurationSetting",
# "settingInstance": {...} } - no "id", no "settingDefinitions" (that's a
# read-only $expand added by the backup scripts to resolve friendly titles).
# The nested settingInstance tree round-trips as-is; its own @odata.type
# values came from Graph originally and don't need to be rebuilt.
# ----------------------------------------------------------------------------

$settingsPayload = @(
    foreach ($s in $originalSettings) {
        $odataType = $s.'@odata.type'
        if (-not $odataType) { $odataType = '#microsoft.graph.deviceManagementConfigurationSetting' }
        [ordered]@{
            '@odata.type'   = $odataType
            settingInstance = $s.settingInstance
        }
    }
)

$description = if ($null -eq $Snapshot.Description) { '' } else { $Snapshot.Description }

$payload = [ordered]@{
    '@odata.type' = '#microsoft.graph.deviceManagementConfigurationPolicy'
    name          = $newPolicyName
    description   = $description
    platforms     = $Snapshot.Platforms
    technologies  = $Snapshot.Technologies
    settings      = $settingsPayload
}

# ----------------------------------------------------------------------------
# Print what's about to happen - always, even under -WhatIf
# ----------------------------------------------------------------------------

Write-Host 'About to create a NEW Settings Catalog policy from snapshot:'
Write-Host "  Source JSON     : $JsonFile"
Write-Host "  Original name   : $($Snapshot.Name)"
Write-Host "  New policy name : $newPolicyName"
Write-Host "  Platforms       : $($Snapshot.Platforms)"
Write-Host "  Technologies    : $($Snapshot.Technologies)"
Write-Host "  Settings count  : $($settingsPayload.Count)"
Write-Host ''
Write-Host 'Original assignments (READ-ONLY - this script never assigns anything):'
$includedText = Format-AssignmentList -Assignments $Snapshot.Assignments
$excludedText = Format-AssignmentList -Assignments $Snapshot.Assignments -Exclude
Write-Host "  Included: $(if ($includedText) { $includedText } else { '(none)' })"
Write-Host "  Excluded: $(if ($excludedText) { $excludedText } else { '(none)' })"
Write-Host '  -> Re-apply these manually in the Intune portal once the restored policy looks right.'
Write-Host ''

if ($settingsPayload.Count -eq 0) {
    Write-Warning 'This snapshot has zero settings - the restored policy will be created empty.'
}

# ----------------------------------------------------------------------------
# Connect (reuse existing context, never force a new one)
# ----------------------------------------------------------------------------

$existingContext = Get-MgContext
if ($existingContext) {
    Write-Host "Using existing Graph connection (Account: $($existingContext.Account), Tenant: $($existingContext.TenantId))."
}
else {
    Write-Host 'No existing Graph connection found - connecting...'
    $connectParams = @{ Scopes = @('DeviceManagementConfiguration.ReadWrite.All') }
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    Connect-MgGraph @connectParams | Out-Null
    Write-Host "Connected to tenant: $((Get-MgContext).TenantId)"
}

# ----------------------------------------------------------------------------
# Create
# ----------------------------------------------------------------------------

$uri = 'beta/deviceManagement/configurationPolicies'

if ($PSCmdlet.ShouldProcess($newPolicyName, "POST $uri (create new policy)")) {
    $body = $payload | ConvertTo-Json -Depth 20
    $created = Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -ContentType 'application/json'

    Write-Host ''
    Write-Host "Created new policy '$($created.name)' with Id: $($created.id)"
    Write-Host 'It has NO assignments yet - apply the ones listed above manually in the Intune portal.'
}
else {
    Write-Host '(WhatIf: no policy was created.)'
}
