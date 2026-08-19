<#
.SYNOPSIS
    Deploy the platform as a deployment stack.

.DESCRIPTION
    Runs what-if first and waits for confirmation, then creates or updates the stack.

    A stack rather than a plain deployment, for three reasons:
      * resources removed from the template are removed from Azure instead of lingering
      * the deny assignment blocks portal edits to anything the stack manages
      * teardown becomes one command that cannot miss a resource group

.EXAMPLE
    ./scripts/deploy.ps1 -Environment dev
#>
[CmdletBinding()]
param(
    [ValidateSet('dev', 'prod')]
    [string]$Environment = 'dev',

    [string]$Location = 'westeurope',

    [string]$Workload = 'ztwp',

    [switch]$SkipWhatIf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$template = Join-Path $repoRoot 'infra/main.bicep'
$parameters = Join-Path $repoRoot "infra/main.$Environment.bicepparam"
$stackName = "$Workload-$Environment"

if (-not $SkipWhatIf) {
    Write-Host '==> What-if. Read it before answering.' -ForegroundColor Cyan
    az deployment sub what-if `
        --location $Location `
        --template-file $template `
        --parameters $parameters `
        --exclude-change-types Ignore NoChange

    $reply = Read-Host "Deploy stack $stackName? [y/N]"
    if ($reply -ne 'y') {
        Write-Host 'Aborted.' -ForegroundColor Yellow
        exit 1
    }
}

Write-Host '==> Creating the deployment stack' -ForegroundColor Cyan
az stack sub create `
    --name $stackName `
    --location $Location `
    --template-file $template `
    --parameters $parameters `
    --action-on-unmanage deleteResources `
    --deny-settings-mode denyWriteAndDelete `
    --deny-settings-apply-to-child-scopes `
    --description "Zero-trust web platform, $Environment" `
    --yes

Write-Host '==> Outputs' -ForegroundColor Cyan
az stack sub show --name $stackName --query outputs -o jsonc

Write-Host ''
Write-Host 'The gateway takes a few minutes to report a healthy backend. Then:' -ForegroundColor DarkGray
Write-Host '  ./scripts/verify.ps1' -ForegroundColor DarkGray
Write-Host 'And when you are done, do not forget:' -ForegroundColor DarkGray
Write-Host '  ./scripts/teardown.ps1' -ForegroundColor DarkGray
