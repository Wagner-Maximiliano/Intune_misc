#requires -Version 5.1
<#
.SYNOPSIS
    Collects local evidence for validating MDMWinsOverGP on a Windows device.

.DESCRIPTION
    This script gathers:
      - MDMWinsOverGP state
      - PolicyManager effective device and user policy values
      - GPResult XML, HTML, and text
      - DeviceManagement-Enterprise-Diagnostics-Provider logs and EVTX exports
      - MDM diagnostic output
      - Registry policy snapshots
      - Candidate overlaps between GPO and MDM settings
      - Verified overlaps supplied through an optional mapping CSV
      - HTML and CSV reports

    Important:
      - Event 881 is treated as MDM PolicyManager activity, not proof of a GPO conflict.
      - Automatic name matching is heuristic.
      - A verified one-to-one GPO-to-CSP mapping requires a mapping CSV or manual validation.
      - MDMWinsOverGP applies to Policy CSP settings, not every Windows management CSP.

.PARAMETER OutputRoot
    Parent folder for the evidence package.

.PARAMETER SinceHours
    Number of hours of DeviceManagement events to include in CSV reports.

.PARAMETER MappingCsv
    Optional CSV containing verified GPO-to-CSP mappings.

    Supported columns:
      GpoSetting
      GpoName
      CspArea
      CspPolicy
      OmaUri
      Notes

.PARAMETER EnableDebugLog
    Enables the DeviceManagement-Enterprise-Diagnostics-Provider Debug channel.

.PARAMETER DisableDebugLogAfterCollection
    Disables the Debug channel after collection, but only when this run enabled it.

.PARAMETER RunGpUpdate
    Runs gpupdate /force before collecting GPResult.

.PARAMETER SkipMdmDiagnostics
    Skips MdmDiagnosticsTool.exe.

.EXAMPLE
    .\Test-MDMWinsOverGP.ps1 -EnableDebugLog -RunGpUpdate

.EXAMPLE
    .\Test-MDMWinsOverGP.ps1 -MappingCsv .\PolicyMappings.csv -SinceHours 48
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:PUBLIC\Documents\MDMWinsOverGP-Validation",
    [ValidateRange(1, 720)]
    [int]$SinceHours = 24,
    [string]$MappingCsv,
    [switch]$EnableDebugLog,
    [switch]$DisableDebugLogAfterCollection,
    [switch]$RunGpUpdate,
    [switch]$SkipMdmDiagnostics
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '_')
}

function Convert-ValueToText {
    param($Value)

    if ($null -eq $Value) { return '' }

    if ($Value -is [byte[]]) {
        return [BitConverter]::ToString($Value)
    }

    if ($Value -is [array]) {
        return ($Value | ForEach-Object { [string]$_ }) -join '; '
    }

    return [string]$Value
}

function Get-RegistryTreeValues {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('MDM','GPORegistry','Provider')][string]$Source,
        [string]$Scope = ''
    )

    $results = New-Object System.Collections.Generic.List[object]

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $keys = @()
    try {
        $keys += Get-Item -LiteralPath $Path -ErrorAction Stop
        $keys += Get-ChildItem -LiteralPath $Path -Recurse -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Could not enumerate registry path $Path. $($_.Exception.Message)"
        return @()
    }

    foreach ($key in $keys) {
        try {
            $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            $valueNames = $key.GetValueNames()

            foreach ($valueName in $valueNames) {
                if ([string]::IsNullOrWhiteSpace($valueName)) {
                    $displayName = '(Default)'
                }
                else {
                    $displayName = $valueName
                }

                $relativePath = $key.Name
                $leaf = Split-Path -Path $relativePath -Leaf
                $parent = Split-Path -Path $relativePath -Parent
                $area = Split-Path -Path $parent -Leaf

                $results.Add([pscustomobject]@{
                    Source       = $Source
                    Scope        = $Scope
                    RegistryPath = $relativePath
                    Area         = $area
                    Policy       = $leaf
                    ValueName    = $displayName
                    Value        = Convert-ValueToText -Value $key.GetValue($valueName)
                    ValueKind    = [string]$key.GetValueKind($valueName)
                })
            }
        }
        catch {
            Write-Verbose "Could not read $($key.PSPath): $($_.Exception.Message)"
        }
    }

    return $results.ToArray()
}

