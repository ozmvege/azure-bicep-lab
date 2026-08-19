# 04 — Compute: App Service with two network edges

> Outbound through the VNet, inbound only from the gateway, and a configuration that holds
> a reference where a password used to be. Then the console that lets you prove all of it
> from inside the VNet for free.

**Time:** 40 minutes · **Cost:** ~USD 0.018/hour (B1 plan)

**File:** [`app-service.bicep`](../infra/modules/app/app-service.bicep)

---

## 4.1 Two edges, not one

App Service has two independent network boundaries and confusing them is the most common
mistake in this architecture:

| | Direction | Feature | What it does |
|---|---|---|---|
| **Outbound** | app → VNet | VNet integration | lets the app reach private endpoints |
| **Inbound** | client → app | access restrictions **or** private endpoint | decides who may reach the app |

Turning on VNet integration does nothing whatsoever for inbound traffic. An app with
integration and no inbound control is still reachable by anyone who knows its
`*.azurewebsites.net` name.

### Outbound

```bicep
virtualNetworkSubnetId: appServiceSubnetId
vnetRouteAllEnabled: true
```

`vnetRouteAllEnabled` is the second half. Without it only RFC 1918 destinations go through
the VNet, and calls to `*.vault.azure.net` — a public hostname that resolves privately —
take the internet path instead, missing the private endpoint entirely. This is the switch
that makes Key Vault references resolve over Private Link.

The subnet must be delegated to `Microsoft.Web/serverFarms`, which
[chapter 02](02-network.md) already did.

### Inbound, dev profile

```bicep
publicNetworkAccess: 'Enabled'
ipSecurityRestrictionsDefaultAction: 'Deny'
ipSecurityRestrictions: [
  {
    vnetSubnetResourceId: applicationGatewaySubnetId
    action: 'Allow'
    priority: 100
    name: 'AllowApplicationGatewaySubnet'
  }
]
```

The rule names a **subnet**, not an IP address. That works because `snet-agw` carries the
`Microsoft.Web` service endpoint (added in [chapter 02](02-network.md)): traffic from the
gateway to the app leaves with a subnet identity, and the app can refuse everything else.
The alternative — allowing the gateway's public IP — works too, and breaks the day the
gateway's address changes.

Everything not matching gets **403 Ip Forbidden**, which is exactly what
[chapter 10](10-verification.md) checks for.

### The SCM site has its own rules

```bicep
scmIpSecurityRestrictionsUseMain: false
scmIpSecurityRestrictionsDefaultAction: empty(managementIpAddress) ? 'Allow' : 'Deny'
scmIpSecurityRestrictions: [ { ipAddress: managementIpAddress, action: 'Allow', priority: 100 } ]
```

The Kudu/SCM endpoint (`<app>.scm.azurewebsites.net`) handles deployments and the console.
Sharing the main rules would lock you out of it, because you are not the Application
Gateway. Your operator IP gets in; nothing else does.

### Inbound, prod profile

```bicep
param enableAppPrivateEndpoint bool = false
// ...
publicNetworkAccess: enablePrivateEndpoint ? 'Disabled' : 'Enabled'
```

Set it to `true` and the app leaves the public internet entirely, reachable only through a
private endpoint in `snet-pep`. Strictly better security — and it takes the SCM site with
it. Deployments and the console then require the jumpbox, a VPN, or a self-hosted CI runner
inside the VNet.

That is the correct production choice and a hostile lab default, which is why
[`main.dev.bicepparam`](../infra/main.dev.bicepparam) leaves it `false` and
[`main.prod.bicepparam`](../infra/main.prod.bicepparam) sets it `true` alongside
`deployBastion: true`. Run both and feel the difference.

---

## 4.2 Configuration that holds no secrets

```bicep
var secretAppSettings = empty(databaseSecretUri) ? [] : [
  {
    name: 'DATABASE_URL'
    value: '@Microsoft.KeyVault(SecretUri=${databaseSecretUri})'
  }
]
```

`@Microsoft.KeyVault(SecretUri=…)` is a **Key Vault reference**. The platform resolves it at
startup using the app's managed identity; the app receives the value as an ordinary
environment variable and never learns where it came from.

For this to work, four things must all be true — and every one of them is a chapter:

1. The app has a system-assigned identity — `identity: { type: 'SystemAssigned' }`.
2. That identity holds **Key Vault Secrets User** on the vault — chapter 03, via
   [`rbac.bicep`](../infra/modules/shared/rbac.bicep).
3. The vault is reachable from the app — private endpoint plus private DNS, chapters 02–03.
4. Outbound traffic actually goes through the VNet — `vnetRouteAllEnabled: true`, above.

