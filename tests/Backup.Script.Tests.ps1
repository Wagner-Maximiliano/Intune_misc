#requires -Modules Pester

<#
    End-to-end tests for scripts/Backup-IntunePolicies.ps1.

    These RUN THE SCRIPT - parameters, main body and all - against an offline
    fake for Microsoft Graph, and then inspect what it actually wrote to disk.
    That is the only way to catch the failure mode this project keeps hitting:
    a parameter binder rejecting a legitimate value BEFORE the function body
    runs, which no amount of unit-testing the body can see.

    Each of R-02, R-03, R-05, R-13 and R-14 in docs/REVIEW-PHASE0.md has a
    named regression test below. Every one of them was invisible to the suite
    this replaces (Issue #14).

    -SkipExcel throughout: the ImportExcel module is not needed, so these run
    anywhere. Export-PolicyWorkbook is consequently NOT covered - see
    docs/PROJECT_STATUS.md.

    Run:  Invoke-Pester ./tests
#>

# See the note in Backup.Functions.Tests.ps1: scripts/ has no StrictMode
# (R-01), so the harness must not add one.
Set-StrictMode -Off

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    $script:BackupScript = Get-ProductionScriptPath -Name 'Backup-IntunePolicies.ps1'
}

BeforeEach {
    $script:Out = New-TestRoot
    Enable-FakeGraph

    # The audit query is $top=1, so it returns exactly one event. Registered
    # for every test because the script asks for it on any changed policy.
    Add-FakeGraphRoute -UriLike '*auditEvents*' -Response @{
        value = @(@{ actor = @{ userPrincipalName = 'admin@contoso.invalid' } })
    }
}

AfterEach {
    Disable-FakeGraph
    Remove-TestRoot -Path $script:Out
}

