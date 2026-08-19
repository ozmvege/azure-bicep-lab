<#
.SYNOPSIS
    Everything CI does, minus the parts that need Azure.

.DESCRIPTION
    Compiles every template, compiles both parameter files, lints against the elevated
    rules in bicepconfig.json, and runs the offline assertions. No subscription, no login,
    no cost — which is why it should run before every commit.

.EXAMPLE
    ./scripts/validate.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = 0

Write-Host '==> Compiling templates' -ForegroundColor Cyan
Get-ChildItem -Path (Join-Path $repoRoot 'infra') -Filter '*.bicep' -Recurse |
    Where-Object { $_.FullName -notmatch '[\/]tests[\/]' } |
    ForEach-Object {
        az bicep build --file $_.FullName --stdout *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("    FAIL {0}" -f $_.Name) -ForegroundColor Red
            $failures++
        }
        else {
            Write-Host ("    ok   {0}" -f $_.Name) -ForegroundColor DarkGray
        }
    }

Write-Host '==> Compiling parameter files' -ForegroundColor Cyan
foreach ($file in @('main.dev.bicepparam', 'main.prod.bicepparam')) {
    az bicep build-params --file (Join-Path $repoRoot "infra/$file") --stdout *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("    FAIL {0}" -f $file) -ForegroundColor Red
        $failures++
    }
    else {
        Write-Host ("    ok   {0}" -f $file) -ForegroundColor DarkGray
    }
}

Write-Host '==> Linting' -ForegroundColor Cyan
az bicep lint --file (Join-Path $repoRoot 'infra/main.bicep')
if ($LASTEXITCODE -ne 0) { $failures++ }

Write-Host '==> Offline assertions' -ForegroundColor Cyan
# az bicep has no `test` subcommand; the standalone binary that az bicep install places in
# ~/.azure/bin does.
$bicepExe = Join-Path $HOME '.azure/bin/bicep.exe'
if (-not (Test-Path $bicepExe)) { $bicepExe = 'bicep' }
& $bicepExe test (Join-Path $repoRoot 'infra/tests/main.tests.bicep')
if ($LASTEXITCODE -ne 0) { $failures++ }

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
}
else {
    Write-Host ("{0} check(s) failed." -f $failures) -ForegroundColor Red
    exit 1
}
