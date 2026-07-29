#requires -Modules Pester

<#
    Unit tests for scripts/Backup-IntunePolicies.ps1.

    These exercise the REAL functions from that file, loaded verbatim out of
    its AST by Import-ProductionFunction. Nothing here is a copy. If a function
    in the production script changes, these tests see the change; if it breaks,
    they fail. That was not true of the suite this replaces - see Issue #14 and
    docs/REVIEW-PHASE0.md.

    Offline: no tenant, no Graph, no ImportExcel. Enable-FakeGraph stands in
    for Microsoft Graph.

    Not covered here: Export-PolicyWorkbook, Export-IndexWorkbook,
    Get-WorkbookPath and Set-CellColor, which need the ImportExcel module.
    The end-to-end suite runs the script with -SkipExcel for the same reason.

    Run:  Invoke-Pester ./tests
#>

# The five files in scripts/ set no StrictMode at all (docs/REVIEW-PHASE0.md
# R-01), so the suite must not impose one: a harness stricter than production
# fails on things that cannot happen in the field, which is precisely how the
# old TestHelpers.ps1 managed to be green while shipping four real bugs.
# When R-11 turns StrictMode on in scripts/, change this to
# Set-StrictMode -Version 2.0 and this suite becomes the tool that verifies it.
Set-StrictMode -Off

# Pester 6 rejects a BeforeEach/AfterEach directly in the file root ("Each
# test setup is not supported in root") - only BeforeAll/AfterAll are allowed
# there. Wrapping the whole file in one outer Describe is a no-op for every
# Describe already nested inside it (their BeforeEach still runs after this
# one, exactly as when this was the file root), and keeps the file running
# unmodified under Pester 5.
Describe 'Backup-IntunePolicies.ps1 functions' {

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"

    $script:BackupScript = Get-ProductionScriptPath -Name 'Backup-IntunePolicies.ps1'

    . (Import-ProductionFunction -Path $script:BackupScript -Name @(
            'Add-SettingDefinitionToCache'
            'Get-SettingDefinition'
            'Resolve-SettingTitle'
            'Resolve-ChoiceValue'
            'ConvertTo-FlatSettings'
            'Get-StringSha256'
            'Get-PolicyContentHash'
            'Get-SafeFileName'
            'Get-VersionSheetName'
            'Format-AssignmentList'
            'Get-GroupDisplayName'
            'Get-AssignmentFilterName'
            'Resolve-Assignment'
        ))

    # Plain ConvertFrom-Json (PSCustomObject, not -AsHashtable) so the suite
    # runs on Windows PowerShell 5.1 as well as 7.
    $script:MixedSettings = Get-Content "$PSScriptRoot/fixtures/policy-mixed.json" -Raw | ConvertFrom-Json
}

BeforeEach {
    Initialize-BackupFunctionState
    Enable-FakeGraph
}

AfterAll {
    Disable-FakeGraph
    Clear-BackupFunctionState
}