function Get-ControlPolicyConflictState {
    $path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ControlPolicyConflict'
    $result = [ordered]@{
        RegistryPath                = $path
        KeyPresent                  = $false
        MDMWinsOverGP               = $null
        MDMWinsOverGP_ProviderSet   = $null
        MDMWinsOverGP_WinningProvider = $null
        Interpretation              = 'Not detected'
    }

    if (Test-Path -LiteralPath $path) {
        $result.KeyPresent = $true
        $item = Get-ItemProperty -LiteralPath $path

        foreach ($name in @('MDMWinsOverGP','MDMWinsOverGP_ProviderSet','MDMWinsOverGP_WinningProvider')) {
            if ($item.PSObject.Properties.Name -contains $name) {
                $result[$name] = Convert-ValueToText $item.$name
            }
        }

        if ([string]$result.MDMWinsOverGP -eq '1') {
            $result.Interpretation = 'Enabled in the effective PolicyManager device store'
        }
        elseif ($null -ne $result.MDMWinsOverGP) {
            $result.Interpretation = 'Present, but not enabled'
        }
    }

    return [pscustomobject]$result
}

function Set-DmDebugLogState {
    param([Parameter(Mandatory)][bool]$Enabled)

    $logName = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Debug'
    $enabledText = if ($Enabled) { 'true' } else { 'false' }

    & "$env:SystemRoot\System32\wevtutil.exe" sl $logName "/e:$enabledText" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "wevtutil failed to set Debug log state to $Enabled."
    }
}

function Get-DmLogConfiguration {
    $logPattern = '*DeviceManagement-Enterprise-Diagnostics-Provider*'
    $logs = Get-WinEvent -ListLog $logPattern -ErrorAction SilentlyContinue

    foreach ($log in $logs) {
        [pscustomobject]@{
            LogName       = $log.LogName
            IsEnabled     = $log.IsEnabled
            RecordCount   = $log.RecordCount
            MaximumSizeMB = [math]::Round($log.MaximumSizeInBytes / 1MB, 2)
            LogMode       = $log.LogMode
        }
    }
}

function Export-DmEvents {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][datetime]$StartTime
    )

    $eventRows = New-Object System.Collections.Generic.List[object]
    $logConfigs = Get-DmLogConfiguration

    foreach ($config in $logConfigs) {
        $safeName = New-SafeFileName $config.LogName
        $evtxPath = Join-Path $Folder "$safeName.evtx"

        try {
            & "$env:SystemRoot\System32\wevtutil.exe" epl $config.LogName $evtxPath "/ow:true" 2>&1 | Out-Null
        }
        catch {
            Write-Warning "Could not export EVTX for $($config.LogName)."
        }

        try {
            $events = Get-WinEvent -FilterHashtable @{
                LogName   = $config.LogName
                StartTime = $StartTime
            } -ErrorAction Stop

            foreach ($event in $events) {
                $message = ''
                try { $message = $event.FormatDescription() } catch { $message = $event.Message }

                $eventRows.Add([pscustomobject]@{
                    TimeCreated = $event.TimeCreated
                    LogName     = $event.LogName
                    Id          = $event.Id
                    Level       = $event.LevelDisplayName
                    Provider    = $event.ProviderName
                    RecordId    = $event.RecordId
                    Message     = ($message -replace "`r?`n", ' | ')
                })
            }
        }
        catch {
            Write-Verbose "No readable recent events in $($config.LogName)."
        }
    }

    return [pscustomobject]@{
        Configuration = @($logConfigs)
        Events         = $eventRows.ToArray()
    }
}

function Invoke-GpResultCollection {
    param([Parameter(Mandatory)][string]$Folder)

    $xmlPath  = Join-Path $Folder 'GPResult.xml'
    $htmlPath = Join-Path $Folder 'GPResult.html'
    $textPath = Join-Path $Folder 'GPResult.txt'

    & "$env:SystemRoot\System32\gpresult.exe" /x $xmlPath /f 2>&1 |
        Out-File -LiteralPath (Join-Path $Folder 'GPResult-XML-command.txt') -Encoding utf8

    & "$env:SystemRoot\System32\gpresult.exe" /h $htmlPath /f 2>&1 |
        Out-File -LiteralPath (Join-Path $Folder 'GPResult-HTML-command.txt') -Encoding utf8

    & "$env:SystemRoot\System32\gpresult.exe" /r /scope computer 2>&1 |
        Out-File -LiteralPath $textPath -Encoding utf8

    return [pscustomobject]@{
        XmlPath  = $xmlPath
        HtmlPath = $htmlPath
        TextPath = $textPath
    }
}

function Get-FirstNodeText {
    param(
        [Parameter(Mandatory)][System.Xml.XmlNode]$Node,
        [Parameter(Mandatory)][string[]]$LocalNames
    )

    foreach ($name in $LocalNames) {
        $match = $Node.SelectSingleNode(".//*[local-name()='$name']")
        if ($match -and -not [string]::IsNullOrWhiteSpace($match.InnerText)) {
            return $match.InnerText.Trim()
        }
    }

    return ''
}