Describe 'Backup-IntunePolicies.ps1 - a policy with no assignments (R-02)' {

    BeforeEach {
        $policy = New-FakePolicy -Id 'p-noassign' -Name 'Staged Policy' `
            -Settings @(New-FakeSimpleSetting -DefinitionId 'def_a' -Value 'one')

        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($policy) }

        # No 'value' key at all. This is what Graph returns for a policy that
        # has never been assigned, and it is what makes Get-MgGraphAllPages
        # emit nothing at all - so the caller sees $null, not an empty list.
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{}

        $script:Output = & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-String
        $script:Files  = @(Get-SnapshotFile -OutputPath $script:Out)
    }

    It 'does not abort the policy' {
        # Before the fix this was a parameter-binder rejection inside
        # Resolve-Assignment, caught by the per-policy try/catch and reported
        # as [errored] - so the backup "succeeded" while silently skipping the
        # policy.
        $script:Output | Should -Not -Match 'failed at line'
        $script:Output | Should -Match 'created'
    }

    It 'writes exactly one snapshot' {
        $script:Files.Count | Should -Be 1
    }

    It 'records Assignments as an empty array, not null' {
        # "Assignments": null is what made R-04 reachable in the restore path,
        # so the shape matters, not just the absence of a crash.
        $raw = Get-Content -LiteralPath $script:Files[0].FullName -Raw
        $raw | Should -Match '"Assignments":\s*\[\s*\]'
    }

    It 'still captures the policy settings' {
        $snap = Get-Content -LiteralPath $script:Files[0].FullName -Raw | ConvertFrom-Json
        @($snap.Settings).Count | Should -Be 1
    }

    It 'resolves who last modified the policy (R-14)' {
        # Get-MgGraphAllPages enumerates its List[object] on output, so the
        # single audit event arrived as a bare hashtable. Indexing it with [0]
        # is a key lookup that finds nothing, so this field was permanently
        # blank in every workbook and index until the @() wrapper was added.
        $snap = Get-Content -LiteralPath $script:Files[0].FullName -Raw | ConvertFrom-Json
        $snap.LastModifiedBy | Should -Be 'admin@contoso.invalid'
    }
}

Describe 'Backup-IntunePolicies.ps1 - a policy with no settings (R-03, R-13)' {

    # Graph supplies either null or an empty array for a Settings Catalog
    # policy that has no settings yet. Both are legitimate and both used to
    # abort the run: first at ConvertTo-FlatSettings' binder (R-03), and then,
    # once that was fixed, one line later at Get-PolicyContentHash's (R-13).

    It 'completes when Graph returns null settings' {
        $policy = New-FakePolicy -Id 'p-null' -Name 'Null Settings Policy' -Settings $null
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($policy) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{}

        $out = & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-String

        $out | Should -Not -Match 'failed at line'
        $out | Should -Match 'created'
        @(Get-SnapshotFile -OutputPath $script:Out).Count | Should -Be 1
    }

    It 'completes when Graph returns an empty settings array' {
        $policy = New-FakePolicy -Id 'p-empty' -Name 'Empty Settings Policy' -Settings @()
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($policy) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{}

        $out = & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-String

        $out | Should -Not -Match 'failed at line'
        $out | Should -Match 'created'
        @(Get-SnapshotFile -OutputPath $script:Out).Count | Should -Be 1
    }

    It 'snapshots the empty policy with no settings rather than inventing one' {
        $policy = New-FakePolicy -Id 'p-empty' -Name 'Empty Settings Policy' -Settings @()
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($policy) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{}

        & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-Null

        $files = @(Get-SnapshotFile -OutputPath $script:Out)
        $snap  = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
        $snap.Settings    | Should -BeNullOrEmpty
        $snap.ContentHash | Should -Not -BeNullOrEmpty
    }
}

Describe 'Backup-IntunePolicies.ps1 - a tenant with no policies (R-05)' {

    It 'completes and reports zero policies' {
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @() }

        $out = & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-String

        $out | Should -Match 'Found 0 policies'
        $out | Should -Not -Match 'failed at line'
    }

    It 'still writes its state files' {
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @() }
        & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-Null

        $state = Join-Path $script:Out 'state'
        (Test-Path -LiteralPath (Join-Path $state 'manifest.json'))    | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $state 'definitions.json')) | Should -BeTrue
    }
}

Describe 'Backup-IntunePolicies.ps1 - assignment resolution' {

    It 'writes resolved group and filter names into the snapshot' {
        $policy = New-FakePolicy -Id 'p-assigned' -Name 'Assigned Policy' `
            -Settings @(New-FakeSimpleSetting -DefinitionId 'def_a')

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

        & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-Null

        $files       = @(Get-SnapshotFile -OutputPath $script:Out)
        $snap        = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
        $assignments = @($snap.Assignments)

        $assignments.Count | Should -Be 2
        $included = $assignments | Where-Object { -not $_.IsExclude }
        $excluded = $assignments | Where-Object { $_.IsExclude }
        $included.GroupName  | Should -Be 'Pilot devices'
        $included.FilterName | Should -Be 'Corp owned'
        $excluded.GroupName  | Should -Be 'Kiosks'
    }

    It 'does not fail the run when a group can no longer be resolved' {
        $policy = New-FakePolicy -Id 'p-ghost' -Name 'Ghost Group Policy'
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($policy) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{
            value = @((New-FakeAssignment -GroupId 'g-deleted'))
        }
        # No route for the group: a deleted Entra group behaves exactly this way.

        $out = & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-String
        $out | Should -Not -Match 'failed at line'

        $files = @(Get-SnapshotFile -OutputPath $script:Out)
        $snap  = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
        @($snap.Assignments)[0].GroupName | Should -Be '<unresolved: g-deleted>'
    }
}

