<#
.SYNOPSIS
    Delete the stack and every resource it manages.

.DESCRIPTION
    Application Gateway WAF_v2 costs roughly USD 0.44 per hour whether traffic reaches it
    or not, so teardown is part of the lab rather than an afterthought.

    --action-on-unmanage deleteAll is the parameter that matters: it removes the managed
    resources and their resource groups. With detachAll the stack disappears and the bill
    does not.

    The bootstrap resource group is not managed by this stack and survives on purpose — the
    next deployment reuses the same password.

.EXAMPLE
    ./scripts/teardown.ps1 -Environment dev
#>
[CmdletBinding()]
param(
    [ValidateSet('dev', 'prod')]
    [string]$Environment = 'dev',

    [string]$Workload = 'ztwp'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stackName = "$Workload-$Environment"

Write-Host "==> Deleting stack $stackName and every resource it manages" -ForegroundColor Cyan
az stack sub delete `
    --name $stackName `
    --action-on-unmanage deleteAll `
    --yes

Write-Host '==> Anything left over?' -ForegroundColor Cyan
az group list --query "[?starts_with(name, 'rg-$Workload-')].name" -o tsv

Write-Host ''
Write-Host 'Only the bootstrap group should be listed above.' -ForegroundColor DarkGray