Break any one and the app starts with an empty setting and a message in the log that names
none of the four. [Troubleshooting](troubleshooting.md#a-key-vault-reference-does-not-resolve)
covers the diagnosis.

### Role assignments live with the resource, not the identity

```bicep
module appRbac 'modules/shared/rbac.bicep' = {
  scope: platformResourceGroup     // where the vault and the account are
  params: {
    principalId: app.outputs.principalId
    keyVaultName: keyVault.outputs.name
    storageAccountName: storage.outputs.name
  }
}
```

Two assignments, each scoped to a single resource:

```bicep
resource keyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, principalId, keyVaultSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
```

Two details worth stealing:

- The name is a **deterministic GUID** derived from scope + principal + role. Redeploying is
  a no-op instead of a conflict.
- `principalType: 'ServicePrincipal'` avoids a race where Entra ID has not yet replicated a
  brand-new managed identity and the assignment fails with `PrincipalNotFound`.

---

## 4.3 The rest of the site configuration

```bicep
httpsOnly: true
siteConfig: {
  linuxFxVersion: 'NODE|20-lts'
  alwaysOn: true
  http20Enabled: true
  minTlsVersion: '1.2'
  scmMinTlsVersion: '1.2'
  ftpsState: 'Disabled'
  healthCheckPath: '/'
}
```

No application code is deployed. An empty Linux app serves App Service's default page with
**200 OK**, which is all the gateway health probe and the WAF tests need. The lab is about
the platform; adding a repository to build would add a CI concern and change nothing about
the network.

`ftpsState: 'Disabled'` closes a legacy publishing path that no one in this architecture
uses and everyone forgets exists.

---

## 4.4 The console that makes verification free

This is the trick that keeps the lab cheap. Open:

```
https://<app-name>.scm.azurewebsites.net/webssh/host
```

You are now in a shell **inside the integrated subnet**, and App Service ships three tools
that answer the questions this architecture raises:

```bash
nameresolver <storage-account>.blob.core.windows.net
```

Expect `10.20.2.x`. A public address means the DNS zone link is missing — go back to
[chapter 02](02-network.md).

```bash
tcpping <postgres-server>.postgres.database.azure.com:5432
```

Expect a connection. From your laptop the same host is unreachable.

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://<vault-name>.vault.azure.net/healthstatus
```

A response at all proves the vault answers over the private endpoint.

Doing the same with a jumpbox costs about USD 0.19/hour for Bastion Basic plus the VM.
Both modules are in the repository for the prod profile, which needs them —
[`bastion.bicep`](../infra/modules/network/bastion.bicep),
[`jumpbox.bicep`](../infra/modules/network/jumpbox.bicep).

> The Bastion **Developer** SKU is free, and useless here: it cannot traverse VNet peering,
> so it cannot reach a spoke from a hub. That limitation is the reason the module defaults
> to Basic.

---

## 4.5 Verify

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://<app>.azurewebsites.net/
```

**403.** The app is up; you are simply not the Application Gateway.

```bash
az webapp config appsettings list --name <app> --resource-group rg-ztwp-app-dev-weu --query "[?name=='DATABASE_URL'].value" -o tsv
```

`@Microsoft.KeyVault(SecretUri=https://…)` — a reference, not a password.

```bash
az webapp config show --name <app> --resource-group rg-ztwp-app-dev-weu --query "{vnetRouteAll:vnetRouteAllEnabled, ftps:ftpsState, tls:minTlsVersion}" -o json
```

```bash
az webapp identity show --name <app> --resource-group rg-ztwp-app-dev-weu --query principalId -o tsv
```

Then confirm that principal really holds the two roles:

```bash
az role assignment list --assignee <principalId> --all --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

---

## Exercises

1. **Remove the access restriction** and redeploy. `curl` the app hostname directly: 200.
   You have just bypassed the WAF entirely — the same request with `?id=1' OR '1'='1` now
   reaches the application. Put it back.

2. **Flip to the private endpoint.** Set `enableAppPrivateEndpoint = true` in the dev
   parameter file and redeploy. The app hostname stops resolving publicly, and so does Kudu.
   Now you need the jumpbox — deploy it and reach the console through Bastion.

3. **Break the Key Vault reference** by removing the `Key Vault Secrets User` assignment.
   Restart the app and read `DATABASE_URL`: empty. Then find the failure in
   `AppServiceConsoleLogs` — chapter 06 has the query.

---

## Checkpoint

- [ ] The app answers 403 on its own hostname and 200 through the gateway
- [ ] `DATABASE_URL` is a Key Vault reference
- [ ] `nameresolver` inside Kudu returns a `10.20.2.x` address for storage
- [ ] The managed identity holds exactly two roles, each on one resource

---

Next: [05 — Edge and WAF](05-edge-waf.md)