Describe 'ConvertTo-FlatSettings' {

    It 'emits one row per leaf/choice value (6 for the mixed fixture)' {
        @(ConvertTo-FlatSettings -Settings $script:MixedSettings).Count | Should -Be 6
    }

    It 'flattens a simple string setting' {
        $rows = @(ConvertTo-FlatSettings -Settings $script:MixedSettings)
        ($rows | Where-Object Path -eq 'def_simple_string').Value | Should -Be 'hello'
    }

    It 'nests choice children under the parent path' {
        $rows = @(ConvertTo-FlatSettings -Settings $script:MixedSettings)
        $row  = $rows | Where-Object Path -eq 'def_choice \ def_choice_child'
        $row | Should -Not -BeNullOrEmpty
        $row.RawValue | Should -Be '42'
    }

    It 'expands a simple setting collection into one row per value' {
        $rows = @(ConvertTo-FlatSettings -Settings $script:MixedSettings)
        $coll = @($rows | Where-Object Path -eq 'def_simple_coll')
        $coll.Count | Should -Be 2
        ($coll.RawValue | Sort-Object) -join ',' | Should -Be 'a,b'
    }

    It 'walks group setting collection children' {
        $rows = @(ConvertTo-FlatSettings -Settings $script:MixedSettings)
        ($rows | Where-Object Path -eq 'def_group \ def_group_child').Value | Should -Be 'x'
    }

    It 'falls back to the raw definition id when nothing is cached' {
        $rows = @(ConvertTo-FlatSettings -Settings $script:MixedSettings)
        ($rows | Where-Object Path -eq 'def_simple_string').Title | Should -Be 'def_simple_string'
    }

    It 'resolves friendly title and choice value when the definition is cached' {
        Add-SettingDefinitionToCache -Definition @{
            id          = 'def_choice'
            displayName = 'My Choice Setting'
            options     = @(@{ itemId = 'def_choice_1'; name = 'Enabled' })
        }
        $row = @(ConvertTo-FlatSettings -Settings $script:MixedSettings) | Where-Object Path -eq 'def_choice'
        $row.Title    | Should -Be 'My Choice Setting'
        $row.Value    | Should -Be 'Enabled'
        $row.RawValue | Should -Be 'def_choice_1'
    }

    It 'records an unrecognised instance type instead of dropping it silently' {
        $odd = [pscustomobject]@{
            settingInstance = [pscustomobject]@{
                '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationFutureSettingInstance'
                settingDefinitionId = 'def_future'
            }
        }
        $rows = @(ConvertTo-FlatSettings -Settings @($odd))
        $rows.Count    | Should -Be 1
        $rows[0].Value | Should -Match 'unhandled type'
    }

    # --- R-02 / R-03 regressions ------------------------------------------
    # A Settings Catalog policy with no settings is legitimate, and Graph
    # supplies either $null or an empty array for it. Before the fix, a bare
    # [Parameter(Mandatory)] rejected both at BIND time - before the body ran -
    # which aborted the whole backup. A call-site @() wrapper cannot fix that,
    # so these have to be asserted against the declaration.

    It 'accepts $null settings without a binder rejection (R-03)' {
        { ConvertTo-FlatSettings -Settings $null } | Should -Not -Throw
    }

    It 'accepts an empty settings array without a binder rejection (R-03)' {
        { ConvertTo-FlatSettings -Settings @() } | Should -Not -Throw
    }

    It 'produces no rows for a policy with no settings' {
        @(ConvertTo-FlatSettings -Settings $null).Count | Should -Be 0
        @(ConvertTo-FlatSettings -Settings @()).Count   | Should -Be 0
    }
}

Describe 'Get-SettingDefinition' {

    It 'uses an inline cached definition rather than calling Graph' {
        Add-SettingDefinitionToCache -Definition @{
            id = 'def_x'; displayName = 'Setting X'; options = @(@{ itemId = 'opt_1'; name = 'On' })
        }
        (Get-SettingDefinition -Id 'def_x').DisplayName | Should -Be 'Setting X'
        @(Get-FakeGraphCall -UriLike '*configurationSettings*').Count | Should -Be 0
    }

    It 'negative-caches a definition it cannot fetch, so it asks Graph only once' {
        Get-SettingDefinition -Id 'def_missing' | Should -BeNullOrEmpty
        Get-SettingDefinition -Id 'def_missing' | Should -BeNullOrEmpty
        @(Get-FakeGraphCall -UriLike '*configurationSettings/def_missing*').Count | Should -Be 1
    }

    It 'cannot distinguish a throttled request from a missing definition (R-07, open)' {
        # This is the open finding, asserted as current behaviour rather than
        # as desired behaviour: a transient 429 lands in the same catch as a
        # genuine 404 and is cached as a permanent miss for the rest of the
        # run, silently degrading that setting to its raw GUID. The fix is a
        # shared retry-capable helper in Continuum.Core (Issue #15); when it
        # lands, this expectation should be inverted.
        Add-FakeGraphRoute -UriLike '*configurationSettings/def_throttled*' -ThrowMessage 'Response status code does not indicate success: 429 (Too Many Requests).'
        Get-SettingDefinition -Id 'def_throttled' | Should -BeNullOrEmpty
        Get-SettingDefinition -Id 'def_throttled' | Should -BeNullOrEmpty
        @(Get-FakeGraphCall -UriLike '*configurationSettings/def_throttled*').Count | Should -Be 1
    }

    It 'lets a real definition upgrade an earlier negative-cache miss' {
        Get-SettingDefinition -Id 'def_y' | Should -BeNullOrEmpty
        Add-SettingDefinitionToCache -Definition @{ id = 'def_y'; displayName = 'Setting Y'; options = @() }
        (Get-SettingDefinition -Id 'def_y').DisplayName | Should -Be 'Setting Y'
    }
}

