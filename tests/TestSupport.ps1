<#
TestSupport.ps1

Test INFRASTRUCTURE for the Pester suite in this folder. Dot-sourced by the
*.Tests.ps1 files:

    . "$PSScriptRoot/TestSupport.ps1"

THE ONE RULE FOR THIS FILE
--------------------------
Nothing here may reimplement production logic. This file predates a rewrite
(Issue #14): its ancestor, TestHelpers.ps1, contained private copies of 21 of
the 27 functions in scripts/Backup-IntunePolicies.ps1, so the suite exercised
the copies and never the shipped code. Four real bugs (docs/REVIEW-PHASE0.md
R-02..R-05) were therefore invisible to a "passing" suite, and the copies had
silently drifted from the originals.

So this file provides only three kinds of thing:

  1. A loader that pulls the REAL function text out of a production .ps1 and
     defines it in the caller's scope (Import-ProductionFunction).
  2. An offline fake for Microsoft Graph, so a whole script can be run
     end to end with no tenant (Enable-FakeGraph and friends).
  3. Fixture builders and temp-folder plumbing.

SuiteIntegrity.Tests.ps1 enforces rule 1 mechanically: it fails if any file
under tests/ defines a function name that also exists in scripts/.

WHY LOADING BY AST AND NOT DOT-SOURCING THE SCRIPT
--------------------------------------------------
Every script in scripts/ is a monolith: parameters, functions, then a main
body that connects to Graph and does work. Dot-sourcing one to get at its
functions would also run that main body. Parsing the file and re-declaring
just its function definitions gives the real, byte-identical function bodies
with none of the side effects, and needs no test hook in production code.

When Issue #15 moves this logic into Continuum.* modules, Import-ProductionFunction
is replaced by Import-Module and the tests themselves should not need to change.

NOTE ON StrictMode: this file deliberately does NOT set it. The five scripts
in scripts/ run with no StrictMode at all (docs/REVIEW-PHASE0.md R-01), and a
test harness that ran their code under stricter rules than production would
report failures that cannot happen in the field - which is exactly the trap
TestHelpers.ps1 fell into. Each test file states the mode it wants explicitly.
#>

# ---------------------------------------------------------------------------
# Locating production code
# ---------------------------------------------------------------------------

function Get-ProductionScriptPath {
    <# Absolute path to a script in scripts/, throwing if it has moved. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $path     = Join-Path (Join-Path $repoRoot 'scripts') $Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Production script not found: '$path'. Has it been renamed or moved out of scripts/?"
    }
    return $path
}

function Get-ToolkitScriptPath {
    <# Absolute path to a script in MDMWinsOverGPToolKit/, throwing if it has moved. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $path     = Join-Path (Join-Path $repoRoot 'MDMWinsOverGPToolKit') $Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Toolkit script not found: '$path'. Has it been renamed or moved out of MDMWinsOverGPToolKit/?"
    }
    return $path
}

function Get-ScriptFunctionDefinition {
    <#
        FunctionDefinitionAst nodes in a .ps1 file.

        By default only top-level ones: FindAll's $false argument means "do not
        descend into nested script blocks", so helpers declared *inside* another
        function (ConvertTo-FlatSettings declares Emit and Walk) are not
        returned separately - they come along inside their parent's text, which
        is what the loader wants.

        -IncludeNested descends everywhere. That is what the reimplementation
        guard in SuiteIntegrity.Tests.ps1 needs, because a copy of production
        code hidden inside a Pester BeforeAll block is nested, and a guard that
        could not see it would miss the very thing it exists to catch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Name,
        [switch]$IncludeNested
    )

    $tokens      = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors -and @($parseErrors).Count -gt 0) {
        $detail = (@($parseErrors) | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '
        throw "'$Path' does not parse: $detail"
    }

    $found = @($ast.FindAll(
        { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        [bool]$IncludeNested))

    if ($Name) {
        $wanted    = @($Name)
        $available = @($found | ForEach-Object { $_.Name })
        $missing   = @($wanted | Where-Object { $available -notcontains $_ })
        if ($missing) {
            throw "'$Path' does not define: $($missing -join ', '). It defines: $($available -join ', ')"
        }
        return @($found | Where-Object { $wanted -contains $_.Name })
    }

    return $found
}

function Get-ScriptFunctionName {
    <# Names of the functions a .ps1 defines; -IncludeNested reaches inside
       other functions and inside Pester blocks. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludeNested
    )
    return @(@(Get-ScriptFunctionDefinition -Path $Path -IncludeNested:$IncludeNested) |
            ForEach-Object { $_.Name })
}

