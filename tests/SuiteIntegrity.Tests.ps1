#requires -Modules Pester

<#
    Guards on the suite itself.

    Issue #14 was not "some tests were missing". It was that the suite had
    quietly stopped testing the product: tests/TestHelpers.ps1 defined 27
    functions, 21 of which were private copies of functions in
    scripts/Backup-IntunePolicies.ps1. The suite exercised the copies, the
    copies drifted, and four real bugs shipped behind a green run
    (docs/REVIEW-PHASE0.md, "Evidence gathered for the next two Phase 0 tasks").

    Rewriting the tests fixes that once. These tests stop it coming back.

    Run:  Invoke-Pester ./tests
#>

# See Backup.Functions.Tests.ps1: scripts/ has no StrictMode (R-01).
Set-StrictMode -Off

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:RepoRoot 'scripts'
    $script:ToolkitDir = Join-Path $script:RepoRoot 'MDMWinsOverGPToolKit'
    $script:ModulesDir = Join-Path $script:RepoRoot 'modules'
    $script:TestsDir   = $PSScriptRoot

    # Every .psm1 under modules/ (Issue #15). Kept as a list so these guards
    # extend to Continuum.PolicyBackup and friends without further edits.
    $script:ModuleFiles = @(
        if (Test-Path -LiteralPath $script:ModulesDir) {
            Get-ChildItem -LiteralPath $script:ModulesDir -Filter '*.psm1' -File -Recurse
        }
    )
}

Describe 'No test file reimplements production code' {

    It 'defines no function name that also exists in scripts/' {
        # The failure message names the offender and its production twin, so
        # the fix is obvious: load the real function with
        # Import-ProductionFunction instead of writing another copy.
        $production = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $script:ScriptsDir -Filter '*.ps1' -File)) {
            foreach ($name in @(Get-ScriptFunctionName -Path $file.FullName)) {
                $production[$name] = $file.Name
            }
        }
        $production.Count | Should -BeGreaterThan 0

        $offenders = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $script:TestsDir -Filter '*.ps1' -File -Recurse)) {
            foreach ($name in @(Get-ScriptFunctionName -Path $file.FullName -IncludeNested)) {
                if ($production.ContainsKey($name)) {
                    $offenders += "$($file.Name) defines '$name', which is production code in $($production[$name])"
                }
            }
        }

        $offenders -join ' ;; ' | Should -BeNullOrEmpty
    }

    It 'defines no function name that also exists in modules/' {
        # Same rule as for scripts/, applied to the code Issue #15 is moving
        # into modules. A test needing one of these calls Import-ContinuumModule.
        $script:ModuleFiles.Count | Should -BeGreaterThan 0

        $production = @{}
        foreach ($file in $script:ModuleFiles) {
            foreach ($name in @(Get-ScriptFunctionName -Path $file.FullName)) {
                $production[$name] = $file.Name
            }
        }
        $production.Count | Should -BeGreaterThan 0

        $offenders = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $script:TestsDir -Filter '*.ps1' -File -Recurse)) {
            foreach ($name in @(Get-ScriptFunctionName -Path $file.FullName -IncludeNested)) {
                if ($production.ContainsKey($name)) {
                    $offenders += "$($file.Name) defines '$name', which is production code in $($production[$name])"
                }
            }
        }

        $offenders -join ' ;; ' | Should -BeNullOrEmpty
    }

    It 'defines no function name that also exists in MDMWinsOverGPToolKit/' {
        $production = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $script:ToolkitDir -Filter '*.ps1' -File)) {
            foreach ($name in @(Get-ScriptFunctionName -Path $file.FullName)) {
                $production[$name] = $file.Name
            }
        }
        $production.Count | Should -BeGreaterThan 0

        $offenders = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $script:TestsDir -Filter '*.ps1' -File -Recurse)) {
            foreach ($name in @(Get-ScriptFunctionName -Path $file.FullName -IncludeNested)) {
                if ($production.ContainsKey($name)) {
                    $offenders += "$($file.Name) defines '$name', which is production code in $($production[$name])"
                }
            }
        }

        $offenders -join ' ;; ' | Should -BeNullOrEmpty
    }
}

Describe 'The harness does not run production code under stricter rules than production' {

    It 'sets no StrictMode version in files testing scripts/, and only -Version 2.0 in files testing the toolkit' {
        # TestHelpers.ps1 was the only file in the repo carrying
        # Set-StrictMode -Version Latest, so its private copies ran under
        # stricter rules than the code they shadowed - a difference that could
        # only ever produce failures impossible in the field, or hide real ones.
        # The five files in scripts/ set no StrictMode at all (R-01), so any
        # test file for scripts/ must not set one either.
        #
        # MDMWinsOverGPToolKit/'s three scripts DO set Set-StrictMode -Version
        # 2.0 (docs/AGENT_ONBOARDING.md's StrictMode table), so a test file
        # exercising toolkit code must match that exactly, by the same logic in
        # the other direction: a harness looser than production would miss the
        # .Count-on-$null class this project has shipped four times. Test
        # files are told apart by a 'Toolkit' prefix on the filename - see
        # tests/Toolkit.PureFunctions.Tests.ps1.
        #
        # WHEN R-11 LANDS and scripts/ adopts Set-StrictMode -Version 2.0, every
        # test file converges on the toolkit rule above and this test collapses
        # to one branch. At that point this suite becomes the instrument that
        # verifies the switch instead of a guard against it.
        $offenders = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $script:TestsDir -Filter '*.ps1' -File -Recurse)) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $setsVersion2 = $text -match '(?m)^\s*Set-StrictMode\s+-Version\s+2\.0\s*$'
            $setsOtherVersion = ($text -match '(?m)^\s*Set-StrictMode\s+-Version') -and -not $setsVersion2

            if ($file.Name -like 'Toolkit.*') {
                if (-not $setsVersion2) {
                    $offenders += "$($file.Name) tests MDMWinsOverGPToolKit/ (Set-StrictMode -Version 2.0) but does not set that exact mode"
                }
            }
            elseif ($setsVersion2 -or $setsOtherVersion) {
                $offenders += "$($file.Name) sets a StrictMode version but tests scripts/, which sets none (R-01)"
            }
        }
        $offenders -join ' ;; ' | Should -BeNullOrEmpty
    }
}