function Get-GpResultPolicyRows {
    param([Parameter(Mandatory)][string]$XmlPath)

    if (-not (Test-Path -LiteralPath $XmlPath)) {
        return @()
    }

    try {
        [xml]$xml = Get-Content -LiteralPath $XmlPath -Raw
    }
    catch {
        Write-Warning "Could not parse GPResult XML. $($_.Exception.Message)"
        return @()
    }

    $rows = New-Object System.Collections.Generic.List[object]

    # GPResult XML structure varies across Windows releases and policy extension types.
    # We capture nodes that appear to represent policy settings and retain raw XML for audit.
    $candidateNodes = $xml.SelectNodes(
        "//*[local-name()='Policy' or local-name()='Setting' or local-name()='RegistrySetting']"
    )

    foreach ($node in $candidateNodes) {
        $settingName = Get-FirstNodeText -Node $node -LocalNames @(
            'Name','PolicyName','SettingName','DisplayName','KeyName'
        )

        if ([string]::IsNullOrWhiteSpace($settingName)) {
            if ($node.Attributes['name']) {
                $settingName = $node.Attributes['name'].Value
            }
        }

        $state = Get-FirstNodeText -Node $node -LocalNames @(
            'State','Setting','Value','PolicyState'
        )

        $gpoName = Get-FirstNodeText -Node $node -LocalNames @(
            'GPOName','GPO','WinningGPO','SOMName'
        )

        $category = Get-FirstNodeText -Node $node -LocalNames @(
            'Category','CategoryName','ExtensionName'
        )

        $registryKey = Get-FirstNodeText -Node $node -LocalNames @(
            'RegistryKey','KeyPath','Path'
        )

        $registryValue = Get-FirstNodeText -Node $node -LocalNames @(
            'RegistryValue','ValueName'
        )

        if (-not [string]::IsNullOrWhiteSpace($settingName) -or
            -not [string]::IsNullOrWhiteSpace($registryKey)) {

            $rows.Add([pscustomobject]@{
                GpoSetting    = $settingName
                GpoName       = $gpoName
                State         = $state
                Category      = $category
                RegistryKey   = $registryKey
                RegistryValue = $registryValue
                XmlNodeName   = $node.LocalName
            })
        }
    }

    return $rows.ToArray() |
        Sort-Object GpoSetting, GpoName, RegistryKey, RegistryValue -Unique
}

function Normalize-PolicyName {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $normalized = $Text.ToLowerInvariant()
    $normalized = $normalized -replace '^(allow|enable|disable|configure|turnon|turnoff)', ''
    $normalized = $normalized -replace '[^a-z0-9]', ''
    return $normalized
}

function Get-TokenSet {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $expanded = $Text -creplace '([a-z])([A-Z])', '$1 $2'
    # Use -split (regex) rather than String.Split(@(...)): passing an untyped
    # array to .Split binds the single-String overload, so the text is never
    # tokenized. The character class covers whitespace and the previous
    # delimiters (space, _ - / \ . : ( ) [ ]); the trailing '-' is literal.
    return @(
        ($expanded.ToLowerInvariant() -split '[\s_/\\.:()\[\]-]+') |
        Where-Object {
            $_.Length -gt 2 -and
            $_ -notin @('policy','setting','windows','microsoft','computer','user','configure')
        } |
        Sort-Object -Unique
    )
}

function Get-JaccardScore {
    param(
        [string[]]$Left,
        [string[]]$Right
    )

    if ($Left.Count -eq 0 -or $Right.Count -eq 0) { return 0 }

    $intersection = @($Left | Where-Object { $Right -contains $_ } | Sort-Object -Unique)
    $union = @($Left + $Right | Sort-Object -Unique)

    if ($union.Count -eq 0) { return 0 }
    return [math]::Round($intersection.Count / $union.Count, 3)
}

function Get-MdmPolicyRows {
    param([object[]]$RegistryRows)

    $ignoredNames = @(
        '(Default)',
        'Behavior',
        'PolicyInstanceID',
        'PolicyInstanceID_ProviderSet',
        'PolicyInstanceID_WinningProvider'
    )

    $grouped = $RegistryRows |
        Where-Object {
            $_.Source -eq 'MDM' -and
            $_.ValueName -notin $ignoredNames -and
            $_.ValueName -notmatch '(_ProviderSet|_WinningProvider)$'
        } |
        Group-Object Scope, RegistryPath, Policy

    foreach ($group in $grouped) {
        $first = $group.Group | Select-Object -First 1
        $providerSet = $RegistryRows |
            Where-Object {
                $_.RegistryPath -eq $first.RegistryPath -and
                $_.ValueName -eq "$($first.ValueName)_ProviderSet"
            } |
            Select-Object -First 1

        $winningProvider = $RegistryRows |
            Where-Object {
                $_.RegistryPath -eq $first.RegistryPath -and
                $_.ValueName -eq "$($first.ValueName)_WinningProvider"
            } |
            Select-Object -First 1

        [pscustomobject]@{
            Scope           = $first.Scope
            Area            = $first.Area
            Policy          = $first.Policy
            ValueName       = $first.ValueName
            EffectiveValue  = $first.Value
            RegistryPath    = $first.RegistryPath
            ProviderSet     = if ($providerSet) { $providerSet.Value } else { '' }
            WinningProvider = if ($winningProvider) { $winningProvider.Value } else { '' }
            NormalizedName  = Normalize-PolicyName "$($first.Area) $($first.Policy) $($first.ValueName)"
            Tokens          = Get-TokenSet "$($first.Area) $($first.Policy) $($first.ValueName)"
        }
    }
}

