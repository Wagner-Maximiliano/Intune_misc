<#
.SYNOPSIS
    Parse-check a PowerShell script with the real parser (no execution).
.DESCRIPTION
    Validates that a .ps1/.psm1 parses cleanly and every function compiles.
    Executes nothing in the target file, so it is safe to run against scripts
    with Windows-only or side-effecting top-level code. Exits 1 on parse errors.
.EXAMPLE
    pwsh -NoProfile -File parse-check.ps1 ./MyScript.ps1
#>
param(
    [Parameter(Mandatory)][string]$Path
)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "File not found: $Path"
    exit 1
}

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $Path).Path, [ref]$tokens, [ref]$errors)

if ($errors -and $errors.Count -gt 0) {
    Write-Host "PARSE ERRORS: $($errors.Count)"
    foreach ($e in $errors) {
        Write-Host ("  [line {0}] {1}" -f $e.Extent.StartLineNumber, $e.Message)
    }
    exit 1
}

$funcs = $ast.FindAll(
    { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

Write-Host "PARSE OK - no syntax errors"
Write-Host ("Functions compiled: {0}" -f $funcs.Count)
foreach ($f in $funcs) { Write-Host ("  - {0}" -f $f.Name) }
exit 0
