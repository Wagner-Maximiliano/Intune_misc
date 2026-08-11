@{
    RootModule        = 'Continuum.Core.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '7c1f0f4e-3b6a-4a2b-9d1e-2f5a8c0b6d31'
    Author            = 'Continuum'
    Description       = 'Shared foundation for the Continuum toolsets: file I/O, Graph paging, naming, policy content hashing and assignment rendering.'

    # 5.1 is the floor for the whole project - the scripts that consume this
    # module all declare #requires -Version 5.1.
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Write-TextFile'
        'ConvertFrom-JsonFile'
        'Get-MgGraphAllPages'
        'Get-SafeFileName'
        'Get-StringSha256'
        'Get-PolicyContentHash'
        'Format-AssignmentList'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # No RequiredModules on purpose. Get-MgGraphAllPages calls
    # Invoke-MgGraphRequest, but declaring Microsoft.Graph.Authentication here
    # would make importing this module fail on a machine that only ever runs
    # the offline paths (Import-PolicyHistoryToDatabase.ps1, Export-PolicySummary.ps1)
    # and would break the offline Pester suite, which substitutes its own
    # stand-in for that command. The consuming scripts already document and
    # check their own Graph prerequisites.
}