function Import-VerifiedMappings {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Mapping CSV not found: $Path"
    }

    $rows = Import-Csv -LiteralPath $Path

    foreach ($row in $rows) {
        [pscustomobject]@{
            GpoSetting = [string]$row.GpoSetting
            GpoName    = [string]$row.GpoName
            CspArea    = [string]$row.CspArea
            CspPolicy  = [string]$row.CspPolicy
            OmaUri     = [string]$row.OmaUri
            Notes      = [string]$row.Notes
        }
    }
}

function Get-VerifiedOverlapRows {
    param(
        [object[]]$Mappings,
        [object[]]$GpoRows,
        [object[]]$MdmRows
    )

    foreach ($mapping in $Mappings) {
        $matchingGpo = @(
            $GpoRows | Where-Object {
                ($_.GpoSetting -eq $mapping.GpoSetting -or
                 (Normalize-PolicyName $_.GpoSetting) -eq (Normalize-PolicyName $mapping.GpoSetting)) -and
                ([string]::IsNullOrWhiteSpace($mapping.GpoName) -or $_.GpoName -eq $mapping.GpoName)
            }
        )

        $matchingMdm = @(
            $MdmRows | Where-Object {
                $_.Area -eq $mapping.CspArea -and
                ($_.Policy -eq $mapping.CspPolicy -or $_.ValueName -eq $mapping.CspPolicy)
            }
        )

        [pscustomobject]@{
            MatchType         = 'Verified mapping'
            Confidence        = 1
            GpoConfigured     = $matchingGpo.Count -gt 0
            MdmConfigured     = $matchingMdm.Count -gt 0
            GpoSetting        = $mapping.GpoSetting
            GpoName           = (@($matchingGpo | ForEach-Object { $_.GpoName }) | Where-Object { $_ } | Sort-Object -Unique) -join '; '
            GpoState          = (@($matchingGpo | ForEach-Object { $_.State }) | Where-Object { $_ } | Sort-Object -Unique) -join '; '
            CspArea           = $mapping.CspArea
            CspPolicy         = $mapping.CspPolicy
            MdmEffectiveValue = (@($matchingMdm | ForEach-Object { $_.EffectiveValue }) | Where-Object { $_ } | Sort-Object -Unique) -join '; '
            WinningProvider   = (@($matchingMdm | ForEach-Object { $_.WinningProvider }) | Where-Object { $_ } | Sort-Object -Unique) -join '; '
            OmaUri            = $mapping.OmaUri
            Status            = if ($matchingGpo.Count -gt 0 -and $matchingMdm.Count -gt 0) {
                                    'Confirmed overlap. Validate effective value and behavior.'
                                }
                                elseif ($matchingMdm.Count -gt 0) {
                                    'Mapped setting found only in MDM evidence.'
                                }
                                elseif ($matchingGpo.Count -gt 0) {
                                    'Mapped setting found only in GPO evidence.'
                                }
                                else {
                                    'Mapping not found in collected evidence.'
                                }
            Notes             = $mapping.Notes
        }
    }
}