function Import-ProductionFunction {
    <#
        Returns a scriptblock containing the verbatim source of the named
        functions. DOT-SOURCE the result so they land in the caller's scope:

            . (Import-ProductionFunction -Path $p -Name 'ConvertTo-FlatSettings')

        The text is copied straight from the file's AST extent, so what runs
        in the test IS what runs in production - no transformation, no
        paraphrase.

        Functions loaded this way still read the script-level state their
        original file sets up (the $DefinitionCache / $GroupNameCache /
        $FilterNameCache hashtables). Call Initialize-BackupFunctionState to
        provide it.

        LIMIT: a scriptblock built this way has no backing file, so
        $PSScriptRoot is empty inside it. That is harmless today - scripts/ has
        zero occurrences of $PSScriptRoot (docs/PROJECT_STATUS.md known issue
        #7) - but it stops being true the moment path portability is brought
        over during the module extraction. Test such functions through the
        whole-script route instead, or import the Continuum module once #15
        makes that possible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Name
    )

    $defs = @(Get-ScriptFunctionDefinition -Path $Path -Name $Name)
    if ($defs.Count -eq 0) { throw "No function definitions found in '$Path'." }

    $text = (@($defs | ForEach-Object { $_.Extent.Text })) -join "`r`n`r`n"
    return [scriptblock]::Create($text)
}

# ---------------------------------------------------------------------------
# Script-level state the extracted functions expect
# ---------------------------------------------------------------------------

function Initialize-BackupFunctionState {
    <#
        Recreates the three caches that Backup-IntunePolicies.ps1 (and
        Import-PolicyHistoryToDatabase.ps1, for $DefinitionCache) declare at
        file scope. This is fixture setup - three empty hashtables - not a
        reimplementation. If it ever grows behaviour, that behaviour belongs
        in the production script, not here.

        GLOBAL SCOPE IS DELIBERATE. The production functions read these by
        unqualified name, so resolution walks the scope chain from wherever
        Pester happens to invoke the test body. Global is the only scope
        guaranteed to be on every chain. The production code only ever does
        indexed assignment ($DefinitionCache[$id] = ...), never whole-variable
        assignment, so it mutates these rather than shadowing them.
    #>
    [CmdletBinding()]
    param()

    $global:DefinitionCache = @{}
    $global:GroupNameCache  = @{}
    $global:FilterNameCache = @{}
}

function Clear-BackupFunctionState {
    [CmdletBinding()]
    param()
    Remove-Variable -Name DefinitionCache, GroupNameCache, FilterNameCache `
        -Scope Global -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Offline fake for Microsoft Graph
# ---------------------------------------------------------------------------

function Enable-FakeGraph {
    <#
        Installs offline stand-ins for Get-MgContext, Connect-MgGraph and
        Invoke-MgGraphRequest so a production script can be run end to end
        with no tenant, no credentials and no network.

        Calling it again resets the routing table and the call log, which is
        how a test drives two consecutive runs with different tenant state.

        The stubs are defined at GLOBAL scope on purpose: the script under
        test is invoked with & from inside a Pester It block, so it gets its
        own scope, and a stub defined anywhere narrower might not be on its
        lookup chain. Functions take precedence over cmdlets in PowerShell's
        command resolution, so these win even if the real
        Microsoft.Graph.Authentication module happens to be imported.

        Returns hashtables, matching the real Invoke-MgGraphRequest, whose
        default -OutputType is HashTable.
    #>
    [CmdletBinding()]
    param(
        # Start with no Graph connection, so the script under test exercises
        # its own Connect-MgGraph branch.
        [switch]$Disconnected
    )

    $global:CtmGraphRoutes = New-Object System.Collections.ArrayList
    $global:CtmGraphCalls  = New-Object System.Collections.ArrayList
    $global:CtmGraphContext = if ($Disconnected) { $null } else {
        @{ Account = 'tests@contoso.invalid'; TenantId = '11111111-2222-3333-4444-555555555555' }
    }

    function global:Get-MgContext {
        [CmdletBinding()]
        param()
        return $global:CtmGraphContext
    }

    function global:Connect-MgGraph {
        [CmdletBinding()]
        param([string[]]$Scopes, [string]$TenantId, [string]$ClientId)
        $global:CtmGraphContext = @{
            Account  = 'tests@contoso.invalid'
            TenantId = if ($TenantId) { $TenantId } else { '11111111-2222-3333-4444-555555555555' }
        }
        return $global:CtmGraphContext
    }

    function global:Invoke-MgGraphRequest {
        [CmdletBinding()]
        param(
            [string]$Method = 'GET',
            [Parameter(Mandatory)][string]$Uri,
            $Body,
            [string]$ContentType,
            [string]$OutputType
        )

        [void]$global:CtmGraphCalls.Add([pscustomobject]@{
            Method = $Method
            Uri    = $Uri
            Body   = $Body
        })

        foreach ($route in $global:CtmGraphRoutes) {
            if ($route.Method -ne $Method) { continue }
            if ($Uri -like $route.UriLike) {
                if ($route.ThrowMessage) { throw $route.ThrowMessage }
                return $route.Response
            }
        }

        # An unrouted call is an error, exactly as an unknown Graph resource
        # would be. Several production paths depend on that: Get-SettingDefinition
        # negative-caches the miss and falls back to the raw definition id.
        throw "FakeGraph: no route registered for $Method $Uri"
    }
}

function Disable-FakeGraph {
    [CmdletBinding()]
    param()
    foreach ($name in @('Get-MgContext', 'Connect-MgGraph', 'Invoke-MgGraphRequest')) {
        if (Test-Path -LiteralPath "function:global:$name") {
            Remove-Item -LiteralPath "function:global:$name" -Force
        }
    }
    Remove-Variable -Name CtmGraphRoutes, CtmGraphCalls, CtmGraphContext `
        -Scope Global -ErrorAction SilentlyContinue
}

