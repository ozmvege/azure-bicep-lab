# 03 — Platform services: Key Vault, Storage, PostgreSQL

> Three stateful services, six private endpoints, and one reusable module that creates all
> of them. Plus the switch that turns "we use managed identity" from a claim into a property
> of the system.

**Time:** 45 minutes · **Cost:** ~USD 0.02/hour (PostgreSQL B1ms + endpoints)

**Files:** [`key-vault.bicep`](../infra/modules/platform/key-vault.bicep) ·
[`storage.bicep`](../infra/modules/platform/storage.bicep) ·
[`postgresql.bicep`](../infra/modules/platform/postgresql.bicep) ·
[`private-endpoint.bicep`](../infra/modules/shared/private-endpoint.bicep)

---

## 3.1 One private endpoint module, six call sites

A private endpoint is always the same three things: a NIC in a subnet, a connection to a
service with a **group ID**, and a DNS zone group that writes the A record. Only the group
ID and the zone change, so there is one module:

```bicep
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: '${name}-connection'
        properties: {
          privateLinkServiceId: serviceId
          groupIds: [ groupId ]
        }
      }
    ]
  }

  resource dnsZoneGroup 'privateDnsZoneGroups@2024-05-01' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: replace(split(dnsZoneId, '/')[8], '.', '-')
          properties: { privateDnsZoneId: dnsZoneId }
        }
      ]
    }
  }
}
```

The group IDs used in this lab:

| Service | `groupId` | Zone |
|---|---|---|
| Key Vault | `vault` | `privatelink.vaultcore.azure.net` |
| Storage (blob) | `blob` | `privatelink.blob.core.windows.net` |
| PostgreSQL Flexible | `postgresqlServer` | `privatelink.postgres.database.azure.com` |
| App Service | `sites` | `privatelink.azurewebsites.net` |

A wrong group ID fails at deployment with `PrivateLinkServiceIdAndGroupIdMismatch`, which is
one of the friendlier errors in this lab.