function Get-HeuristicOverlapRows {
    param(
        [object[]]$GpoRows,
        [object[]]$MdmRows,
        [double]$MinimumScore = 0.5
    )

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($gpo in $GpoRows) {
        $gpoText = "$($gpo.Category) $($gpo.GpoSetting) $($gpo.RegistryValue)"
        $gpoNormalized = Normalize-PolicyName $gpoText
        $gpoTokens = Get-TokenSet $gpoText

        if ([string]::IsNullOrWhiteSpace($gpoNormalized)) { continue }

        $best = $null
        $bestScore = 0.0

        foreach ($mdm in $MdmRows) {
            $score = 0.0

            if ($gpoNormalized -eq $mdm.NormalizedName) {
                $score = 1.0
            }
            elseif ($gpoNormalized.Length -ge 6 -and
                    $mdm.NormalizedName.Length -ge 6 -and
                    ($mdm.NormalizedName.Contains($gpoNormalized) -or
                     $gpoNormalized.Contains($mdm.NormalizedName))) {
                $score = 0.8
            }
            else {
                $score = Get-JaccardScore -Left $gpoTokens -Right $mdm.Tokens
            }

            if ($score -gt $bestScore) {
                $bestScore = $score
                $best = $mdm
            }
        }

        if ($best -and $bestScore -ge $MinimumScore) {
            $results.Add([pscustomobject]@{
                MatchType         = 'Heuristic candidate'
                Confidence        = $bestScore
                GpoConfigured     = $true
                MdmConfigured     = $true
                GpoSetting        = $gpo.GpoSetting
                GpoName           = $gpo.GpoName
                GpoState          = $gpo.State
                CspArea           = $best.Area
                CspPolicy         = $best.Policy
                MdmEffectiveValue = $best.EffectiveValue
                WinningProvider   = $best.WinningProvider
                OmaUri            = ''
                Status            = 'Candidate only. Confirm the Microsoft CSP mapping before treating this as a conflict.'
                Notes             = "Name similarity score: $bestScore"
            })
        }
    }

    # Use hashtable sort keys so the mixed ascending/descending sort parses
    # unambiguously. "Sort-Object Confidence -Descending, GpoSetting" does not
    # bind the way it reads and can fail under Set-StrictMode.
    return $results.ToArray() |
        Sort-Object -Property `
            @{ Expression = 'Confidence'; Descending = $true }, `
            @{ Expression = 'GpoSetting'; Descending = $false } `
            -Unique
}

function ConvertTo-HtmlEncoded {
    param([object]$Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Convert-ObjectsToHtmlTable {
    param(
        [object[]]$Rows,
        [string[]]$Properties,
        [string]$EmptyMessage = 'No records found.'
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        return "<p>$([System.Net.WebUtility]::HtmlEncode($EmptyMessage))</p>"
    }

    $header = ($Properties | ForEach-Object { "<th>$(ConvertTo-HtmlEncoded $_)</th>" }) -join ''
    $bodyRows = foreach ($row in $Rows) {
        $cells = foreach ($property in $Properties) {
            "<td>$(ConvertTo-HtmlEncoded $row.$property)</td>"
        }
        "<tr>$($cells -join '')</tr>"
    }

    return "<table><thead><tr>$header</tr></thead><tbody>$($bodyRows -join "`n")</tbody></table>"
}

function New-HtmlReport {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$ConflictState,
        [Parameter(Mandatory)][object[]]$LogConfiguration,
        [Parameter(Mandatory)][object[]]$Events,
        [Parameter(Mandatory)][object[]]$GpoRows,
        [Parameter(Mandatory)][object[]]$MdmRows,
        [Parameter(Mandatory)][object[]]$VerifiedRows,
        [Parameter(Mandatory)][object[]]$HeuristicRows,
        [Parameter(Mandatory)][string]$EvidenceFolder
    )

    $event881 = @($Events | Where-Object Id -eq 881)
    $eventErrors = @($Events | Where-Object { $_.Level -in @('Error','Critical','Warning') })

    $verifiedBoth = @($VerifiedRows | Where-Object { $_.GpoConfigured -and $_.MdmConfigured })
    $summaryRows = @(
        [pscustomobject]@{ Metric = 'MDMWinsOverGP'; Value = $ConflictState.Interpretation }
        [pscustomobject]@{ Metric = 'GPO settings parsed'; Value = $GpoRows.Count }
        [pscustomobject]@{ Metric = 'PolicyManager effective rows'; Value = $MdmRows.Count }
        [pscustomobject]@{ Metric = 'Verified overlaps'; Value = $verifiedBoth.Count }
        [pscustomobject]@{ Metric = 'Heuristic candidates'; Value = $HeuristicRows.Count }
        [pscustomobject]@{ Metric = 'Recent Event 881 records'; Value = $event881.Count }
        [pscustomobject]@{ Metric = 'Recent warning/error/critical events'; Value = $eventErrors.Count }
        [pscustomobject]@{ Metric = 'Evidence folder'; Value = $EvidenceFolder }
    )

    $css = @'