function Add-FakeGraphRoute {
    <#
        Registers one canned response. Routes are matched in the order they
        were added and the first match wins, so register the specific ones
        first.

        CAUTION ON PATTERNS: matching is -like, where '?' is a single-character
        WILDCARD, not a literal. 'configurationPolicies?*' therefore also
        matches 'configurationPolicies/<id>/assignments'. Write patterns that
        key off an unambiguous fragment instead - the suite uses
        '*configurationPolicies*expand*' for the list call and
        '*configurationPolicies/*/assignments' for the per-policy one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UriLike,
        [string]$Method = 'GET',
        $Response,
        # Make this route fail instead of answering, for throttling/permission
        # error paths.
        [string]$ThrowMessage
    )

    [void]$global:CtmGraphRoutes.Add([pscustomobject]@{
        Method       = $Method
        UriLike      = $UriLike
        Response     = $Response
        ThrowMessage = $ThrowMessage
    })
}

function Get-FakeGraphCall {
    <# Everything the script under test asked Graph for, in order. #>
    [CmdletBinding()]
    param(
        [string]$Method,
        [string]$UriLike = '*'
    )
    return @($global:CtmGraphCalls | Where-Object {
        ((-not $Method) -or ($_.Method -eq $Method)) -and ($_.Uri -like $UriLike)
    })
}

# ---------------------------------------------------------------------------
# Fixture builders (hashtables, matching real Graph output)
# ---------------------------------------------------------------------------

function New-FakePolicy {
    <# A Settings Catalog policy as the configurationPolicies list call returns it. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [string]$Platforms = 'windows10',
        [string]$Technologies = 'mdm',
        # $null and @() are both legitimate here: a Settings Catalog policy
        # with no settings is a normal thing to have (R-03).
        [AllowNull()][AllowEmptyCollection()]$Settings = @(),
        [string]$LastModifiedDateTime = '2026-07-01T10:00:00Z'
    )

    return @{
        id                   = $Id
        name                 = $Name
        description          = "Fixture policy: $Name"
        platforms            = $Platforms
        technologies         = $Technologies
        createdDateTime      = '2026-06-01T09:00:00Z'
        lastModifiedDateTime = $LastModifiedDateTime
        settings             = $Settings
    }
}

function New-FakeSimpleSetting {
    <# One string-valued simple setting, wrapped the way Graph wraps it. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DefinitionId,
        [AllowEmptyString()][string]$Value = 'configured'
    )

    return @{
        '@odata.type'   = '#microsoft.graph.deviceManagementConfigurationSetting'
        settingInstance = @{
            '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
            settingDefinitionId = $DefinitionId
            simpleSettingValue  = @{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'
                value         = $Value
            }
        }
    }
}

function New-FakeAssignment {
    <# One assignment as the per-policy assignments endpoint returns it. #>
    [CmdletBinding()]
    param(
        [string]$GroupId,
        [switch]$Exclude,
        [string]$FilterId,
        [string]$FilterType = 'none'
    )

    $targetType = if ($Exclude) {
        '#microsoft.graph.exclusionGroupAssignmentTarget'
    } else {
        '#microsoft.graph.groupAssignmentTarget'
    }

    return @{
        id     = [guid]::NewGuid().ToString()
        target = @{
            '@odata.type'                              = $targetType
            groupId                                    = $GroupId
            deviceAndAppManagementAssignmentFilterId   = $FilterId
            deviceAndAppManagementAssignmentFilterType = $FilterType
        }
    }
}

# ---------------------------------------------------------------------------
# Temp folders and output inspection
# ---------------------------------------------------------------------------

function New-TestRoot {
    <# A fresh, empty output folder under the system temp directory. #>
    [CmdletBinding()]
    param([string]$Prefix = 'continuum_tests')
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}_{1}" -f $Prefix, [guid]::NewGuid())
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Remove-TestRoot {
    [CmdletBinding()]
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-SnapshotFile {
    <#
        The JSON snapshots a run wrote. Both backup scripts write to
        <OutputPath>\json\<yyyy-MM-dd_HHmmss>\, one folder per run, so this
        searches recursively rather than guessing the timestamp.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutputPath)

    $jsonRoot = Join-Path $OutputPath 'json'
    if (-not (Test-Path -LiteralPath $jsonRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $jsonRoot -Filter '*.json' -File -Recurse)
}
