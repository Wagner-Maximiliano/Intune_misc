#requires -Modules Pester

<#
    End-to-end tests for scripts/Get-IntuneSettingsCatalogSnapshot.ps1, run
    against the offline Graph fake.

    This script has NO per-policy try/catch, so a binder rejection anywhere in
    the loop kills the entire run under $ErrorActionPreference = 'Stop'. That
    makes the R-02 regression here a plain "does it throw", and makes this the
    sharpest of the two backup paths to assert against.

    Run:  Invoke-Pester ./tests
#>

# See Backup.Functions.Tests.ps1: scripts/ has no StrictMode (R-01).
Set-StrictMode -Off

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    $script:SnapshotScript = Get-ProductionScriptPath -Name 'Get-IntuneSettingsCatalogSnapshot.ps1'
}

BeforeEach {
    $script:Out = New-TestRoot
    Enable-FakeGraph
}

AfterEach {
    Disable-FakeGraph
    Remove-TestRoot -Path $script:Out
}

Describe 'Get-IntuneSettingsCatalogSnapshot.ps1 - a policy with no assignments (R-02)' {

    BeforeEach {
        $policy = New-FakePolicy -Id 'p-noassign' -Name 'Staged Policy' `
            -Settings @(New-FakeSimpleSetting -DefinitionId 'def_a' -Value 'one')
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($policy) }
        # No 'value' key: Graph's shape for a policy that was never assigned.
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{}
    }

    It 'does not abort the run' {
        # Before the fix, Resolve-Assignment's Mandatory parameter rejected the
        # phantom $null that @($rawAssignments) produced, and with no try/catch
        # in this script that ended the whole snapshot.
        { & $script:SnapshotScript -OutputPath $script:Out 6>&1 3>&1 | Out-Null } | Should -Not -Throw
    }

    It 'writes the snapshot with Assignments as an empty array, not null' {
        & $script:SnapshotScript -OutputPath $script:Out 6>&1 3>&1 | Out-Null

        $files = @(Get-SnapshotFile -OutputPath $script:Out)
        $files.Count | Should -Be 1
        (Get-Content -LiteralPath $files[0].FullName -Raw) | Should -Match '"Assignments":\s*\[\s*\]'
    }
}

Describe 'Get-IntuneSettingsCatalogSnapshot.ps1 - a tenant with no policies (R-05)' {

    It 'completes and reports zero policies' {
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @() }

        $out = & $script:SnapshotScript -OutputPath $script:Out 6>&1 3>&1 | Out-String

        $out | Should -Match 'Found 0 policies'
        @(Get-SnapshotFile -OutputPath $script:Out).Count | Should -Be 0
    }
}

Describe 'Get-IntuneSettingsCatalogSnapshot.ps1 - assignment resolution' {

    It 'resolves group and filter names into the snapshot' {
        $policy = New-FakePolicy -Id 'p-assigned' -Name 'Assigned Policy'
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($policy) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{
            value = @(
                (New-FakeAssignment -GroupId 'g-inc' -FilterId 'f-1' -FilterType 'include'),
                (New-FakeAssignment -GroupId 'g-exc' -Exclude)
            )
        }
        Add-FakeGraphRoute -UriLike 'v1.0/groups/g-inc*'      -Response @{ displayName = 'Pilot devices' }
        Add-FakeGraphRoute -UriLike 'v1.0/groups/g-exc*'      -Response @{ displayName = 'Kiosks' }
        Add-FakeGraphRoute -UriLike '*assignmentFilters/f-1*' -Response @{ displayName = 'Corp owned' }

        & $script:SnapshotScript -OutputPath $script:Out 6>&1 3>&1 | Out-Null

        $files       = @(Get-SnapshotFile -OutputPath $script:Out)
        $snap        = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
        $assignments = @($snap.Assignments)

        $assignments.Count | Should -Be 2
        ($assignments | Where-Object { -not $_.IsExclude }).GroupName  | Should -Be 'Pilot devices'
        ($assignments | Where-Object { -not $_.IsExclude }).FilterName | Should -Be 'Corp owned'
        ($assignments | Where-Object { $_.IsExclude }).GroupName       | Should -Be 'Kiosks'
    }

    It "normalises Intune's all-zero 'no filter' GUID rather than trying to resolve it" {
        $policy = New-FakePolicy -Id 'p-nofilter' -Name 'No Filter Policy'
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($policy) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{
            value = @((New-FakeAssignment -GroupId 'g1' -FilterId '00000000-0000-0000-0000-000000000000' -FilterType 'none'))
        }
        Add-FakeGraphRoute -UriLike 'v1.0/groups/g1*' -Response @{ displayName = 'All staff' }

        & $script:SnapshotScript -OutputPath $script:Out 6>&1 3>&1 | Out-Null

        # The all-zero GUID must never be looked up as if it were a real filter.
        @(Get-FakeGraphCall -UriLike '*assignmentFilters*').Count | Should -Be 0

        $files = @(Get-SnapshotFile -OutputPath $script:Out)
        $snap  = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
        @($snap.Assignments)[0].FilterId | Should -BeNullOrEmpty
    }
}

Describe 'Get-IntuneSettingsCatalogSnapshot.ps1 - options' {

    It 'filters to a single platform' {
        $win = New-FakePolicy -Id 'p-win' -Name 'Windows Policy' -Platforms 'windows10'
        $mac = New-FakePolicy -Id 'p-mac' -Name 'macOS Policy'   -Platforms 'macOS'
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($win, $mac) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{}

        $out = & $script:SnapshotScript -OutputPath $script:Out -Platform Windows 6>&1 3>&1 | Out-String

        $out | Should -Match "Filtered to platform 'Windows': 1 of 2"
        $files = @(Get-SnapshotFile -OutputPath $script:Out)
        $files.Count   | Should -Be 1
        $files[0].Name | Should -BeLike 'Windows Policy*'
    }

    It 'sanitises a policy name that is not safe as a file name' {
        $policy = New-FakePolicy -Id 'p-slash' -Name 'Base/Line: Windows'
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($policy) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{}

        { & $script:SnapshotScript -OutputPath $script:Out 6>&1 3>&1 | Out-Null } | Should -Not -Throw

        $files = @(Get-SnapshotFile -OutputPath $script:Out)
        $files.Count   | Should -Be 1
        $files[0].Name | Should -Be 'Base_Line_ Windows__p-slash.json'
    }
}