body { font-family: Segoe UI, Arial, sans-serif; margin: 28px; color: #202124; }
h1, h2 { color: #1f3a5f; }
table { border-collapse: collapse; width: 100%; margin: 12px 0 28px 0; font-size: 12px; }
th, td { border: 1px solid #d0d7de; padding: 6px 8px; vertical-align: top; text-align: left; }
th { background: #eef3f8; position: sticky; top: 0; }
.note { padding: 12px; background: #fff8dc; border-left: 4px solid #b8860b; }
.good { padding: 12px; background: #eef8ee; border-left: 4px solid #2e7d32; }
code { background: #f3f4f6; padding: 2px 4px; }
'@

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>MDMWinsOverGP Validation Report</title>
<style>$css</style>
</head>
<body>
<h1>MDMWinsOverGP Validation Report</h1>
<p>Computer: $(ConvertTo-HtmlEncoded $env:COMPUTERNAME)<br>
Generated: $(ConvertTo-HtmlEncoded (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))</p>

<div class="note">
<strong>Interpretation limits:</strong>
Event 881 records PolicyManager operations. It does not prove a GPO conflict or prove which authority won.
Heuristic matches are triage candidates only. Verified mappings and effective-value checks provide stronger evidence.
MDMWinsOverGP does not cover every Windows management CSP.
</div>

<h2>Summary</h2>
$(Convert-ObjectsToHtmlTable -Rows $summaryRows -Properties @('Metric','Value'))

<h2>ControlPolicyConflict state</h2>
$(Convert-ObjectsToHtmlTable -Rows @($ConflictState) -Properties @(
    'RegistryPath','KeyPresent','MDMWinsOverGP',
    'MDMWinsOverGP_ProviderSet','MDMWinsOverGP_WinningProvider','Interpretation'
))

<h2>Verified mapping results</h2>
$(Convert-ObjectsToHtmlTable -Rows $VerifiedRows -Properties @(
    'GpoSetting','GpoName','GpoState','CspArea','CspPolicy',
    'MdmEffectiveValue','WinningProvider','Status','Notes'
) -EmptyMessage 'No mapping CSV was supplied, or no mapping rows were found.')

<h2>Heuristic overlap candidates</h2>
$(Convert-ObjectsToHtmlTable -Rows ($HeuristicRows | Select-Object -First 250) -Properties @(
    'Confidence','GpoSetting','GpoName','GpoState','CspArea','CspPolicy',
    'MdmEffectiveValue','WinningProvider','Status'
))

<h2>Recent warnings and errors</h2>
$(Convert-ObjectsToHtmlTable -Rows ($eventErrors | Select-Object -First 250) -Properties @(
    'TimeCreated','LogName','Id','Level','Message'
))

<h2>Event log configuration</h2>
$(Convert-ObjectsToHtmlTable -Rows $LogConfiguration -Properties @(
    'LogName','IsEnabled','RecordCount','MaximumSizeMB','LogMode'
))

<h2>Recommended review sequence</h2>
<ol>
<li>Review verified overlaps first.</li>
<li>Confirm each mapped setting belongs to Policy CSP and supports the device's Windows edition and version.</li>
<li>Compare the expected Intune value with the effective PolicyManager value.</li>
<li>Review the related GPResult entry and winning GPO.</li>
<li>Test the actual Windows behavior.</li>
<li>Use Debug and Admin events to explain timing or application failures, not as sole proof of precedence.</li>
<li>Move confirmed settings out of GPO targeting when the migration permits it.</li>
</ol>
</body>
</html>
"@

    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated Windows PowerShell or PowerShell session.'
}

# Validate optional input up front so a bad path fails fast, before we spend
# time collecting evidence that would be discarded when the import later throws.
if (-not [string]::IsNullOrWhiteSpace($MappingCsv) -and -not (Test-Path -LiteralPath $MappingCsv)) {
    throw "Mapping CSV not found: $MappingCsv"
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputFolder = Join-Path $OutputRoot "$env:COMPUTERNAME-$timestamp"
$folders = @{
    Root       = $outputFolder
    GPResult   = Join-Path $outputFolder 'GPResult'
    MDM        = Join-Path $outputFolder 'MDMDiagnostics'
    Events     = Join-Path $outputFolder 'Events'
    Registry   = Join-Path $outputFolder 'Registry'
    Reports    = Join-Path $outputFolder 'Reports'
}

foreach ($folder in $folders.Values) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
}

$transcriptPath = Join-Path $folders.Root 'Transcript.txt'
$transcriptStarted = $false
try {
    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    $transcriptStarted = $true
}
catch {
    Write-Warning "Could not start a transcript. Continuing without one. $($_.Exception.Message)"
}

$debugWasEnabled = $false
$debugEnabledByThisRun = $false
$collectionSucceeded = $false
$collectionError = $null

try {
    Write-Host "Collecting MDMWinsOverGP validation evidence from $env:COMPUTERNAME"

    $initialLogs = @(Get-DmLogConfiguration)
    $debugConfig = $initialLogs |
        Where-Object LogName -eq 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Debug' |
        Select-Object -First 1

    if ($debugConfig) {
        $debugWasEnabled = [bool]$debugConfig.IsEnabled
    }

    if ($EnableDebugLog -and -not $debugWasEnabled) {
        Write-Host 'Enabling DeviceManagement Debug log...'
        Set-DmDebugLogState -Enabled $true
        $debugEnabledByThisRun = $true
    }

    if ($RunGpUpdate) {
        Write-Host 'Running gpupdate /force...'
        & "$env:SystemRoot\System32\gpupdate.exe" /force 2>&1 |
            Tee-Object -FilePath (Join-Path $folders.GPResult 'GPUpdate.txt')
    }

    Write-Host 'Collecting GPResult...'
    $gpFiles = Invoke-GpResultCollection -Folder $folders.GPResult
    $gpoRows = @(Get-GpResultPolicyRows -XmlPath $gpFiles.XmlPath)
    $gpoRows | Export-Csv -LiteralPath (Join-Path $folders.Reports 'GPO-Settings.csv') -NoTypeInformation -Encoding UTF8

    Write-Host 'Reading PolicyManager effective stores...'
    $mdmRegistryRows = @()
    $mdmRegistryRows += Get-RegistryTreeValues `
        -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device' `
        -Source MDM -Scope Device

    if (Test-Path 'Registry::HKEY_USERS') {
        foreach ($sidKey in Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
                 Where-Object { $_.PSChildName -match '^S-1-5-21-' }) {

            $userPath = "Registry::$($sidKey.Name)\SOFTWARE\Microsoft\PolicyManager\current\user"
            $mdmRegistryRows += Get-RegistryTreeValues -Path $userPath -Source MDM -Scope "User:$($sidKey.PSChildName)"
        }
    }

    $mdmRegistryRows | Export-Csv `
        -LiteralPath (Join-Path $folders.Registry 'PolicyManager-AllValues.csv') `
        -NoTypeInformation -Encoding UTF8

    $mdmRows = @(Get-MdmPolicyRows -RegistryRows $mdmRegistryRows)
    $mdmRows |
        Select-Object Scope,Area,Policy,ValueName,EffectiveValue,RegistryPath,ProviderSet,WinningProvider |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'MDM-EffectivePolicies.csv') `
        -NoTypeInformation -Encoding UTF8

    Write-Host 'Exporting classic registry policy trees...'
    $gpoRegistryRows = @()
    $gpoRegistryRows += Get-RegistryTreeValues `
        -Path 'HKLM:\SOFTWARE\Policies' -Source GPORegistry -Scope Device
    $gpoRegistryRows += Get-RegistryTreeValues `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies' `
        -Source GPORegistry -Scope Device
    $gpoRegistryRows |
        Export-Csv -LiteralPath (Join-Path $folders.Registry 'ClassicPolicyRegistry.csv') `
        -NoTypeInformation -Encoding UTF8

    Write-Host 'Reading MDMWinsOverGP state...'
    $conflictState = Get-ControlPolicyConflictState
    $conflictState |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'MDMWinsOverGP-State.csv') `
        -NoTypeInformation -Encoding UTF8

    if (-not $SkipMdmDiagnostics) {
        Write-Host 'Running MdmDiagnosticsTool.exe...'
        $mdmTool = Join-Path $env:SystemRoot 'System32\MdmDiagnosticsTool.exe'
        if (Test-Path -LiteralPath $mdmTool) {
            & $mdmTool -out $folders.MDM 2>&1 |
                Out-File -LiteralPath (Join-Path $folders.MDM 'MdmDiagnosticsTool-command.txt') -Encoding UTF8
        }
        else {
            Write-Warning 'MdmDiagnosticsTool.exe was not found.'
        }
    }

    Write-Host 'Exporting DeviceManagement event logs...'
    $startTime = (Get-Date).AddHours(-$SinceHours)
    $dmEvidence = Export-DmEvents -Folder $folders.Events -StartTime $startTime
    $dmEvidence.Configuration |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'EventLog-Configuration.csv') `
        -NoTypeInformation -Encoding UTF8
    $dmEvidence.Events |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'DeviceManagement-Events.csv') `
        -NoTypeInformation -Encoding UTF8

    $dmEvidence.Events |
        Where-Object Id -eq 881 |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'Event-881.csv') `
        -NoTypeInformation -Encoding UTF8

    $mappings = @(Import-VerifiedMappings -Path $MappingCsv)
    $verifiedRows = @(Get-VerifiedOverlapRows -Mappings $mappings -GpoRows $gpoRows -MdmRows $mdmRows)
    $heuristicRows = @(Get-HeuristicOverlapRows -GpoRows $gpoRows -MdmRows $mdmRows)

    $verifiedRows |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'Verified-Overlap-Results.csv') `
        -NoTypeInformation -Encoding UTF8
    $heuristicRows |
        Export-Csv -LiteralPath (Join-Path $folders.Reports 'Heuristic-Overlap-Candidates.csv') `
        -NoTypeInformation -Encoding UTF8

    $templatePath = Join-Path $folders.Reports 'PolicyMappings-Template.csv'
    @(
        [pscustomobject]@{
            GpoSetting = 'Example GPO setting display name'
            GpoName    = 'Optional winning GPO name'
            CspArea    = 'ExampleArea'
            CspPolicy  = 'ExamplePolicy'
            OmaUri     = './Device/Vendor/MSFT/Policy/Config/ExampleArea/ExamplePolicy'
            Notes      = 'Replace this row with a mapping verified against Microsoft documentation.'
        }
    ) | Export-Csv -LiteralPath $templatePath -NoTypeInformation -Encoding UTF8

    $reportPath = Join-Path $folders.Reports 'MDMWinsOverGP-Validation.html'
    New-HtmlReport `
        -Path $reportPath `
        -ConflictState $conflictState `
        -LogConfiguration $dmEvidence.Configuration `
        -Events $dmEvidence.Events `
        -GpoRows $gpoRows `
        -MdmRows $mdmRows `
        -VerifiedRows $verifiedRows `
        -HeuristicRows $heuristicRows `
        -EvidenceFolder $folders.Root

    $manifest = [ordered]@{
        ComputerName        = $env:COMPUTERNAME
        Generated           = (Get-Date).ToString('o')
        WindowsVersion      = [Environment]::OSVersion.VersionString
        PowerShellVersion   = $PSVersionTable.PSVersion.ToString()
        SinceHours          = $SinceHours
        MappingCsv          = $MappingCsv
        DebugWasEnabled     = $debugWasEnabled
        DebugEnabledByRun   = $debugEnabledByThisRun
        OutputFolder        = $folders.Root
        HtmlReport          = $reportPath
        CollectionSucceeded = $true
        CollectionError     = $null
    }

    $manifest | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $folders.Root 'Manifest.json') -Encoding UTF8

    # Mark success only after every collection step and the report/manifest are
    # written, so the ZIP naming below can distinguish a complete package from a
    # partial one salvaged after a failure.
    $collectionSucceeded = $true

    Write-Host ''
    Write-Host 'Collection completed.'
    Write-Host "HTML report: $reportPath"
}
catch {
    # Preserve the failure for the manifest/marker below, then re-throw so the
    # run still surfaces the error to the caller exactly as before.
    $collectionError = $_
    throw
}
finally {
    if ($DisableDebugLogAfterCollection -and $debugEnabledByThisRun) {
        try {
            Write-Host 'Disabling DeviceManagement Debug log...'
            Set-DmDebugLogState -Enabled $false
        }
        catch {
            Write-Warning "Could not disable the Debug log. $($_.Exception.Message)"
        }
    }

    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }

    # When the run failed, drop a marker into the folder so the salvaged evidence
    # is self-describing rather than relying on the file name alone.
    if (-not $collectionSucceeded -and (Test-Path -LiteralPath $outputFolder)) {
        $errorText = if ($collectionError) { $collectionError.Exception.Message } else { 'Collection did not complete.' }
        try {
            @(
                'COLLECTION INCOMPLETE'
                "Timestamp: $((Get-Date).ToString('o'))"
                "Error: $errorText"
                'This package was salvaged after a failure and may be missing evidence.'
            ) | Set-Content -LiteralPath (Join-Path $outputFolder 'COLLECTION-INCOMPLETE.txt') -Encoding UTF8
        }
        catch { }
    }

    # Package whatever evidence was collected. This runs after the transcript is
    # stopped so the transcript file is flushed and unlocked before it is zipped,
    # and it runs even on failure so a partial collection is still preserved.
    # Partial packages get a distinct name so an incomplete collection is never
    # mistaken for a successful one. A ZIP failure must not mask the underlying
    # result, so it is non-fatal.
    if (Test-Path -LiteralPath $outputFolder) {
        $zipSuffix = if ($collectionSucceeded) { '' } else { '-PARTIAL' }
        $zipPath = "$outputFolder$zipSuffix.zip"
        try {
            Compress-Archive -Path (Join-Path $outputFolder '*') -DestinationPath $zipPath -Force
            if ($collectionSucceeded) {
                Write-Host "Evidence ZIP: $zipPath"
            }
            else {
                Write-Warning "Collection did not complete. Partial evidence ZIP: $zipPath"
            }
        }
        catch {
            Write-Warning "Could not create evidence ZIP. The evidence folder is still available at $outputFolder. $($_.Exception.Message)"
        }
    }
}
