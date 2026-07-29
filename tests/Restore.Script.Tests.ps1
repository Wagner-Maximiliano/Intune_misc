#requires -Modules Pester

<#
    End-to-end tests for scripts/Restore-IntunePolicy.ps1.

    This is the project's only write path, so it gets tested as a whole
    script: almost all of its logic lives in the main body rather than in
    functions, and the payload it builds is the thing that matters. The Graph
    fake records the POST, so the test can assert on the exact body that would
    have gone to the tenant without ever reaching one.

    Two safety properties are asserted explicitly because they were design
    decisions, not accidents (see the script's own header):
      - it CREATES, never overwrites;
      - it NEVER assigns the restored policy to anything.

    Run:  Invoke-Pester ./tests
#>

# See Backup.Functions.Tests.ps1: scripts/ has no StrictMode (R-01).
Set-StrictMode -Off

# Pester 6 rejects a BeforeEach/AfterEach directly in the file root ("Each
# test setup is not supported in root") - only BeforeAll/AfterAll are allowed
# there. Wrapping the whole file in one outer Describe is a no-op for every
# Describe already nested inside it, and keeps the file running unmodified
# under Pester 5.
Describe 'Restore-IntunePolicy.ps1 end-to-end' {

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    $script:RestoreScript = Get-ProductionScriptPath -Name 'Restore-IntunePolicy.ps1'
    $script:OneSetting    = Join-Path $PSScriptRoot 'fixtures/snapshot-one-setting.json'
    $script:NullSettings  = Join-Path $PSScriptRoot 'fixtures/snapshot-null-settings.json'
    $script:WrongType     = Join-Path $PSScriptRoot 'fixtures/snapshot-wrong-type.json'
}

BeforeEach {
    Enable-FakeGraph
    Add-FakeGraphRoute -Method 'POST' -UriLike '*configurationPolicies' -Response @{
        id   = 'restored-policy-id'
        name = 'Restored'
    }
}

AfterEach {
    Disable-FakeGraph
}

Describe 'Restore-IntunePolicy.ps1 - a snapshot with null settings (R-04)' {

    # @($Snapshot.Settings) on "Settings": null yields a ONE-element array
    # holding $null, not an empty array. The payload loop used to turn that
    # phantom entry into { '@odata.type' = <default>; settingInstance = $null },
    # which both suppressed the "zero settings" warning (Count was 1) and
    # POSTed a malformed setting to Graph.

    It 'reports zero settings rather than one phantom setting' {
        $out = & $script:RestoreScript -JsonFile $script:NullSettings -WhatIf 6>&1 3>&1 | Out-String
        $out | Should -Match 'Settings count\s*:\s*0'
    }

    It 'warns that the restored policy will be empty' {
        $out = & $script:RestoreScript -JsonFile $script:NullSettings -WhatIf 6>&1 3>&1 | Out-String
        $out | Should -Match 'zero settings'
    }

    It 'POSTs no settings at all, rather than one null settingInstance' {
        & $script:RestoreScript -JsonFile $script:NullSettings -Confirm:$false 6>&1 3>&1 | Out-Null

        $posts = @(Get-FakeGraphCall -Method 'POST')
        $posts.Count | Should -Be 1
        $body = $posts[0].Body | ConvertFrom-Json
        $body.settings | Should -BeNullOrEmpty
    }

    It 'prints "(none)" for a snapshot whose Assignments is null' {
        $out = & $script:RestoreScript -JsonFile $script:NullSettings -WhatIf 6>&1 3>&1 | Out-String
        $out | Should -Match 'Included: \(none\)'
        $out | Should -Match 'Excluded: \(none\)'
    }
}

Describe 'Restore-IntunePolicy.ps1 - payload construction' {

    It 'sends exactly the settings the snapshot holds' {
        & $script:RestoreScript -JsonFile $script:OneSetting -Confirm:$false 6>&1 3>&1 | Out-Null

        $body = (@(Get-FakeGraphCall -Method 'POST'))[0].Body | ConvertFrom-Json
        @($body.settings).Count | Should -Be 1
        (@($body.settings)[0]).'@odata.type' | Should -Be '#microsoft.graph.deviceManagementConfigurationSetting'
    }

    It 'round-trips the nested settingInstance tree unchanged' {
        & $script:RestoreScript -JsonFile $script:OneSetting -Confirm:$false 6>&1 3>&1 | Out-Null

        $body     = (@(Get-FakeGraphCall -Method 'POST'))[0].Body | ConvertFrom-Json
        $instance = (@($body.settings)[0]).settingInstance
        $instance.settingDefinitionId          | Should -Be 'def_a'
        $instance.simpleSettingValue.value     | Should -Be 'one'
    }

    It 'strips the read-only settingDefinitions expansion Graph will not accept' {
        & $script:RestoreScript -JsonFile $script:OneSetting -Confirm:$false 6>&1 3>&1 | Out-Null

        $body    = (@(Get-FakeGraphCall -Method 'POST'))[0].Body | ConvertFrom-Json
        $setting = @($body.settings)[0]
        @($setting.PSObject.Properties.Name) | Should -Not -Contain 'settingDefinitions'
        @($setting.PSObject.Properties.Name) | Should -Not -Contain 'id'
    }

    It 'carries the platform and technology across' {
        & $script:RestoreScript -JsonFile $script:OneSetting -Confirm:$false 6>&1 3>&1 | Out-Null

        $body = (@(Get-FakeGraphCall -Method 'POST'))[0].Body | ConvertFrom-Json
        $body.platforms    | Should -Be 'windows10'
        $body.technologies | Should -Be 'mdm'
        $body.'@odata.type' | Should -Be '#microsoft.graph.deviceManagementConfigurationPolicy'
    }
}

Describe 'Restore-IntunePolicy.ps1 - naming' {

    It 'appends a restored-on marker by default' {
        $expected = 'Baseline Policy (restored {0})' -f (Get-Date).ToString('yyyy-MM-dd')
        & $script:RestoreScript -JsonFile $script:OneSetting -Confirm:$false 6>&1 3>&1 | Out-Null

        $body = (@(Get-FakeGraphCall -Method 'POST'))[0].Body | ConvertFrom-Json
        $body.name | Should -Be $expected
    }

    It 'uses -NewName verbatim when given' {
        & $script:RestoreScript -JsonFile $script:OneSetting -NewName 'Baseline (recovered)' -Confirm:$false 6>&1 3>&1 | Out-Null

        $body = (@(Get-FakeGraphCall -Method 'POST'))[0].Body | ConvertFrom-Json
        $body.name | Should -Be 'Baseline (recovered)'
    }

    It 'reproduces the original name with -UseOriginalName' {
        & $script:RestoreScript -JsonFile $script:OneSetting -UseOriginalName -Confirm:$false 6>&1 3>&1 | Out-Null

        $body = (@(Get-FakeGraphCall -Method 'POST'))[0].Body | ConvertFrom-Json
        $body.name | Should -Be 'Baseline Policy'
    }

    It 'lets -NewName win over -UseOriginalName' {
        & $script:RestoreScript -JsonFile $script:OneSetting -NewName 'Explicit' -UseOriginalName -Confirm:$false 6>&1 3>&1 | Out-Null

        $body = (@(Get-FakeGraphCall -Method 'POST'))[0].Body | ConvertFrom-Json
        $body.name | Should -Be 'Explicit'
    }
}

Describe 'Restore-IntunePolicy.ps1 - safety boundaries' {

    It 'never assigns the restored policy to anything' {
        # A deliberate boundary, not a missing feature: the original
        # assignments are printed for manual re-application and nothing else.
        & $script:RestoreScript -JsonFile $script:OneSetting -Confirm:$false 6>&1 3>&1 | Out-Null
        @(Get-FakeGraphCall -UriLike '*assign*').Count | Should -Be 0
    }

    It 'only ever POSTs - it never PATCHes or PUTs an existing policy' {
        & $script:RestoreScript -JsonFile $script:OneSetting -Confirm:$false 6>&1 3>&1 | Out-Null

        $methods = @(@(Get-FakeGraphCall) | ForEach-Object { $_.Method } | Sort-Object -Unique)
        $methods.Count | Should -Be 1
        $methods[0]    | Should -Be 'POST'
    }

    It 'prints the original assignments for manual re-application' {
        $out = & $script:RestoreScript -JsonFile $script:OneSetting -WhatIf 6>&1 3>&1 | Out-String
        $out | Should -Match 'Included: Pilot devices \[filter: Corp owned/include\]'
        $out | Should -Match 'Excluded: Kiosks'
    }

    It 'creates nothing under -WhatIf' {
        & $script:RestoreScript -JsonFile $script:OneSetting -WhatIf 6>&1 3>&1 | Out-Null
        @(Get-FakeGraphCall -Method 'POST').Count | Should -Be 0
    }

    It 'refuses a snapshot that is not a Settings Catalog policy' {
        { & $script:RestoreScript -JsonFile $script:WrongType -WhatIf 6>&1 3>&1 | Out-Null } |
            Should -Throw '*Only Settings Catalog snapshots*'
    }

    It 'refuses a JSON file that does not exist' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) 'definitely-not-here.json'
        { & $script:RestoreScript -JsonFile $missing -WhatIf 6>&1 3>&1 | Out-Null } |
            Should -Throw '*not found*'
    }
}

}
