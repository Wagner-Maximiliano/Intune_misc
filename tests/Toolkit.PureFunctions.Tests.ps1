#requires -Modules Pester

<#
    Tests for the pure, device-independent helper functions in
    MDMWinsOverGPToolKit/ (known issue #12, item B in docs/PROJECT_STATUS.md).

    The toolkit's ~5,200 lines had zero tests before this file - only the
    parse check in SuiteIntegrity.Tests.ps1 reached it. Most of the toolkit
    needs a live device (registry reads, MDMDiagReport.html parsing on real
    evidence, gpresult.exe), so this file starts with the functions that need
    none of that: pure string/set transforms used by Build-PolicyMappings.ps1's
    Tier B/C matching.

    THESE FUNCTIONS EXIST IN TWO FILES, ON PURPOSE. Both
    Build-PolicyMappings.ps1 and Test-MDMWinsOverGP.ps1 define their own copy
    of Normalize-PolicyName, Get-TokenSet, Get-JaccardScore and
    Convert-ValueToText - each file's comments say "kept local ... so this
    script is meant to be runnable standalone" rather than dot-sourcing the
    other. That is a deliberate design choice (unlike the scripts/ copies
    Issue #14 collapsed), so this file tests BOTH copies and adds parity
    checks between them - the same shape ImportDatabase.Functions.Tests.ps1
    uses for ConvertTo-FlatSettings / Get-PolicyContentHash: each copy is
    dot-sourced inside its own `& { }` so the two same-named copies never
    collide in this file's scope.

    Run:  Invoke-Pester ./tests
#>

# MDMWinsOverGPToolKit/ sets Set-StrictMode -Version 2.0 in all three of its
# scripts (docs/AGENT_ONBOARDING.md's StrictMode table) - unlike scripts/,
# which sets none (R-01). A harness looser than the code it tests could miss
# exactly the .Count-on-$null class this project has shipped four times, so
# this file matches production instead of copying the -Off line the scripts/
# test files use. See SuiteIntegrity.Tests.ps1 for the guard that enforces
# this per file.
Set-StrictMode -Version 2.0

# Pester 6 rejects a BeforeEach/AfterEach directly in the file root ("Each
# test setup is not supported in root") - only BeforeAll/AfterAll are allowed
# there. Wrapping the whole file in one outer Describe is a no-op for every
# Describe already nested inside it, and keeps the file running unmodified
# under Pester 5. See tests/README.md "Pester version".
Describe 'MDMWinsOverGPToolKit pure helper functions' {

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"

    $script:MappingsPath = Get-ToolkitScriptPath -Name 'Build-PolicyMappings.ps1'
    $script:TestMdmPath  = Get-ToolkitScriptPath -Name 'Test-MDMWinsOverGP.ps1'

    function Invoke-NormalizePolicyName {
        param([Parameter(Mandatory)][string]$ScriptPath, [string]$Text)
        & { . (Import-ProductionFunction -Path $ScriptPath -Name 'Normalize-PolicyName'); Normalize-PolicyName -Text $Text }
    }

    function Invoke-GetTokenSet {
        param([Parameter(Mandatory)][string]$ScriptPath, [string]$Text)
        & { . (Import-ProductionFunction -Path $ScriptPath -Name 'Get-TokenSet'); @(Get-TokenSet -Text $Text) }
    }

    function Invoke-GetJaccardScore {
        param([Parameter(Mandatory)][string]$ScriptPath, [string[]]$Left, [string[]]$Right)
        & { . (Import-ProductionFunction -Path $ScriptPath -Name 'Get-JaccardScore'); Get-JaccardScore -Left $Left -Right $Right }
    }

    function Invoke-ConvertValueToText {
        param([Parameter(Mandatory)][string]$ScriptPath, $Value)
        & { . (Import-ProductionFunction -Path $ScriptPath -Name 'Convert-ValueToText'); Convert-ValueToText -Value $Value }
    }
}

    Describe 'Normalize-PolicyName (Build-PolicyMappings.ps1)' {

        It 'returns an empty string for $null or whitespace' {
            Invoke-NormalizePolicyName -ScriptPath $script:MappingsPath -Text $null | Should -Be ''
            Invoke-NormalizePolicyName -ScriptPath $script:MappingsPath -Text '   ' | Should -Be ''
        }

        It 'lowercases and strips non-alphanumeric characters' {
            Invoke-NormalizePolicyName -ScriptPath $script:MappingsPath -Text 'Diagnostic Data Collection!' |
                Should -Be 'diagnosticdatacollection'
        }

        It 'strips a leading verb prefix (allow/enable/disable/configure/turnon/turnoff)' {
            Invoke-NormalizePolicyName -ScriptPath $script:MappingsPath -Text 'Allow Diagnostic Data' | Should -Be 'diagnosticdata'
            Invoke-NormalizePolicyName -ScriptPath $script:MappingsPath -Text 'EnableAutoUpdate' | Should -Be 'autoupdate'
            Invoke-NormalizePolicyName -ScriptPath $script:MappingsPath -Text 'Disable Camera' | Should -Be 'camera'
            Invoke-NormalizePolicyName -ScriptPath $script:MappingsPath -Text 'Configure Update' | Should -Be 'update'
            Invoke-NormalizePolicyName -ScriptPath $script:MappingsPath -Text 'TurnOnFirewall' | Should -Be 'firewall'
            Invoke-NormalizePolicyName -ScriptPath $script:MappingsPath -Text 'TurnOffTelemetry' | Should -Be 'telemetry'
        }

        It 'only strips the prefix when it is leading, not mid-string' {
            # "Do Not Allow ..." does not start with a listed verb, so nothing
            # is stripped from the front - only the anchored ^ match applies.
            Invoke-NormalizePolicyName -ScriptPath $script:MappingsPath -Text 'Do Not Allow Telemetry' |
                Should -Be 'donotallowtelemetry'
        }
    }

    Describe 'Get-TokenSet (Build-PolicyMappings.ps1)' {

        # @(...) at every call site is deliberate, not decoration: Get-TokenSet
        # can return zero, one, or many strings, and PowerShell collapses a
        # zero-count pipeline result to $null and a one-count result to a bare
        # scalar unless the caller forces array context. See
        # AGENT_ONBOARDING.md's "return $list" trap - the same collapse, just
        # triggered by pipeline unrolling through the `& { }` wrapper instead
        # of a List[object]. Comparing via -join keeps each assertion a plain
        # string equality, which sidesteps Pester's array-vs-scalar handling
        # entirely rather than relying on it.

        It 'returns an empty array for $null or whitespace' {
            @(Invoke-GetTokenSet -ScriptPath $script:MappingsPath -Text $null).Count | Should -Be 0
            @(Invoke-GetTokenSet -ScriptPath $script:MappingsPath -Text '  ').Count | Should -Be 0
        }

        It 'splits camelCase boundaries before lowercasing' {
            (@(Invoke-GetTokenSet -ScriptPath $script:MappingsPath -Text 'AllowTelemetry') -join ',') |
                Should -Be 'allow,telemetry'
        }

        It 'drops tokens of length 2 or less' {
            (@(Invoke-GetTokenSet -ScriptPath $script:MappingsPath -Text 'Do It Now') -join ',') | Should -Be 'now'
        }

        It 'drops stoplisted words even when long enough to otherwise qualify' {
            @(Invoke-GetTokenSet -ScriptPath $script:MappingsPath -Text 'Configure Windows Policy Setting').Count |
                Should -Be 0
        }

        It 'splits on the full delimiter set and sorts unique' {
            (@(Invoke-GetTokenSet -ScriptPath $script:MappingsPath -Text 'Zebra_Alpha/Alpha.Beta:Gamma(Delta)[Zebra]-Echo') -join ',') |
                Should -Be 'alpha,beta,delta,echo,gamma,zebra'
        }
    }

    Describe 'Get-JaccardScore (Build-PolicyMappings.ps1)' {

        It 'returns 0 when either side is $null' {
            Invoke-GetJaccardScore -ScriptPath $script:MappingsPath -Left $null -Right @('a') | Should -Be 0
            Invoke-GetJaccardScore -ScriptPath $script:MappingsPath -Left @('a') -Right $null | Should -Be 0
        }

        It 'returns 0 when either side is an empty array' {
            Invoke-GetJaccardScore -ScriptPath $script:MappingsPath -Left @() -Right @('a') | Should -Be 0
        }

        It 'returns 1 for identical sets' {
            Invoke-GetJaccardScore -ScriptPath $script:MappingsPath -Left @('a', 'b') -Right @('b', 'a') | Should -Be 1
        }

        It 'computes intersection-over-union, rounded to 3 decimals' {
            Invoke-GetJaccardScore -ScriptPath $script:MappingsPath -Left @('a', 'b', 'c') -Right @('b', 'c', 'd') |
                Should -Be 0.5
            Invoke-GetJaccardScore -ScriptPath $script:MappingsPath -Left @('a', 'b', 'c') -Right @('b', 'c', 'd', 'e', 'f') |
                Should -Be 0.333
        }
    }

    Describe 'Convert-ValueToText (Build-PolicyMappings.ps1)' {

        It 'returns an empty string for $null' {
            Invoke-ConvertValueToText -ScriptPath $script:MappingsPath -Value $null | Should -Be ''
        }

        It 'formats a byte array as hyphenated hex' {
            Invoke-ConvertValueToText -ScriptPath $script:MappingsPath -Value ([byte[]](1, 2, 255)) | Should -Be '01-02-FF'
        }

        It 'joins a non-byte array with "; "' {
            Invoke-ConvertValueToText -ScriptPath $script:MappingsPath -Value @('one', 'two', 3) | Should -Be 'one; two; 3'
        }

        It 'stringifies a scalar unchanged' {
            Invoke-ConvertValueToText -ScriptPath $script:MappingsPath -Value 'plain' | Should -Be 'plain'
            Invoke-ConvertValueToText -ScriptPath $script:MappingsPath -Value 7 | Should -Be '7'
        }
    }

    Describe 'Parity between the Build-PolicyMappings.ps1 and Test-MDMWinsOverGP.ps1 copies' {

        # Both scripts deliberately keep their own copy of these four functions
        # rather than dot-sourcing one another (see the file header above). That
        # is fine as a design choice, but nothing else stops the two copies
        # silently drifting apart the way the scripts/ copies did before Issue
        # #14 - these checks are what makes "same helper" true rather than
        # aspirational.

        It 'Normalize-PolicyName agrees on a representative set of names' {
            foreach ($name in @('Allow Diagnostic Data', 'TurnOffTelemetry', 'Some Random Policy', '', $null)) {
                Invoke-NormalizePolicyName -ScriptPath $script:MappingsPath -Text $name |
                    Should -Be (Invoke-NormalizePolicyName -ScriptPath $script:TestMdmPath -Text $name)
            }
        }

        It 'Get-TokenSet agrees on a representative set of names' {
            foreach ($name in @('AllowTelemetry', 'Do It Now', 'Configure Windows Policy Setting', '', $null)) {
                $fromMappings = @(Invoke-GetTokenSet -ScriptPath $script:MappingsPath -Text $name) -join ','
                $fromTestMdm  = @(Invoke-GetTokenSet -ScriptPath $script:TestMdmPath -Text $name) -join ','
                $fromMappings | Should -Be $fromTestMdm
            }
        }

        It 'Get-JaccardScore agrees on representative token sets' {
            Invoke-GetJaccardScore -ScriptPath $script:MappingsPath -Left @('a', 'b', 'c') -Right @('b', 'c', 'd') |
                Should -Be (Invoke-GetJaccardScore -ScriptPath $script:TestMdmPath -Left @('a', 'b', 'c') -Right @('b', 'c', 'd'))
            Invoke-GetJaccardScore -ScriptPath $script:MappingsPath -Left $null -Right @('a') |
                Should -Be (Invoke-GetJaccardScore -ScriptPath $script:TestMdmPath -Left $null -Right @('a'))
        }

        It 'Convert-ValueToText agrees on representative values' {
            Invoke-ConvertValueToText -ScriptPath $script:MappingsPath -Value $null |
                Should -Be (Invoke-ConvertValueToText -ScriptPath $script:TestMdmPath -Value $null)
            Invoke-ConvertValueToText -ScriptPath $script:MappingsPath -Value ([byte[]](1, 2, 255)) |
                Should -Be (Invoke-ConvertValueToText -ScriptPath $script:TestMdmPath -Value ([byte[]](1, 2, 255)))
            Invoke-ConvertValueToText -ScriptPath $script:MappingsPath -Value @('one', 'two', 3) |
                Should -Be (Invoke-ConvertValueToText -ScriptPath $script:TestMdmPath -Value @('one', 'two', 3))
        }
    }
}