Describe 'No script shadows a function that moved into a module' {

    It 'defines no function in scripts/ that a module also exports' {
        # The failure mode this catches is silent and nasty. A function defined
        # in a .ps1 wins over the module's copy of the same name, so re-adding
        # a "local copy" of, say, Format-AssignmentList would shadow
        # Continuum.Core's without any error - and the two would then drift
        # apart exactly as the three original copies did, with the suite still
        # green because it tests the module.
        #
        # This is the guard that makes the extraction stick, and it is the
        # mechanical form of the rule in Continuum.Core's header: a function
        # lives in one place.
        $script:ModuleFiles.Count | Should -BeGreaterThan 0

        $moduleFunctions = @{}
        foreach ($file in $script:ModuleFiles) {
            foreach ($name in @(Get-ScriptFunctionName -Path $file.FullName)) {
                $moduleFunctions[$name] = $file.Name
            }
        }

        $offenders = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $script:ScriptsDir -Filter '*.ps1' -File)) {
            foreach ($name in @(Get-ScriptFunctionName -Path $file.FullName)) {
                if ($moduleFunctions.ContainsKey($name)) {
                    $offenders += "$($file.Name) defines '$name', which $($moduleFunctions[$name]) already provides - it would shadow the module copy"
                }
            }
        }

        $offenders -join ' ;; ' | Should -BeNullOrEmpty
    }

    It 'has every script that calls a module function actually importing that module' {
        # A script that calls into Continuum.Core without importing it appears
        # to work whenever something else in the same session imported the
        # module first - which is precisely the situation inside this suite,
        # where eight test files share one process. Deleting the Import-Module
        # line from Backup-IntunePolicies.ps1 therefore left every test green.
        # That is what this guard is for, and it is why it looks for a real
        # Import-Module STATEMENT rather than a mention of the module's name:
        # the first version of this test checked for the string 'Continuum.Core'
        # and passed on the broken script, because the path variable and the
        # comments above it still contained the name.
        $moduleFunctions = @()
        foreach ($file in $script:ModuleFiles) {
            $moduleFunctions += @(Get-ScriptFunctionName -Path $file.FullName)
        }
        $moduleFunctions.Count | Should -BeGreaterThan 0

        $offenders = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $script:ScriptsDir -Filter '*.ps1' -File)) {
            $text = Get-Content -LiteralPath $file.FullName -Raw

            # Calls only: a line that is entirely a comment does not count, so
            # the "see Continuum.Core" breadcrumbs left behind by the
            # extraction are not mistaken for uses.
            $used = @($moduleFunctions | Where-Object {
                    $text -match "(?m)^\s*(?!#)[^\r\n]*\b$([regex]::Escape($_))\b"
                })
            $imports = $text -match '(?m)^\s*Import-Module\s+\$ContinuumCorePath\b'

            if ($used.Count -gt 0 -and -not $imports) {
                $offenders += "$($file.Name) calls $($used -join ', ') but has no 'Import-Module `$ContinuumCorePath' statement"
            }
        }

        $offenders -join ' ;; ' | Should -BeNullOrEmpty
    }
}

Describe 'Every production script is covered' {

    It 'names each script in scripts/ from at least one test file' {
        # A crude but effective guard: a script added to scripts/ with no test
        # file mentioning it fails here, rather than quietly joining the
        # untested set.
        $testText = (@(Get-ChildItem -LiteralPath $script:TestsDir -Filter '*.Tests.ps1' -File) |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"

        $uncovered = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $script:ScriptsDir -Filter '*.ps1' -File)) {
            if ($testText -notlike "*$($file.Name)*") { $uncovered += $file.Name }
        }

        $uncovered -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'Every PowerShell file in the repository parses' {

    It 'has no syntax errors in scripts/, modules/, MDMWinsOverGPToolKit/ or tests/' {
        # This is the mechanical half of the brace/paren balance check that
        # docs/REVIEW-PHASE0.md had to do by hand, and it is worth having: the
        # agent sandbox has no PowerShell interpreter, so a syntax error in a
        # desk-checked change is otherwise only found on the user's machine.
        $files = @(
            @(Get-ChildItem -LiteralPath $script:ScriptsDir -Filter '*.ps1' -File) +
            @(Get-ChildItem -LiteralPath $script:ToolkitDir -Filter '*.ps1' -File) +
            @(Get-ChildItem -LiteralPath $script:TestsDir   -Filter '*.ps1' -File -Recurse) +
            @($script:ModuleFiles) +
            @(if (Test-Path -LiteralPath $script:ModulesDir) {
                Get-ChildItem -LiteralPath $script:ModulesDir -Filter '*.psd1' -File -Recurse
            })
        )
        $files.Count | Should -BeGreaterThan 0

        $failures = @()
        foreach ($file in $files) {
            $tokens      = $null
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors -and @($parseErrors).Count -gt 0) {
                $detail = (@($parseErrors) |
                        ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join ' / '
                $failures += "$($file.Name) - $detail"
            }
        }

        $failures -join ' ;; ' | Should -BeNullOrEmpty
    }
}
