#requires -Modules Pester

<#
    Tests for scripts/Export-PolicySummary.ps1.

    That script is almost entirely a main body ending in Export-Excel, so only
    its one function is unit-testable offline: Format-AssignmentGroup, which is
    a third copy of the assignment rendering that Backup-IntunePolicies.ps1 and
    Restore-IntunePolicy.ps1 both call Format-AssignmentList. Its comment says
    "Same rendering used by Backup-IntunePolicies.ps1 / Export-PolicySummary.ps1".
    The parity test below is what makes that claim true rather than aspirational
    - the two names differ, so both copies can be loaded side by side here.

    The Excel export itself needs the ImportExcel module and is not covered.
    See docs/PROJECT_STATUS.md.

    Run:  Invoke-Pester ./tests
#>

# See Backup.Functions.Tests.ps1: scripts/ has no StrictMode (R-01).
Set-StrictMode -Off

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"

    . (Import-ProductionFunction `
            -Path (Get-ProductionScriptPath -Name 'Export-PolicySummary.ps1') `
            -Name 'Format-AssignmentGroup')

    . (Import-ProductionFunction `
            -Path (Get-ProductionScriptPath -Name 'Backup-IntunePolicies.ps1') `
            -Name 'Format-AssignmentList')

    $script:Assignments = @(
        [pscustomobject]@{ AssignmentType = 'groupAssignmentTarget'; IsExclude = $false; GroupId = 'g1'; GroupName = 'Sales'; FilterId = $null; FilterName = $null; FilterType = 'none' }
        [pscustomobject]@{ AssignmentType = 'groupAssignmentTarget'; IsExclude = $false; GroupId = 'g2'; GroupName = 'HR'; FilterId = 'f1'; FilterName = 'Corp'; FilterType = 'include' }
        [pscustomobject]@{ AssignmentType = 'exclusionGroupAssignmentTarget'; IsExclude = $true; GroupId = 'g3'; GroupName = 'Kiosks'; FilterId = $null; FilterName = $null; FilterType = 'none' }
    )
}

Describe 'Format-AssignmentGroup' {

    It 'renders included groups with their filters' {
        Format-AssignmentGroup -Assignments $script:Assignments |
            Should -Be 'Sales, HR [filter: Corp/include]'
    }

    It 'renders excluded groups only when asked' {
        Format-AssignmentGroup -Assignments $script:Assignments -Exclude | Should -Be 'Kiosks'
    }

    It 'surfaces group-less targets such as allDevices on the include side' {
        $special = @([pscustomobject]@{ AssignmentType = 'allLicensedUsersAssignmentTarget'; IsExclude = $false; GroupId = $null; GroupName = $null; FilterId = $null; FilterName = $null; FilterType = 'none' })
        Format-AssignmentGroup -Assignments $special | Should -Be 'allLicensedUsersAssignmentTarget'
    }

    It 'returns an empty string for an unassigned policy' {
        Format-AssignmentGroup -Assignments @() | Should -Be ''
    }

    It 'returns an empty string when Assignments is $null (a pre-R-02 snapshot)' {
        Format-AssignmentGroup -Assignments $null | Should -Be ''
    }
}

Describe 'Format-AssignmentGroup parity with Format-AssignmentList' {

    # Three files render assignments; two of them are copies. Until Issue #15
    # collapses them into Continuum.Core, this is what stops them diverging
    # without anyone noticing.

    It 'renders included groups the same way as the backup script' {
        Format-AssignmentGroup -Assignments $script:Assignments |
            Should -Be (Format-AssignmentList -Assignments $script:Assignments)
    }

    It 'renders excluded groups the same way as the backup script' {
        Format-AssignmentGroup -Assignments $script:Assignments -Exclude |
            Should -Be (Format-AssignmentList -Assignments $script:Assignments -Exclude)
    }

    It 'agrees on an unassigned policy' {
        Format-AssignmentGroup -Assignments @() | Should -Be (Format-AssignmentList -Assignments @())
        Format-AssignmentGroup -Assignments $null | Should -Be (Format-AssignmentList -Assignments $null)
    }

    It 'agrees on a group-less target' {
        $special = @([pscustomobject]@{ AssignmentType = 'allDevicesAssignmentTarget'; IsExclude = $false; GroupId = $null; GroupName = $null; FilterId = $null; FilterName = $null; FilterType = 'none' })
        Format-AssignmentGroup -Assignments $special | Should -Be (Format-AssignmentList -Assignments $special)
    }
}
