# Troubleshooting

The errors this build actually produces, in the order you are likely to meet them. Every one
of these came up while writing the lab.

---

## Compilation and linting

### `BCP307` / `BCP181` on a private endpoint's IP address

```
BCP307: The expression cannot be evaluated, because the identifier properties of the
referenced existing resource including "name" cannot be calculated at the start of the
deployment.
```

You tried to read the private IP from the NIC a private endpoint created. Both routes are
refused, for the same reason: the NIC is created *by* the endpoint, so nothing about it is
knowable before the deployment runs. Output the NIC's resource ID instead and read the
address afterwards —
[`private-endpoint.bicep`](../infra/modules/shared/private-endpoint.bicep) and
[chapter 10](10-verification.md#103-reading-the-private-ips-from-outside).

### `BCP318` — "may be null at the start of the deployment"

```
BCP318: The value of type "module | null" may be null at the start of the deployment
```

You referenced an output of a conditionally deployed module:

```bicep
databaseHost: deployDatabase ? postgres.outputs.fullyQualifiedDomainName : ''
```

Bicep cannot see that the same flag guards both the module and the reference. Add the
non-null assertion:

```bicep
databaseHost: deployDatabase ? postgres!.outputs.fullyQualifiedDomainName : ''
```

### The linter rejects something that looks fine

Two rules in this repository's [`bicepconfig.json`](../bicepconfig.json) are raised to
`error` and both fire on correct-looking code.

**`outputs-should-not-contain-secrets`**

```
Error outputs-should-not-contain-secrets: Outputs should not contain secrets.
Found possible secret: secure value 'databaseConnectionString'
```

The output only *tested* the secure parameter:

```bicep
output connectionStringSecretUri string = empty(databaseConnectionString) ? '' : '…'
```

The rule does not distinguish testing from returning. Split the switch from the secret — a
separate `createDatabaseSecret bool` parameter — as
[`key-vault.bicep`](../infra/modules/platform/key-vault.bicep) does.

**`secure-secrets-in-params`**

```
Error secure-secrets-in-params: Parameter 'httpsCertificateSecretId' may represent a secret
(according to its name) and must be declared with the '@secure()' attribute.
```

The rule matches on the *name*. A Key Vault certificate URI is an address, not a secret, and
marking it `@secure()` would hide it from what-if output for no benefit. Rename it —
`certificateKeyVaultUri` in
[`application-gateway.bicep`](../infra/modules/edge/application-gateway.bicep).

### `[[parameters('effect')]` in the compiled policy

Not a bug. Bicep escapes a leading `[` so ARM does not evaluate the expression at deployment
time; ARM converts `[[` back to `[` when it writes the policy. The policy engine receives the
expression it should. See [chapter 07](07-governance.md#71-why-the-rules-live-in-json).

### Experimental feature warnings on every build

```
WARNING: The following experimental Bicep features have been enabled: Asserts.
```

Expected. `assertions` and `testFramework` are switched on in
[`bicepconfig.json`](../bicepconfig.json) so [chapter 11](11-testing.md) can run. Remove both
if the noise bothers you more than the tests help.

---

## Deployment

### `RequestDisallowedByPolicy`

```
(RequestDisallowedByPolicy) Resource 'st…' was disallowed by policy.
```

Your own initiative from [chapter 07](07-governance.md) did its job. Read the
`nonComplianceMessages` in the error — it names the rule. If it fires on a *legitimate*
resource, either the resource is wrong or the rule is; deploy with
`policyEnforcementMode = 'DoNotEnforce'` while you decide.

### `RequestDisallowedByAzure` — deny assignment

```
(RequestDisallowedByAzure) Resource '…' was disallowed by a deny assignment.
```

The deployment stack from [chapter 08](08-deployment-stacks.md). Make the change through the
template, or redeploy the stack with `--deny-settings-mode none`, change it, and put the
setting back.

### `az.getSecret` fails with an authorization error

Three causes, in order of likelihood:

1. The bootstrap vault does not have `enabledForTemplateDeployment: true`.
2. The subscription ID, resource group or vault name in the `az.getSecret(…)` call is wrong
   — the error names the vault, not the typo.
3. The identity running the deployment lacks **Key Vault Secrets User** on that vault.

```bash
az keyvault show --name <bootstrap-vault> --query "properties.enabledForTemplateDeployment"
```

### `The global store routingKey … is invalid. It must be a strict and non-default GUID`

The placeholder subscription ID `00000000-0000-0000-0000-000000000000` is still in
[`main.dev.bicepparam`](../infra/main.dev.bicepparam). Run
[`scripts/bootstrap.ps1`](../scripts/bootstrap.ps1) and paste the three values it prints.

### `SubnetMissingRequiredDelegation`

`snet-app` lost its `Microsoft.Web/serverFarms` delegation. Redeploy the network, or:

```bash
az network vnet subnet show --resource-group rg-ztwp-network-dev-weu --vnet-name vnet-ztwp-spoke-dev-weu --name snet-app --query "delegations[].serviceName" -o tsv
```

### `PrivateLinkServiceIdAndGroupIdMismatch`

The `groupId` does not match the service. The correct values are in
[chapter 03](03-platform-services.md#31-one-private-endpoint-module-six-call-sites) —
`vault`, `blob`, `postgresqlServer`, `sites`.

### `SkuNotAvailable` / `ZonalAllocationFailed`

The region cannot supply the SKU or the zones. Either pick another region (change `location`
in [`main.shared.bicepparam`](../infra/main.shared.bicepparam)) or set
`zoneRedundant: false`. Check what is available:

```bash
az vm list-skus --location westeurope --query "[?name=='Standard_B1ms'].locationInfo[].zones" -o tsv
```

### The deployment takes 20 minutes

Normal. Application Gateway alone is five to eight minutes, PostgreSQL another five, and the
private endpoints resolve after both. The gateway is also what makes redeploying expensive
in wall-clock time — during development, comment it out and iterate on the rest.

---

## Runtime

### The gateway backend is unhealthy

The most common failure in the lab, and always one of four things:

```bash
az network application-gateway show-backend-health --name agw-ztwp-dev-weu --resource-group rg-ztwp-app-dev-weu -o json
```

Read the `healthProbeLog`:

| Message contains | Cause | Fix |
|---|---|---|
| `403` | App Service access restriction rejects the gateway subnet | check `ipSecurityRestrictions` names `snet-agw`, and that the subnet has the `Microsoft.Web` service endpoint |
| `404` | the probe sent the wrong `Host` header | `pickHostNameFromBackendHttpSettings: true` on the probe, `pickHostNameFromBackendAddress: true` on the settings |
| timeout / `Unknown` | DNS or NSG | check the private DNS links and that `AllowGatewayManagerInbound` exists on the gateway NSG |
| certificate error | backend TLS name mismatch | the backend must be the App Service default hostname, not a custom name |

### A Key Vault reference does not resolve

`DATABASE_URL` is empty or shows the literal `@Microsoft.KeyVault(...)` string. Four things
must all be true — check them in this order:

```bash
az webapp identity show --name <app> --resource-group rg-ztwp-app-dev-weu --query principalId -o tsv
```

```bash
az role assignment list --assignee <principalId> --all --query "[].roleDefinitionName" -o tsv
```

Expect `Key Vault Secrets User`.

```bash
az webapp config show --name <app> --resource-group rg-ztwp-app-dev-weu --query vnetRouteAllEnabled
```

Expect `true` — without it the app takes the internet path to the vault and misses the
private endpoint.

Then, from the Kudu console:

```bash
nameresolver <vault-name>.vault.azure.net
```

Expect `10.20.2.x`. A public address means the DNS zone link is missing.

Finally: **restart the app**. Key Vault references are resolved at startup, so a role
assignment added afterwards does not take effect until the next start.

```bash
az webapp restart --name <app> --resource-group rg-ztwp-app-dev-weu
```

### `AGWFirewallLogs` does not exist

Either nothing has been blocked yet, or the diagnostic setting is not using resource-specific
tables. Check:

```bash
az monitor diagnostic-settings list --resource <gateway-id> --query "value[].logAnalyticsDestinationType" -o tsv
```

Expect `Dedicated`. On the legacy schema the equivalent query is
`AzureDiagnostics | where Category == "ApplicationGatewayFirewallLog"` — see
[chapter 06](06-observability.md#62-the-one-setting-that-changes-every-query).

Also allow five minutes. Ingestion is not instant.

### The WAF blocks something legitimate

Find the rule, then exclude the specific part of the request rather than disabling the rule:

```kusto
AGWFirewallLogs
| where TimeGenerated > ago(1h)
| where Action == "Blocked"
| summarize count() by RuleId, Message
```

[Chapter 05](05-edge-waf.md#exclusions-with-a-worked-example) has the exclusion syntax.

### Kudu is unreachable

If `enableAppPrivateEndpoint` is `true`, that is the design — the SCM site left the internet
with the app. Use the jumpbox via Bastion, or set the flag back to `false`.

Otherwise your public IP has changed. Update `managementIpAddress` and redeploy:

```bash
curl -s https://api.ipify.org
```

---

## Teardown

### Resources survived the teardown

Check which `--action-on-unmanage` was used. `detachAll` leaves everything running.

```bash
az stack sub show --name ztwp-dev --query "actionOnUnmanage" -o json
```

```bash
az stack sub delete --name ztwp-dev --action-on-unmanage deleteAll --yes
```

### A Key Vault name cannot be reused

Soft delete holds the name. This repository sets `softDeleteRetentionInDays: 7` and does not
enable purge protection precisely so the name can be recovered:

```bash
az keyvault list-deleted --query "[].name" -o tsv
```

```bash
az keyvault purge --name <vault-name>
```

### The bootstrap group is still there

Intended. It is not managed by the stack and holds the database password, so the next
deployment reuses it. Remove it explicitly when you are finished with the lab for good:

```bash
az group delete --name rg-ztwp-bootstrap-dev-weu --yes
```

---

## Still stuck

```bash
az deployment sub list --query "[0].{name:name, state:properties.provisioningState, timestamp:properties.timestamp}" -o json
```

```bash
az deployment operation sub list --name <deployment-name> --query "[?properties.provisioningState=='Failed'].{resource:properties.targetResource.resourceName, code:properties.statusMessage.error.code, message:properties.statusMessage.error.message}" -o json
```

The second command is the one worth remembering: it prints the *actual* failure, rather than
the "at least one resource deployment operation failed" wrapper the portal shows.