**The DNS zone group is not optional.** Without it the endpoint exists, the NIC has an
address, and the hostname still resolves publicly. See
[chapter 02](02-network.md#24-private-dns-the-part-everyone-skips).

### A small Bicep lesson hiding in the outputs

The obvious output for this module is the private IP. It cannot be produced:

```bicep
// BCP307 — the NIC's name is not known at the start of the deployment
resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' existing = {
  name: last(split(privateEndpoint.properties.networkInterfaces[0].id, '/'))
}

// BCP181 — reference() needs an argument computable at the start of the deployment
output ip string = reference(privateEndpoint.properties.networkInterfaces[0].id, '2024-05-01')…
```

Both are refused at compile time, for the same underlying reason: the NIC is created *by*
the endpoint, so nothing about it is knowable before the deployment runs. The module outputs
the NIC's resource ID instead, and the verification chapter reads the address afterwards:

```bash
az network nic show --ids <nicId> --query "ipConfigurations[0].properties.privateIPAddress" -o tsv
```

---

## 3.2 Storage: remove the credential, do not protect it

Four properties decide whether "private" means anything:

```bicep
properties: {
  publicNetworkAccess: 'Disabled'   // not on the internet at all
  allowBlobPublicAccess: false      // no container can ever be anonymous
  allowSharedKeyAccess: false       // account keys stop working
  minimumTlsVersion: 'TLS1_2'       // old clients fail instead of downgrading
}
```

The third is the interesting one. Every leaked-storage story starts with a key in a config
file, a notebook or a CI log. `allowSharedKeyAccess: false` deletes the category: there is
no key to leak, and every client — including your own CLI — must authenticate with Entra ID.

Practically, that means:

```bash
az storage blob list --account-name <account> --container-name app-data --auth-mode login
```

Leave off `--auth-mode login` and the CLI tries a key that no longer works.

```bicep
defaultToOAuthAuthentication: true
networkAcls: {
  defaultAction: 'Deny'
  bypass: 'AzureServices'
}
```

`bypass: AzureServices` is what still allows the ARM resource provider to create the
container inside an account it has just closed off.

### Diagnostics hang off the blob service, not the account

```bicep
resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: storageAccount::blobService
  properties: {
    logs: [ { categoryGroup: 'audit', enabled: true } ]
  }
}
```

A diagnostic setting on the account alone gives metrics and no read/write/delete trail. The
`::` syntax addresses the nested `blobServices/default` resource declared inside the account.

---

## 3.3 PostgreSQL: two networking models, pick one forever

Flexible Server offers **VNet injection** (a delegated subnet) and **private endpoint**, and
they are mutually exclusive from the moment the server is created. This lab uses the second:

```bicep
network: {
  // No delegatedSubnetResourceId and no firewall rules: the server has no public
  // surface, and the private endpoint is the only route to port 5432.
  publicNetworkAccess: 'Disabled'
}
```

Why: VNet injection binds the server to one VNet for its whole life, while a private
endpoint is the same model as every other service here and can be extended to a second VNet
later. The cost is one more endpoint, about USD 0.01 an hour.

Entra ID authentication is enabled alongside password authentication:

```bicep
authConfig: {
  activeDirectoryAuth: 'Enabled'
  passwordAuth: 'Enabled'
  tenantId: tenant().tenantId
}
```

The connection string still uses the password, because a lab that also has to explain OAuth
token acquisition stops being a lab about networking. Set `entraAdminObjectId` to make
yourself Entra administrator and the passwordless path is one `psql` flag away.

High availability is conditional on the tier, because Burstable cannot do it:

```bicep
highAvailability: {
  mode: tier == 'Burstable' ? 'Disabled' : 'ZoneRedundant'
}
```

That single line is why the prod profile moves to `GeneralPurpose` — not because the lab
needs more CPU.

---

## 3.4 Key Vault: two switches that look wrong until they don't

```bicep
enableRbacAuthorization: true
enabledForTemplateDeployment: true
publicNetworkAccess: 'Enabled'
networkAcls: {
  defaultAction: 'Deny'
  bypass: 'AzureServices'
  ipRules: empty(managementIpAddress) ? [] : [ { value: managementIpAddress } ]
}
```

`publicNetworkAccess: 'Enabled'` on a vault in a zero-trust lab reads like a mistake. It is
not, and the reason is worth understanding:

- The **network ACL** is what enforces reachability. `defaultAction: Deny` with a single IP
  rule means: your workstation and nothing else, plus whatever arrives over the private
  endpoint.
- `bypass: AzureServices` together with `enabledForTemplateDeployment: true` is what lets
  the ARM resource provider write the secrets this template creates. Set
  `publicNetworkAccess: 'Disabled'` and the deployment fails while creating a secret in a
  vault it built seconds earlier.

This is also why [chapter 07](07-governance.md) writes a **custom** policy: a built-in
policy demanding `publicNetworkAccess: Disabled` on every vault would reject this platform.

Purge protection is deliberately **not** enabled. On a production vault it should be; in a
lab it turns every teardown into a 90-day name reservation.

### Composing the secret without ever holding it

```bicep
var connectionString = 'postgresql://${databaseUser}:${databasePassword}@${databaseHost}:5432/${databaseName}?sslmode=require'
```

That line lives inside the Key Vault module, not in `main.bicep`, so no variable outside
this module ever holds the password. `main.bicep` passes the secure parameter straight
through:

```bicep
databasePassword: postgresAdministratorPassword
databaseHost: deployDatabase ? postgres!.outputs.fullyQualifiedDomainName : ''
```

The `!` is a promise to the compiler that this branch only runs when the module was
deployed. Without it Bicep raises **BCP318** on every conditional module output, because it
cannot see that the same flag guards both the module and the reference.

### The linter rule that shapes the module's interface

```bicep
@secure()
param databasePassword string = ''

@description('Whether to write that secret. This looks redundant, and it is not.')
param createDatabaseSecret bool = false
```

Two parameters for one decision, because `outputs-should-not-contain-secrets` fires on any
output expression that so much as *tests* a secure value — including `empty()`. The first
attempt was:

```bicep
output connectionStringSecretUri string = empty(databaseConnectionString) ? '' : '…'
//                                        ^ rejected: "Found possible secret"
```

Splitting the switch from the secret is what lets the module hand back the secret URI at
all. Full error in [troubleshooting](troubleshooting.md#the-linter-rejects-something-that-looks-fine).

---

## 3.5 Verify

```bash
az storage account show --name <account> --query "{public:publicNetworkAccess, sharedKey:allowSharedKeyAccess, blobPublic:allowBlobPublicAccess, tls:minimumTlsVersion}" -o json
```

Expected: `Disabled`, `false`, `false`, `TLS1_2`.

```bash
az storage blob list --account-name <account> --container-name app-data --auth-mode login
```

Expected: a network failure. You are outside the VNet, and that is the design working.

```bash
az postgres flexible-server show --name <server> --resource-group rg-ztwp-platform-dev-weu --query "network" -o json
```

Expected: `publicNetworkAccess: Disabled`, no delegated subnet.

```bash
az network private-endpoint list --resource-group rg-ztwp-platform-dev-weu --query "[].{name:name, group:privateLinkServiceConnections[0].groupIds[0]}" -o table
```

Expected: three endpoints — `vault`, `blob`, `postgresqlServer`.

---

## Exercises

1. **Try to break the DNS zone group.** Delete it from the Key Vault endpoint and run
   `nameresolver` from the Kudu console (chapter 04). The vault hostname resolves to a
   public IP again while the endpoint still exists and looks healthy in the portal.

2. **Turn shared keys back on** in [`storage.bicep`](../infra/modules/platform/storage.bicep),
   redeploy, and run `az storage account keys list`. Then notice that
   [chapter 07](07-governance.md)'s policy has nothing to say about it — and write the extra
   rule that would.

3. **Add a second container** through the module rather than the portal, and note that the
   deployment stack in [chapter 08](08-deployment-stacks.md) is what makes the difference
   between those two routes permanent.

---

## Checkpoint

- [ ] Three private endpoints, each with a DNS zone group
- [ ] Storage rejects your CLI from outside the VNet
- [ ] `allowSharedKeyAccess` is `false`
- [ ] PostgreSQL has no public network access and no delegated subnet
- [ ] You can explain why the Key Vault keeps `publicNetworkAccess: Enabled`

---

Next: [04 — Compute](04-compute.md)
