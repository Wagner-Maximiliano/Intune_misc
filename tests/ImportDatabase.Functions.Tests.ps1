#requires -Modules Pester

<#
    Tests for scripts/Import-PolicyHistoryToDatabase.ps1's offline logic, and
    - more importantly - a DRIFT DETECTOR between it and
    scripts/Backup-IntunePolicies.ps1.

    Those two files deliberately carry their own copies of ConvertTo-FlatSettings
    and Get-PolicyContentHash, because every script in this project must stay
    self-contained enough to be copied to a device on its own. The import
    script says so in its own comments: "Ported (deliberately, not dot-sourced)
    ... so the flattened rows AND the content hash come out identical to what
    the backup produced."

    Nothing enforced that until now. If the two copies drift, a policy version
    gets two different identities depending on which tool computed it, and the
    history database grows a spurious version row. The tests below load BOTH
    copies - each into its own scope, since they share function names - and
    compare their output byte for byte.

    The SQLite half of the script (Invoke-Db, Initialize-Schema and the ingest
    loop) is not covered: it needs the PSSQLite module. See docs/PROJECT_STATUS.md.

    Run:  Invoke-Pester ./tests
#>

# See Backup.Functions.Tests.ps1: scripts/ has no StrictMode (R-01).
Set-StrictMode -Off

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"

    $script:BackupScript = Get-ProductionScriptPath -Name 'Backup-IntunePolicies.ps1'
    $script:ImportScript = Get-ProductionScriptPath -Name 'Import-PolicyHistoryToDatabase.ps1'

    # The functions both files define. Get-SettingDefinition is deliberately
    # NOT identical (the import script is offline and never fetches), so the
    # comparisons below all run with a pre-seeded cache or with none at all -
    # cases where both must behave the same.
    $script:FlattenFunctions = @(
        'Add-SettingDefinitionToCache'
        'Get-SettingDefinition'
        'Resolve-SettingTitle'
        'Resolve-ChoiceValue'
        'ConvertTo-FlatSettings'
    )
    $script:HashFunctions = $script:FlattenFunctions + @('Get-StringSha256', 'Get-PolicyContentHash')

    $script:MixedSettings = Get-Content "$PSScriptRoot/fixtures/policy-mixed.json" -Raw | ConvertFrom-Json

    # A definition cache seed, as fixture data rather than as behaviour.
    $script:Seed = @{
        'def_choice' = [pscustomobject]@{
            DisplayName = 'My Choice Setting'
            Options     = @{ 'def_choice_1' = 'Enabled' }
        }
    }

    function Reset-DefinitionCacheFrom {
        <# Fresh global cache per run, so one script's negative-caching cannot
           leak into the other's comparison. #>
        param([hashtable]$Seed)
        $global:DefinitionCache = @{}
        if ($Seed) { foreach ($key in $Seed.Keys) { $global:DefinitionCache[$key] = $Seed[$key] } }
    }

    function Get-FlattenSignature {
        <# One script's flattened rows, rendered as comparable text. The
           functions are dot-sourced inside & { } so the two copies - which
           share names - never collide. #>
        param(
            [Parameter(Mandatory)][string]$ScriptPath,
            [AllowNull()][AllowEmptyCollection()]$Settings,
            [hashtable]$Seed
        )
        Reset-DefinitionCacheFrom -Seed $Seed
        return & {
            . (Import-ProductionFunction -Path $ScriptPath -Name $script:FlattenFunctions)
            $rows = @(ConvertTo-FlatSettings -Settings $Settings)
            ($rows | ForEach-Object { "$($_.Path)|$($_.Title)|$($_.Value)|$($_.RawValue)" }) -join "`n"
        }
    }

    function Get-HashSignature {
        <# One script's content hash, computed through its own call-site shape:
           $flat is deliberately NOT @()-wrapped, because neither production
           call site wraps it (that is what R-13 is about). #>
        param(
            [Parameter(Mandatory)][string]$ScriptPath,
            [AllowNull()][AllowEmptyCollection()]$Settings,
            [AllowNull()][AllowEmptyCollection()]$Assignments,
            [hashtable]$Seed
        )
        Reset-DefinitionCacheFrom -Seed $Seed
        return & {
            . (Import-ProductionFunction -Path $ScriptPath -Name $script:HashFunctions)
            $flat = ConvertTo-FlatSettings -Settings $Settings
            Get-PolicyContentHash -FlatSettings $flat -Assignments $Assignments
        }
    }
}

BeforeEach {
    Enable-FakeGraph
}

AfterAll {
    Disable-FakeGraph
    Clear-BackupFunctionState
}

Describe 'ConvertTo-FlatSettings parity between the backup and import scripts' {

    It 'produces identical rows with a seeded definition cache' {
        $fromBackup = Get-FlattenSignature -ScriptPath $script:BackupScript -Settings $script:MixedSettings -Seed $script:Seed
        $fromImport = Get-FlattenSignature -ScriptPath $script:ImportScript -Settings $script:MixedSettings -Seed $script:Seed

        $fromBackup | Should -Not -BeNullOrEmpty
        $fromImport | Should -Be $fromBackup
    }

    It 'produces identical rows when nothing is cached and both fall back to raw ids' {
        $fromBackup = Get-FlattenSignature -ScriptPath $script:BackupScript -Settings $script:MixedSettings
        $fromImport = Get-FlattenSignature -ScriptPath $script:ImportScript -Settings $script:MixedSettings

        $fromImport | Should -Be $fromBackup
    }

    It 'produces no rows in either copy for a snapshot with no settings' {
        (Get-FlattenSignature -ScriptPath $script:BackupScript -Settings $null) | Should -Be ''
        (Get-FlattenSignature -ScriptPath $script:ImportScript -Settings $null) | Should -Be ''
        (Get-FlattenSignature -ScriptPath $script:ImportScript -Settings @())   | Should -Be ''
    }

    It 'accepts $null settings without a binder rejection in the import copy (R-03)' {
        { Get-FlattenSignature -ScriptPath $script:ImportScript -Settings $null } | Should -Not -Throw
    }
}

