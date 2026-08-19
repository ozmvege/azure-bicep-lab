# 12 — Azure Verified Modules: swap one and compare

> Everything so far was hand-written, which is right for learning and wrong for production.
> This chapter replaces one module with the Microsoft-maintained equivalent and looks at
> what changes.

**Time:** 30 minutes · **Cost:** none beyond a redeploy

---

## 12.1 What AVM is

Azure Verified Modules are Microsoft's official Bicep (and Terraform) module library:
maintained, versioned, tested against the Well-Architected Framework, and published to the
Microsoft Container Registry. They come in two shapes:

| Kind | Path | Scope |
|---|---|---|
| Resource module | `br/public:avm/res/<provider>/<resource>:<version>` | one resource type and its children |
| Pattern module | `br/public:avm/ptn/<area>/<pattern>:<version>` | an architecture composed of several |

Find and pin versions from the registry itself:

```bash
curl -s https://mcr.microsoft.com/v2/bicep/avm/res/storage/storage-account/tags/list | python -m json.tool
```

At the time of writing the latest is **0.33.0**. Always check — AVM moves quickly, and a
version is a contract you should choose deliberately rather than inherit.

The registry alias is already configured in [`bicepconfig.json`](../bicepconfig.json):

```json
"moduleAliases": {
  "br": { "avm": { "registry": "mcr.microsoft.com", "modulePath": "bicep/avm/res" } }
}
```

so `br/public:avm/res/storage/storage-account:0.33.0` and `br:avm/storage/storage-account:0.33.0`
both work.

---

## 12.2 The swap

Replace the `storage` module in [`main.bicep`](../infra/main.bicep):

```bicep
module storage 'modules/platform/storage.bicep' = {
  scope: platformResourceGroup
  name: 'platform-storage'
  params: {
    name: globalName('st', workload, environment, subscription().id)
    location: location
    tags: tags
    privateEndpointSubnetId: spoke.outputs.privateEndpointSubnetId
    privateDnsZoneId: privateDnsZones[blobZoneIndex].outputs.id
    workspaceId: monitoring.outputs.id
  }
}
```

with:

```bicep
module storage 'br/public:avm/res/storage/storage-account:0.33.0' = {
  scope: platformResourceGroup
  name: 'platform-storage'
  params: {
    name: globalName('st', workload, environment, subscription().id)
    location: location
    tags: tags
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    blobServices: {
      containers: [ { name: 'app-data' } ]
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: 7
    }
    privateEndpoints: [
      {
        service: 'blob'
        subnetResourceId: spoke.outputs.privateEndpointSubnetId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [ { privateDnsZoneResourceId: privateDnsZones[blobZoneIndex].outputs.id } ]
        }
      }
    ]
    diagnosticSettings: [
      { workspaceResourceId: monitoring.outputs.id }
    ]
  }
}
```

The consuming code changes too — AVM's output names are standardised and differ from the
hand-written module's:

| Hand-written | AVM |
|---|---|
| `storage.outputs.name` | `storage.outputs.name` |
| `storage.outputs.blobEndpoint` | `storage.outputs.serviceEndpoints.blob` |
| `storage.outputs.containerName` | *(not exposed — keep the literal)* |

Restore the registry cache and compile:

```bash
az bicep restore --file infra/main.bicep --force
```

```bash
az bicep build --file infra/main.bicep --stdout > /dev/null
```

Then diff against Azure:

```bash
az deployment sub what-if --location westeurope --template-file infra/main.bicep --parameters infra/main.dev.bicepparam --exclude-change-types Ignore NoChange
```

---

## 12.3 What the diff shows

The AVM module produces more than the hand-written one, and that is the point. Expect to see
additions such as:

- a customer-managed key scaffold and identity plumbing left inert
- `supportsHttpsTrafficOnly`, `allowCrossTenantReplication` and other properties set to
  their recommended values explicitly rather than by default
- richer diagnostic settings, including metrics categories the hand-written module skipped
- an interface for RBAC assignments, private endpoints and locks that is identical across
  every AVM module

That last one is the real value. Once you know AVM's `privateEndpoints` and
`diagnosticSettings` parameter shapes, you know them for Key Vault, for PostgreSQL, for
everything — instead of learning three slightly different hand-written conventions.

---

## 12.4 When to use which

**Reach for AVM when** you are building something real, you want other people to review it
against a known standard, you need coverage of properties you have not thought about yet, or
you want the Well-Architected defaults without arguing about them.

**Write it yourself when** you are learning — an AVM call teaches its own parameter schema
and nothing about `pickHostNameFromBackendHttpSettings` or why a DNS zone group matters —
when the module is a thin wrapper over one resource with three properties, or when you need
behaviour AVM deliberately does not have.

**The honest position on this repository:** in production it would use AVM for storage, Key
Vault, Log Analytics and the VNets, and keep hand-written modules for the Application Gateway
and the App Service, where the configuration *is* the architecture. It is hand-written
throughout here because a lab where the interesting parts happen inside someone else's module
teaches parameter passing.

---

## 12.5 Version pinning is not optional

```bicep
module storage 'br/public:avm/res/storage/storage-account:0.33.0' = {
```

There is no `latest` tag, and that is deliberate. A floating version means a build that
passed yesterday can fail today for reasons nobody changed. Pin, and upgrade on purpose:

```bash
curl -s https://mcr.microsoft.com/v2/bicep/avm/res/storage/storage-account/tags/list | python -m json.tool
```

```bash
az deployment sub what-if --location westeurope --template-file infra/main.bicep --parameters infra/main.dev.bicepparam
```

Read the diff before merging the bump. AVM modules are pre-1.0 and minor versions do change
behaviour.

---

## Exercises

1. **Do the swap**, run what-if, and write down three properties AVM sets that the
   hand-written module did not. Decide for each whether you want it.

2. **Swap the Key Vault too** — `br/public:avm/res/key-vault/vault` — and discover the
   conflict with [chapter 03](03-platform-services.md#34-key-vault-two-switches-that-look-wrong-until-they-dont):
   AVM's defaults lean toward `publicNetworkAccess: Disabled`, which breaks secret creation
   during deployment. Work out which parameter restores it.

3. **Look at a pattern module.** `br/public:avm/ptn/…` contains whole architectures. Find one
   close to this platform and compare its decisions with the ones in
   [chapter 00](00-architecture.md).

4. **Revert.** Put the hand-written module back and confirm what-if reports no change to the
   properties that matter. Being able to move between the two is the skill worth having.

---

## Checkpoint

- [ ] The AVM version is pinned, and you know how to find the current one
- [ ] `az bicep restore` succeeds and the template compiles against the registry
- [ ] You can name three differences the swap introduced
- [ ] You have an opinion on which modules in this repository should be AVM

---

Back to the [README](../README.md) · or on to
[troubleshooting](troubleshooting.md) and [cost and cleanup](cost-and-cleanup.md).
