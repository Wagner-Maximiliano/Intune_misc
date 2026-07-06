#requires -Modules Pester
<#
    Offline unit tests for the highest-risk logic in IntuneBackup.Common.ps1:
    settings flattening, content hashing, and version-sheet naming. These do
    not need a tenant or any modules beyond Pester.

    Run:  Invoke-Pester ./tests
#>

BeforeAll {
    . "$PSScriptRoot/../scripts/IntuneBackup.Common.ps1"

    # Isolate caches/paths in a temp folder.
    $script:TmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ("intunebackup_tests_" + [guid]::NewGuid())
    Initialize-IntuneBackup -OutputPath $script:TmpOut

    # Force offline: Get-SettingDefinition's fetch fallback must fail cleanly so
    # unseeded definitions resolve to their raw ids.
    function Invoke-MgGraphRequest { throw 'offline test - no Graph' }

    # Plain ConvertFrom-Json (pscustomobject) so the suite runs on both Windows
    # PowerShell 5.1 and PowerShell 7. The code accesses everything through
    # Get-Prop, so object vs. hashtable does not matter.
    $script:Settings = Get-Content "$PSScriptRoot/fixtures/policy-mixed.json" -Raw | ConvertFrom-Json
}

AfterAll {
    if ($script:TmpOut -and (Test-Path $script:TmpOut)) { Remove-Item $script:TmpOut -Recurse -Force }
}

Describe 'ConvertTo-FlatSettings' {

    BeforeAll {
        $script:Flat = ConvertTo-FlatSettings -Settings $script:Settings
    }

    It 'emits one row per leaf/choice value (6 total)' {
        $script:Flat.Count | Should -Be 6
    }

    It 'flattens a simple string setting' {
        $row = $script:Flat | Where-Object Path -eq 'def_simple_string'
        $row.Value | Should -Be 'hello'
    }

    It 'nests choice children under the parent path' {
        $row = $script:Flat | Where-Object Path -eq 'def_choice \ def_choice_child'
        $row | Should -Not -BeNullOrEmpty
        $row.RawValue | Should -Be '42'
    }

    It 'expands a simple setting collection into one row per value' {
        $rows = $script:Flat | Where-Object Path -eq 'def_simple_coll'
        $rows.Count | Should -Be 2
        ($rows.RawValue | Sort-Object) -join ',' | Should -Be 'a,b'
    }

    It 'walks group setting collection children' {
        $row = $script:Flat | Where-Object Path -eq 'def_group \ def_group_child'
        $row.Value | Should -Be 'x'
    }

    It 'falls back to the raw definition id when no definition is cached' {
        $row = $script:Flat | Where-Object Path -eq 'def_simple_string'
        $row.Title | Should -Be 'def_simple_string'
    }

    It 'resolves friendly title and choice value when the definition is cached' {
        Add-SettingDefinitionToCache -Definition @{
            id          = 'def_choice'
            displayName = 'My Choice Setting'
            options     = @(@{ itemId = 'def_choice_1'; name = 'Enabled' })
        }
        $flat = ConvertTo-FlatSettings -Settings $script:Settings
        $row  = $flat | Where-Object Path -eq 'def_choice'
        $row.Title | Should -Be 'My Choice Setting'
        $row.Value | Should -Be 'Enabled'
        $row.RawValue | Should -Be 'def_choice_1'
    }
}

Describe 'Get-PolicyContentHash' {

    BeforeAll {
        $script:Flat = ConvertTo-FlatSettings -Settings $script:Settings
        $script:Assign = @([pscustomobject]@{ AssignmentType = 'groupAssignmentTarget'; GroupId = 'g1'; FilterId = $null; FilterType = 'none' })
    }

    It 'is stable for identical input' {
        $h1 = Get-PolicyContentHash -FlatSettings $script:Flat -Assignments $script:Assign
        $h2 = Get-PolicyContentHash -FlatSettings $script:Flat -Assignments $script:Assign
        $h1 | Should -Be $h2
    }

    It 'is independent of settings order' {
        $reordered = $script:Flat | Sort-Object { $_.RawValue }
        (Get-PolicyContentHash -FlatSettings $script:Flat -Assignments $script:Assign) |
            Should -Be (Get-PolicyContentHash -FlatSettings $reordered -Assignments $script:Assign)
    }

    It 'changes when a value changes' {
        $mutated = $script:Flat | ForEach-Object {
            [pscustomobject]@{ Path = $_.Path; Title = $_.Title; Value = $_.Value; RawValue = ($_.RawValue + '_x') }
        }
        (Get-PolicyContentHash -FlatSettings $script:Flat -Assignments $script:Assign) |
            Should -Not -Be (Get-PolicyContentHash -FlatSettings $mutated -Assignments $script:Assign)
    }

    It 'changes when an assignment changes' {
        $other = @([pscustomobject]@{ AssignmentType = 'groupAssignmentTarget'; GroupId = 'g2'; FilterId = $null; FilterType = 'none' })
        (Get-PolicyContentHash -FlatSettings $script:Flat -Assignments $script:Assign) |
            Should -Not -Be (Get-PolicyContentHash -FlatSettings $script:Flat -Assignments $other)
    }
}

Describe 'Get-VersionSheetName' {

    It 'uses the plain date when free' {
        Get-VersionSheetName -Date ([datetime]'2026-08-20') -ExistingNames @() | Should -Be '2026-08-20'
    }

    It 'suffixes on same-day collision' {
        Get-VersionSheetName -Date ([datetime]'2026-08-20') -ExistingNames @('2026-08-20') | Should -Be '2026-08-20_2'
    }

    It 'finds the next free suffix' {
        Get-VersionSheetName -Date ([datetime]'2026-08-20') -ExistingNames @('2026-08-20', '2026-08-20_2') |
            Should -Be '2026-08-20_3'
    }
}

Describe 'Manifest round-trip' {

    It 'writes and reads back a manifest entry' {
        $m = @{ 'pid-1' = [ordered]@{ name = 'Policy A'; contentHash = 'abc'; lastModified = '2026-08-20T00:00:00Z'; lastSheetName = '2026-08-20'; lastModifiedBy = 'u@x' } }
        Write-Manifest -Manifest $m
        $back = Read-Manifest
        $back['pid-1'].contentHash | Should -Be 'abc'
        $back['pid-1'].name | Should -Be 'Policy A'
    }
}