Describe 'Resolve-ChoiceValue' {

    BeforeEach {
        Add-SettingDefinitionToCache -Definition @{
            id = 'def_c'; displayName = 'C'; options = @(@{ itemId = 'def_c_1'; name = 'Enabled' })
        }
    }

    It 'resolves a choice option id to its display name' {
        Resolve-ChoiceValue -DefinitionId 'def_c' -OptionValue 'def_c_1' | Should -Be 'Enabled'
    }

    It 'falls back to the raw option id when the option is unknown' {
        Resolve-ChoiceValue -DefinitionId 'def_c' -OptionValue 'def_c_9' | Should -Be 'def_c_9'
    }
}

Describe 'Resolve-Assignment' {

    It 'resolves a group target and its display name' {
        Add-FakeGraphRoute -UriLike 'v1.0/groups/g-mkt*' -Response @{ displayName = 'Marketing' }
        $a = Resolve-Assignment -Assignment (New-FakeAssignment -GroupId 'g-mkt')
        $a.AssignmentType | Should -Be 'groupAssignmentTarget'
        $a.IsExclude      | Should -BeFalse
        $a.GroupName      | Should -Be 'Marketing'
    }

    It 'flags an exclusion target' {
        Add-FakeGraphRoute -UriLike 'v1.0/groups/*' -Response @{ displayName = 'Contractors' }
        $a = Resolve-Assignment -Assignment (New-FakeAssignment -GroupId 'g-con' -Exclude)
        $a.AssignmentType | Should -Be 'exclusionGroupAssignmentTarget'
        $a.IsExclude      | Should -BeTrue
    }

    It "normalises Intune's all-zero 'no filter' GUID to nothing" {
        Add-FakeGraphRoute -UriLike 'v1.0/groups/*' -Response @{ displayName = 'Sales' }
        $a = Resolve-Assignment -Assignment (New-FakeAssignment -GroupId 'g1' `
                -FilterId '00000000-0000-0000-0000-000000000000' -FilterType 'none')
        $a.FilterId   | Should -BeNullOrEmpty
        $a.FilterName | Should -BeNullOrEmpty
    }

    It 'resolves a real assignment filter' {
        Add-FakeGraphRoute -UriLike 'v1.0/groups/*' -Response @{ displayName = 'Sales' }
        Add-FakeGraphRoute -UriLike '*assignmentFilters/f-1*' -Response @{ displayName = 'Corp devices' }
        $a = Resolve-Assignment -Assignment (New-FakeAssignment -GroupId 'g1' -FilterId 'f-1' -FilterType 'include')
        $a.FilterName | Should -Be 'Corp devices'
        $a.FilterType | Should -Be 'include'
    }

    It 'marks an unresolvable group instead of failing the run' {
        $a = Resolve-Assignment -Assignment (New-FakeAssignment -GroupId 'g-gone')
        $a.GroupName | Should -Be '<unresolved: g-gone>'
    }

    It 'rejects $null, which is why its callers must filter first (R-02)' {
        # Get-MgGraphAllPages emits nothing for a policy with no assignments,
        # so the caller's @($rawAssignments) is a ONE-element array holding
        # $null. This binder rejection is what aborted the backup. The
        # production fix is the caller's Where-Object { $_ }, not a change
        # here - so this test pins the behaviour that fix depends on.
        { Resolve-Assignment -Assignment $null } | Should -Throw
    }
}

Describe 'Get-PolicyContentHash' {

    BeforeEach {
        $script:Flat = @(ConvertTo-FlatSettings -Settings $script:MixedSettings)
        $script:Assign = @([pscustomobject]@{
                AssignmentType = 'groupAssignmentTarget'; GroupId = 'g1'; FilterId = $null; FilterType = 'none'
            })
    }

    It 'is stable for identical input' {
        (Get-PolicyContentHash -FlatSettings $script:Flat -Assignments $script:Assign) |
            Should -Be (Get-PolicyContentHash -FlatSettings $script:Flat -Assignments $script:Assign)
    }

    It 'is independent of settings order' {
        $reordered = @($script:Flat | Sort-Object { $_.RawValue })
        (Get-PolicyContentHash -FlatSettings $script:Flat -Assignments $script:Assign) |
            Should -Be (Get-PolicyContentHash -FlatSettings $reordered -Assignments $script:Assign)
    }

    It 'changes when a value changes' {
        $mutated = @($script:Flat | ForEach-Object {
                [pscustomobject]@{ Path = $_.Path; Title = $_.Title; Value = $_.Value; RawValue = ($_.RawValue + '_x') }
            })
        (Get-PolicyContentHash -FlatSettings $script:Flat -Assignments $script:Assign) |
            Should -Not -Be (Get-PolicyContentHash -FlatSettings $mutated -Assignments $script:Assign)
    }

    It 'ignores display names, so a Microsoft-side rename is not a new version' {
        $renamed = @($script:Flat | ForEach-Object {
                [pscustomobject]@{ Path = $_.Path; Title = 'Renamed by Microsoft'; Value = 'Renamed'; RawValue = $_.RawValue }
            })
        (Get-PolicyContentHash -FlatSettings $script:Flat -Assignments $script:Assign) |
            Should -Be (Get-PolicyContentHash -FlatSettings $renamed -Assignments $script:Assign)
    }

    It 'changes when an assignment changes' {
        $other = @([pscustomobject]@{
                AssignmentType = 'groupAssignmentTarget'; GroupId = 'g2'; FilterId = $null; FilterType = 'none'
            })
        (Get-PolicyContentHash -FlatSettings $script:Flat -Assignments $script:Assign) |
            Should -Not -Be (Get-PolicyContentHash -FlatSettings $script:Flat -Assignments $other)
    }

    # --- R-13 regression ---------------------------------------------------
    # ConvertTo-FlatSettings returns a List[object]; PowerShell enumerates an
    # IEnumerable on output, so a policy with no settings leaves the caller's
    # $flat as $null - and Backup-IntunePolicies.ps1:673 passes that straight
    # in. Adding [AllowNull()][AllowEmptyCollection()] to ConvertTo-FlatSettings
    # alone (the R-03 fix) just moved the crash one line down.

    It 'accepts the $null that an empty policy produces (R-13)' {
        { Get-PolicyContentHash -FlatSettings $null -Assignments @() } | Should -Not -Throw
    }

    It 'accepts an empty settings array (R-13)' {
        { Get-PolicyContentHash -FlatSettings @() -Assignments @() } | Should -Not -Throw
    }

    It 'hashes an empty policy deterministically' {
        (Get-PolicyContentHash -FlatSettings $null -Assignments @()) |
            Should -Be (Get-PolicyContentHash -FlatSettings $null -Assignments @())
    }

    It 'gives an empty policy a different hash from a populated one' {
        (Get-PolicyContentHash -FlatSettings $null -Assignments @()) |
            Should -Not -Be (Get-PolicyContentHash -FlatSettings $script:Flat -Assignments @())
    }
}

Describe 'Get-VersionSheetName' {

    It 'uses the plain date when free' {
        Get-VersionSheetName -Date ([datetime]'2026-08-20') -ExistingNames @() | Should -Be '2026-08-20'
    }

    It 'suffixes on a same-day collision' {
        Get-VersionSheetName -Date ([datetime]'2026-08-20') -ExistingNames @('2026-08-20') | Should -Be '2026-08-20_2'
    }

    It 'finds the next free suffix' {
        Get-VersionSheetName -Date ([datetime]'2026-08-20') -ExistingNames @('2026-08-20', '2026-08-20_2') |
            Should -Be '2026-08-20_3'
    }

    It 'keeps numbering correctly past _9' {
        $existing = @('2026-08-20') + @(2..10 | ForEach-Object { "2026-08-20_$_" })
        Get-VersionSheetName -Date ([datetime]'2026-08-20') -ExistingNames $existing | Should -Be '2026-08-20_11'
    }

    It 'orders same-day sheets numerically, not lexicographically (R-08, open)' -Skip {
        # SKIPPED ON PURPOSE - this asserts the fix for an open finding, so it
        # fails today. Get-VersionSheetName itself is correct (see the test
        # above); the defect is in Export-PolicyWorkbook, which picks the
        # "previous" sheet with a plain string Sort-Object. Once ten or more
        # sheets exist for one date, '_10' sorts before '_2' and the diff
        # highlighting compares against '_9'. Un-skip when R-08 is fixed, which
        # docs/ROADMAP.md schedules with the module extraction (Issue #15).
        $names = @('2026-08-20') + @(2..10 | ForEach-Object { "2026-08-20_$_" })
        (@($names | Sort-Object))[-1] | Should -Be '2026-08-20_10'
    }
}

Describe 'Format-AssignmentList' {

    It 'renders included groups, with filters where present' {
        $a = @(
            [pscustomobject]@{ AssignmentType = 'groupAssignmentTarget'; IsExclude = $false; GroupId = 'g1'; GroupName = 'Sales'; FilterId = $null; FilterName = $null; FilterType = 'none' }
            [pscustomobject]@{ AssignmentType = 'groupAssignmentTarget'; IsExclude = $false; GroupId = 'g2'; GroupName = 'HR'; FilterId = 'f1'; FilterName = 'Corp'; FilterType = 'include' }
        )
        Format-AssignmentList -Assignments $a | Should -Be 'Sales, HR [filter: Corp/include]'
    }

    It 'renders excluded groups only when asked' {
        $a = @(
            [pscustomobject]@{ AssignmentType = 'groupAssignmentTarget'; IsExclude = $false; GroupId = 'g1'; GroupName = 'Sales'; FilterId = $null; FilterName = $null; FilterType = 'none' }
            [pscustomobject]@{ AssignmentType = 'exclusionGroupAssignmentTarget'; IsExclude = $true; GroupId = 'g3'; GroupName = 'Contractors'; FilterId = $null; FilterName = $null; FilterType = 'none' }
        )
        Format-AssignmentList -Assignments $a           | Should -Be 'Sales'
        Format-AssignmentList -Assignments $a -Exclude   | Should -Be 'Contractors'
    }

    It 'surfaces group-less targets such as allDevices on the include side' {
        $a = @([pscustomobject]@{ AssignmentType = 'allDevicesAssignmentTarget'; IsExclude = $false; GroupId = $null; GroupName = $null; FilterId = $null; FilterName = $null; FilterType = 'none' })
        Format-AssignmentList -Assignments $a | Should -Be 'allDevicesAssignmentTarget'
    }

    It 'returns an empty string for an unassigned policy' {
        Format-AssignmentList -Assignments @() | Should -Be ''
    }

    It 'returns an empty string when Assignments is $null (a pre-R-02 snapshot)' {
        Format-AssignmentList -Assignments $null | Should -Be ''
    }
}

Describe 'Get-SafeFileName' {

    It 'replaces path-illegal characters with underscores' {
        Get-SafeFileName -Name 'A/B\C:D' | Should -Be 'A_B_C_D'
    }

    It 'trims surrounding whitespace' {
        Get-SafeFileName -Name '  Padded  ' | Should -Be 'Padded'
    }
}

Describe 'Get-StringSha256' {

    It 'produces the standard SHA-256 digest, lower-case and undelimited' {
        Get-StringSha256 -Text 'abc' |
            Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }
}

}