Describe 'Backup-IntunePolicies.ps1 - change detection' {

    It 'reports a policy as skipped when nothing has changed' {
        $policy = New-FakePolicy -Id 'p1' -Name 'Stable Policy' `
            -Settings @(New-FakeSimpleSetting -DefinitionId 'def_a' -Value 'one')
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($policy) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{}

        & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-Null
        $second = & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-String

        $second | Should -Match 'skipped'
        $second | Should -Not -Match 'failed at line'
    }

    It 'reports a policy as updated when a setting value changes' {
        $v1 = New-FakePolicy -Id 'p1' -Name 'Drifting Policy' `
            -Settings @(New-FakeSimpleSetting -DefinitionId 'def_a' -Value 'one')
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($v1) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{}

        & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-Null

        # Re-arm the fake with the tenant's next state.
        Enable-FakeGraph
        Add-FakeGraphRoute -UriLike '*auditEvents*' -Response @{
            value = @(@{ actor = @{ userPrincipalName = 'admin@contoso.invalid' } })
        }
        $v2 = New-FakePolicy -Id 'p1' -Name 'Drifting Policy' `
            -Settings @(New-FakeSimpleSetting -DefinitionId 'def_a' -Value 'two') `
            -LastModifiedDateTime '2026-07-02T10:00:00Z'
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($v2) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{}

        $second = & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-String

        $second | Should -Match 'updated'
        $second | Should -Not -Match 'failed at line'
    }

    It 'treats an assignment change as a new version even when settings are identical' {
        $policy = New-FakePolicy -Id 'p1' -Name 'Reassigned Policy' `
            -Settings @(New-FakeSimpleSetting -DefinitionId 'def_a' -Value 'one')
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($policy) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{}

        & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-Null

        Enable-FakeGraph
        Add-FakeGraphRoute -UriLike '*auditEvents*' -Response @{
            value = @(@{ actor = @{ userPrincipalName = 'admin@contoso.invalid' } })
        }
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($policy) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{
            value = @((New-FakeAssignment -GroupId 'g-new'))
        }
        Add-FakeGraphRoute -UriLike 'v1.0/groups/g-new*' -Response @{ displayName = 'Wave 1' }

        $second = & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-String

        $second | Should -Match 'updated'
    }
}

Describe 'Backup-IntunePolicies.ps1 - options' {

    It 'writes nothing under -WhatIf' {
        $policy = New-FakePolicy -Id 'p1' -Name 'Untouched Policy'
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($policy) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{}

        & $script:BackupScript -OutputPath $script:Out -SkipExcel -WhatIf 6>&1 3>&1 | Out-Null

        @(Get-SnapshotFile -OutputPath $script:Out).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path (Join-Path $script:Out 'state') 'manifest.json')) | Should -BeFalse
    }

    It 'filters to a single platform' {
        $win = New-FakePolicy -Id 'p-win' -Name 'Windows Policy' -Platforms 'windows10'
        $mac = New-FakePolicy -Id 'p-mac' -Name 'macOS Policy'   -Platforms 'macOS'
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @($win, $mac) }
        Add-FakeGraphRoute -UriLike '*configurationPolicies/*/assignments' -Response @{}

        $out = & $script:BackupScript -OutputPath $script:Out -SkipExcel -Platform Windows 6>&1 3>&1 | Out-String

        $out | Should -Match "Filtered to platform 'Windows': 1 of 2"
        $files = @(Get-SnapshotFile -OutputPath $script:Out)
        $files.Count  | Should -Be 1
        $files[0].Name | Should -BeLike 'Windows Policy*'
    }

    It 'connects when no Graph session exists yet' {
        Enable-FakeGraph -Disconnected
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @() }

        $out = & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-String

        $out | Should -Match 'No existing Graph connection found'
        $out | Should -Match 'Found 0 policies'
    }

    It 'reuses an existing Graph session rather than reconnecting' {
        Add-FakeGraphRoute -UriLike '*configurationPolicies*expand*' -Response @{ value = @() }

        $out = & $script:BackupScript -OutputPath $script:Out -SkipExcel 6>&1 3>&1 | Out-String

        $out | Should -Match 'Using existing Graph connection'
    }
}
