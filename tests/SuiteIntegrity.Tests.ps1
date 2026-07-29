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
    $script:TestsDir   = $PSScriptRoot
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

    It 'has no syntax errors in scripts/, MDMWinsOverGPToolKit/ or tests/' {
        # This is the mechanical half of the brace/paren balance check that
        # docs/REVIEW-PHASE0.md had to do by hand, and it is worth having: the
        # agent sandbox has no PowerShell interpreter, so a syntax error in a
        # desk-checked change is otherwise only found on the user's machine.
        $files = @(
            @(Get-ChildItem -LiteralPath $script:ScriptsDir -Filter '*.ps1' -File) +
            @(Get-ChildItem -LiteralPath $script:ToolkitDir -Filter '*.ps1' -File) +
            @(Get-ChildItem -LiteralPath $script:TestsDir   -Filter '*.ps1' -File -Recurse)
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
