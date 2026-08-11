#requires -Modules Pester

<#
    Tests for the assignment rendering that scripts/Export-PolicySummary.ps1
    uses, which now lives in modules/Continuum.Core.

    HISTORY, because this file used to be a parity test. Three files rendered
    assignments: Backup-IntunePolicies.ps1 and Restore-IntunePolicy.ps1 called
    it Format-AssignmentList, and Export-PolicySummary.ps1 had the same body
    under the name Format-AssignmentGroup. The parity Describe here existed to
    stop those copies drifting apart without anyone noticing.

    Issue #15 collapsed all three into one function (docs/DECISIONS.md D-018),
    so the parity tests were deleted rather than left asserting that a function
    equals itself - docs/PROJECT_STATUS.md called for exactly that when the
    copies went away. The behavioural assertions below are kept verbatim: they
    were written against the summary script's rendering and are now the shared
    function's contract.

    The Excel export itself needs the ImportExcel module and is not covered.
    See docs/PROJECT_STATUS.md.

    Run:  Invoke-Pester ./tests
#>

# See Backup.Functions.Tests.ps1: scripts/ has no StrictMode (R-01), and
# Continuum.Core sets none either, matching the code that moved into it.
Set-StrictMode -Off

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"

    Import-ContinuumModule

    $script:Assignments = @(
        [pscustomobject]@{ AssignmentType = 'groupAssignmentTarget'; IsExclude = $false; GroupId = 'g1'; GroupName = 'Sales'; FilterId = $null; FilterName = $null; FilterType = 'none' }
        [pscustomobject]@{ AssignmentType = 'groupAssignmentTarget'; IsExclude = $false; GroupId = 'g2'; GroupName = 'HR'; FilterId = 'f1'; FilterName = 'Corp'; FilterType = 'include' }
        [pscustomobject]@{ AssignmentType = 'exclusionGroupAssignmentTarget'; IsExclude = $true; GroupId = 'g3'; GroupName = 'Kiosks'; FilterId = $null; FilterName = $null; FilterType = 'none' }
    )
}

Describe 'Format-AssignmentList, as Export-PolicySummary.ps1 uses it' {

    It 'renders included groups with their filters' {
        Format-AssignmentList -Assignments $script:Assignments |
            Should -Be 'Sales, HR [filter: Corp/include]'
    }

    It 'renders excluded groups only when asked' {
        Format-AssignmentList -Assignments $script:Assignments -Exclude | Should -Be 'Kiosks'
    }

    It 'surfaces group-less targets such as allDevices on the include side' {
        $special = @([pscustomobject]@{ AssignmentType = 'allLicensedUsersAssignmentTarget'; IsExclude = $false; GroupId = $null; GroupName = $null; FilterId = $null; FilterName = $null; FilterType = 'none' })
        Format-AssignmentList -Assignments $special | Should -Be 'allLicensedUsersAssignmentTarget'
    }

    It 'returns an empty string for an unassigned policy' {
        Format-AssignmentList -Assignments @() | Should -Be ''
    }

    It 'returns an empty string when Assignments is $null (a pre-R-02 snapshot)' {
        Format-AssignmentList -Assignments $null | Should -Be ''
    }

    It 'keeps a group-less target out of the exclude side' {
        # Previously only covered indirectly, by the parity comparison against
        # the backup script's copy. Asserted directly now that there is one
        # function to assert about.
        $special = @([pscustomobject]@{ AssignmentType = 'allDevicesAssignmentTarget'; IsExclude = $false; GroupId = $null; GroupName = $null; FilterId = $null; FilterName = $null; FilterType = 'none' })
        Format-AssignmentList -Assignments $special -Exclude | Should -Be ''
    }
}
