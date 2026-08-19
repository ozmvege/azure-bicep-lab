<#
.SYNOPSIS
    Phase zero: create the bootstrap Key Vault and seed the database password into it.

.DESCRIPTION
    Run once per subscription and environment, before the platform is ever deployed. The
    password is generated here, written straight to the vault, and never printed, never
    stored in a file and never passed on a command line that ends up in shell history.

    The three values printed at the end go into infra/main.<environment>.bicepparam, where
    az.getSecret turns them into a Key Vault reference that the deployment engine resolves
    on its own.

.EXAMPLE
    ./scripts/bootstrap.ps1 -Environment dev -Location westeurope
#>
[CmdletBinding()]
param(
    [ValidateSet('dev', 'prod')]
    [string]$Environment = 'dev',

    [string]$Location = 'westeurope',

    [string]$Workload = 'ztwp',

    # Your public address. Locks the bootstrap vault to it; leave empty to allow any network.
    [string]$ManagementIpAddress = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

Write-Host '==> Checking the signed-in context' -ForegroundColor Cyan
$account = az account show --only-show-errors | ConvertFrom-Json
Write-Host ("    subscription : {0} ({1})" -f $account.name, $account.id)
Write-Host ("    identity     : {0}" -f $account.user.name)

$operatorObjectId = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $operatorObjectId) {
    Write-Warning 'Could not resolve the signed-in user. Skipping the role assignment; grant Key Vault Secrets Officer by hand.'
    $operatorObjectId = ''
}

if (-not $ManagementIpAddress) {
    $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json').ip
    $ManagementIpAddress = "$publicIp/32"
    Write-Host ("    detected IP  : {0}" -f $ManagementIpAddress)
}

Write-Host '==> Deploying the bootstrap resource group and vault' -ForegroundColor Cyan
$deployment = az deployment sub create `
    --name "bootstrap-$Workload-$Environment" `
    --location $Location `
    --template-file (Join-Path $repoRoot 'infra/bootstrap.bicep') `
    --parameters workload=$Workload environment=$Environment `
                 managementIpAddress=$ManagementIpAddress `
                 operatorObjectId=$operatorObjectId `
    --only-show-errors | ConvertFrom-Json

$vaultName = $deployment.properties.outputs.bootstrapVaultName.value
$resourceGroupName = $deployment.properties.outputs.bootstrapResourceGroupName.value
$subscriptionId = $deployment.properties.outputs.subscriptionId.value

Write-Host '==> Seeding the database password' -ForegroundColor Cyan
$existing = az keyvault secret show --vault-name $vaultName --name 'postgres-admin-password' --query id -o tsv 2>$null
if ($existing) {
    Write-Host '    secret already present — leaving it alone'
}
else {
    # Alphanumeric only. The connection string is a URI, and a password containing @ or /
    # breaks it in a way that surfaces three modules later as a connection error.
    $alphabet = (48..57) + (65..90) + (97..122)
    $password = -join ($alphabet | Get-Random -Count 32 | ForEach-Object { [char]$_ })

    az keyvault secret set `
        --vault-name $vaultName `
        --name 'postgres-admin-password' `
        --value $password `
        --only-show-errors --output none

    Remove-Variable password
    Write-Host '    32-character password generated and stored'
}

Write-Host ''
Write-Host 'Put these three values into infra/main.' -NoNewline
Write-Host "$Environment" -NoNewline -ForegroundColor Yellow
Write-Host '.bicepparam:' -NoNewline
Write-Host ''
Write-Host ''
Write-Host 'param postgresAdministratorPassword = az.getSecret('
Write-Host ("  '{0}'," -f $subscriptionId) -ForegroundColor Green
Write-Host ("  '{0}'," -f $resourceGroupName) -ForegroundColor Green
Write-Host ("  '{0}'," -f $vaultName) -ForegroundColor Green
Write-Host "  'postgres-admin-password'"
Write-Host ')'
Write-Host ''
Write-Host ("Also set: param managementIpAddress = '{0}'" -f $ManagementIpAddress)