Describe 'Get-PolicyContentHash parity between the backup and import scripts' {

    BeforeAll {
        $script:Assignments = @(
            [pscustomobject]@{ AssignmentType = 'groupAssignmentTarget'; GroupId = 'g1'; FilterId = 'f1'; FilterType = 'include' }
            [pscustomobject]@{ AssignmentType = 'exclusionGroupAssignmentTarget'; GroupId = 'g2'; FilterId = $null; FilterType = 'none' }
        )
    }

    It 'gives a policy the same identity in both tools' {
        # This is the invariant the import script's header promises. If it
        # breaks, the same policy state gets two version rows in the history
        # database and the "unchanged" check stops working across tools.
        $fromBackup = Get-HashSignature -ScriptPath $script:BackupScript -Settings $script:MixedSettings -Assignments $script:Assignments -Seed $script:Seed
        $fromImport = Get-HashSignature -ScriptPath $script:ImportScript -Settings $script:MixedSettings -Assignments $script:Assignments -Seed $script:Seed

        $fromBackup | Should -Not -BeNullOrEmpty
        $fromImport | Should -Be $fromBackup
    }

    It 'ignores display names in both copies' {
        # Seeded vs unseeded changes every Title and Value but no RawValue, so
        # the hash must not move.
        $seeded   = Get-HashSignature -ScriptPath $script:ImportScript -Settings $script:MixedSettings -Assignments $script:Assignments -Seed $script:Seed
        $unseeded = Get-HashSignature -ScriptPath $script:ImportScript -Settings $script:MixedSettings -Assignments $script:Assignments

        $seeded | Should -Be $unseeded
    }

    # --- R-13 regression, import side --------------------------------------
    # Import-PolicyHistoryToDatabase.ps1:432 passes ConvertTo-FlatSettings'
    # output straight into Get-PolicyContentHash. An empty policy makes that
    # $null, which a bare Mandatory parameter rejected at bind time - so the
    # ingest of a no-settings snapshot failed with "Could not read ...", the
    # very file the R-03 fix was meant to unblock.

    It 'hashes a snapshot with no settings without a binder rejection (R-13)' {
        { Get-HashSignature -ScriptPath $script:ImportScript -Settings $null -Assignments @() } | Should -Not -Throw
        { Get-HashSignature -ScriptPath $script:ImportScript -Settings @()   -Assignments @() } | Should -Not -Throw
    }

    It 'agrees on the hash of an empty policy across both tools' {
        # The backup sees $null from Graph; the import sees [] from the JSON.
        # They must still agree, or an empty policy is re-ingested as a new
        # version on every run.
        $fromBackup = Get-HashSignature -ScriptPath $script:BackupScript -Settings $null -Assignments @()
        $fromImport = Get-HashSignature -ScriptPath $script:ImportScript -Settings @()   -Assignments @()

        $fromImport | Should -Be $fromBackup
    }

    It 'agrees on a legacy snapshot whose Assignments is null (R-15, open)' -Skip {
        # SKIPPED ON PURPOSE - asserts the fix for an open finding, so it fails
        # today. Backup-IntunePolicies.ps1 always hands over an @()-wrapped
        # array, so zero assignments contribute zero lines. The import script
        # hands over @($snap.Assignments), and for a snapshot written before
        # the R-02 fix - "Assignments": null - that is a ONE-element array
        # holding $null, which contributes a phantom "|||" line. The same
        # policy state therefore hashes differently depending on which tool
        # computed it.
        # Not fixed here because the fix changes stored content hashes and so
        # creates one spurious version row per affected policy: that is the
        # user's call, per D-011. Un-skip when R-15 is resolved.
        $fromBackup = Get-HashSignature -ScriptPath $script:BackupScript -Settings $null -Assignments @()
        $fromImport = Get-HashSignature -ScriptPath $script:ImportScript -Settings $null -Assignments @($null)

        $fromImport | Should -Be $fromBackup
    }
}

Describe 'ConvertTo-DateTimeOrMin' {

    BeforeAll {
        . (Import-ProductionFunction -Path $script:ImportScript -Name 'ConvertTo-DateTimeOrMin')
    }

    It 'parses a round-trip timestamp' {
        (ConvertTo-DateTimeOrMin -Text '2026-07-01T10:05:00.0000000Z').Year | Should -Be 2026
    }

    It 'returns MinValue for unparseable text rather than throwing' {
        ConvertTo-DateTimeOrMin -Text 'not a timestamp' | Should -Be ([datetime]::MinValue)
    }

    It 'returns MinValue for empty input' {
        ConvertTo-DateTimeOrMin -Text ''   | Should -Be ([datetime]::MinValue)
        ConvertTo-DateTimeOrMin -Text '  ' | Should -Be ([datetime]::MinValue)
    }

    It 'orders snapshots chronologically, which is what the ingest relies on' {
        $earlier = ConvertTo-DateTimeOrMin -Text '2026-07-01T10:00:00.0000000Z'
        $later   = ConvertTo-DateTimeOrMin -Text '2026-07-02T10:00:00.0000000Z'
        $earlier | Should -BeLessThan $later
    }
}
