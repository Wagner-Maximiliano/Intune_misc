<#
.SYNOPSIS
    Dot-source this file, then dot-source the result of Get-ScriptFunctions to
    load ONLY the function definitions from a target script into your harness —
    skipping the target's top-level body.
.DESCRIPTION
    Most Windows-targeted scripts run code at the top level (admin checks,
    param wiring, registry reads) that fails the instant you dot-source the
    whole file on Linux. Get-ScriptFunctions parses the target's AST, extracts
    just the function definitions, and returns them as an unbound scriptblock.

    Usage is a DOUBLE dot-source, and the second one matters:

        . ./load-functions.ps1                       # defines Get-ScriptFunctions
        . (Get-ScriptFunctions -Path ./MyScript.ps1) # loads the target's functions HERE

    The second `. (...)` executes the returned scriptblock in the CURRENT scope,
    so the loaded functions are callable in your harness. If you instead call
    Get-ScriptFunctions without the leading dot, the functions load into a child
    scope and disappear — the dot is what injects them into your scope.
.EXAMPLE
    . ./load-functions.ps1
    . (Get-ScriptFunctions -Path ./MyScript.ps1)
    Get-TokenSet 'AllowTelemetry/Config'
#>

function Get-ScriptFunctions {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Target script not found: $Path"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path -LiteralPath $Path).Path, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        $first = $errors[0]
        throw ("Target script has parse errors (e.g. line {0}: {1}). Run parse-check.ps1 first." -f `
            $first.Extent.StartLineNumber, $first.Message)
    }

    $funcAsts = $ast.FindAll(
        { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

    if (-not $funcAsts -or $funcAsts.Count -eq 0) {
        Write-Warning "No function definitions found in $Path."
        return [scriptblock]::Create('')
    }

    $definitions = ($funcAsts | ForEach-Object { $_.Extent.Text }) -join "`n`n"
    # Return an UNBOUND scriptblock. The caller must dot-source it — `. (...)` —
    # so the functions land in the caller's scope, not a throwaway child scope.
    return [scriptblock]::Create($definitions)
}
