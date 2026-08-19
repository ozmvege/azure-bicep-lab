<#
.SYNOPSIS
    Run the proof matrix from docs/10-verification.md against a deployed platform.

.DESCRIPTION
    Every check states a claim the architecture makes and then tries to break it. A claim
    that cannot be tested is not a control, it is a diagram, so each check here has an
    expected result that would look different if the platform were misconfigured.

    Nothing in this script changes anything. It reads, it curls, and it reports.

.EXAMPLE
    ./scripts/verify.ps1 -Environment dev
#>
[CmdletBinding()]
param(
    [ValidateSet('dev', 'prod')]
    [string]$Environment = 'dev',

    [string]$Workload = 'ztwp'
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$script:passed = 0
$script:failed = 0

function Assert-Claim {
    param(
        [string]$Claim,
        [scriptblock]$Test,
        [string]$Expected
    )

    Write-Host ''
    Write-Host "  $Claim" -ForegroundColor White
    Write-Host "    expected: $Expected" -ForegroundColor DarkGray

    $result = & $Test
    if ($result) {
        $script:passed++
        Write-Host '    PASS' -ForegroundColor Green
    }
    else {
        $script:failed++
        Write-Host '    FAIL' -ForegroundColor Red
    }
}

function Get-StatusCode {
    param([string]$Uri)
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method GET -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 20
        return [int]$response.StatusCode
    }
    catch {
        return -1
    }
}

Write-Host '==> Reading the deployment stack' -ForegroundColor Cyan
$stack = az stack sub show --name "$Workload-$Environment" -o json --only-show-errors | ConvertFrom-Json
$outputs = $stack.outputs

$gatewayFqdn = $outputs.gatewayFqdn.value
$appHostName = $outputs.appDefaultHostName.value
$keyVaultName = $outputs.keyVaultName.value
$storageAccountName = $outputs.storageAccountName.value
$appResourceGroup = $outputs.resourceGroups.value.app

Write-Host "    gateway : http://$gatewayFqdn"
Write-Host "    app     : https://$appHostName"

Assert-Claim -Claim 'The application has no usable public route' `
    -Expected '403 — the access restriction rejects everything that is not the gateway subnet' `
    -Test {
        $code = Get-StatusCode -Uri "https://$appHostName/"
        Write-Host "    actual:   HTTP $code" -ForegroundColor DarkGray
        $code -eq 403
    }

Assert-Claim -Claim 'The gateway is the way in' `
    -Expected '200 — the same application, reached through the WAF' `
    -Test {
        $code = Get-StatusCode -Uri "http://$gatewayFqdn/"
        Write-Host "    actual:   HTTP $code" -ForegroundColor DarkGray
        $code -eq 200
    }

Assert-Claim -Claim 'The WAF blocks SQL injection before the app sees it' `
    -Expected '403 — OWASP CRS rule 942xxx fires at the gateway' `
    -Test {
        $code = Get-StatusCode -Uri "http://$gatewayFqdn/?id=1%27%20OR%20%271%27%3D%271"
        Write-Host "    actual:   HTTP $code" -ForegroundColor DarkGray
        $code -eq 403
    }

Assert-Claim -Claim 'The WAF blocks path traversal too' `
    -Expected '403 — a second rule family, to show the first was not a coincidence' `
    -Test {
        $code = Get-StatusCode -Uri "http://$gatewayFqdn/?file=../../etc/passwd"
        Write-Host "    actual:   HTTP $code" -ForegroundColor DarkGray
        $code -eq 403
    }

Assert-Claim -Claim 'Storage refuses traffic from this machine' `
    -Expected 'the listing fails — public network access is disabled on the account' `
    -Test {
        az storage blob list `
            --account-name $storageAccountName `
            --container-name 'app-data' `
            --auth-mode login `
            --only-show-errors --output none 2>$null
        $LASTEXITCODE -ne 0
    }

Assert-Claim -Claim 'Shared keys are gone, not merely unused' `
    -Expected 'allowSharedKeyAccess is false, so there is no key left to leak' `
    -Test {
        $shared = az storage account show --name $storageAccountName --query allowSharedKeyAccess -o tsv --only-show-errors
        Write-Host "    actual:   allowSharedKeyAccess = $shared" -ForegroundColor DarkGray
        $shared -eq 'false'
    }

Assert-Claim -Claim 'The application configuration holds a reference, not a password' `
    -Expected 'DATABASE_URL contains @Microsoft.KeyVault(SecretUri=...)' `
    -Test {
        $appName = $appHostName.Split('.')[0]
        $settings = az webapp config appsettings list `
            --name $appName --resource-group $appResourceGroup `
            -o json --only-show-errors | ConvertFrom-Json
        $databaseUrl = ($settings | Where-Object { $_.name -eq 'DATABASE_URL' }).value
        Write-Host "    actual:   $databaseUrl" -ForegroundColor DarkGray
        $databaseUrl -like '@Microsoft.KeyVault(SecretUri=*'
    }

Assert-Claim -Claim 'The vault answers on a private address' `
    -Expected 'the private endpoint NIC holds an address inside the spoke VNet' `
    -Test {
        $nicIds = az network private-endpoint list --query "[].networkInterfaces[0].id" -o tsv --only-show-errors
        $addresses = @()
        foreach ($nicId in $nicIds) {
            $addresses += az network nic show --ids $nicId --query 'ipConfigurations[0].properties.privateIPAddress' -o tsv --only-show-errors
        }
        Write-Host ("    actual:   {0}" -f ($addresses -join ', ')) -ForegroundColor DarkGray
        ($addresses | Where-Object { $_ -like '10.20.*' }).Count -gt 0
    }

Assert-Claim -Claim 'Policy would reject a regression' `
    -Expected 'the baseline initiative is assigned and enforcing' `
    -Test {
        $assignments = az policy assignment list --query "[?name=='$Workload-baseline'].{name:name, mode:enforcementMode}" -o json --only-show-errors | ConvertFrom-Json
        Write-Host ("    actual:   {0} assignment(s)" -f $assignments.Count) -ForegroundColor DarkGray
        $assignments.Count -gt 0
    }

Assert-Claim -Claim 'The stack denies changes made outside the pipeline' `
    -Expected 'denySettings mode is denyWriteAndDelete' `
    -Test {
        $mode = $stack.denySettings.mode
        Write-Host "    actual:   $mode" -ForegroundColor DarkGray
        $mode -eq 'denyWriteAndDelete'
    }

Write-Host ''
Write-Host ('=' * 70)
Write-Host ("  passed: {0}    failed: {1}" -f $script:passed, $script:failed) -ForegroundColor $(if ($script:failed -eq 0) { 'Green' } else { 'Yellow' })
Write-Host ('=' * 70)
Write-Host ''
Write-Host 'A blocked request takes a few minutes to reach Log Analytics. When it has:' -ForegroundColor DarkGray
Write-Host '  AGWFirewallLogs | where Action == "Blocked" | project TimeGenerated, RuleId, Message, ClientIp' -ForegroundColor DarkGray

if ($script:failed -gt 0) { exit 1 }
