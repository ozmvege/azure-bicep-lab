# 02 — Network: hub, spoke, and the DNS that makes "private" true

> Two VNets, peered in both directions, six subnets with a written-down purpose each, and
> four private DNS zones. The DNS is the part that decides whether the rest of this lab is
> real or theatre.

**Time:** 45 minutes · **Cost:** VNets, subnets, NSGs and DNS zones are free; peering is
charged per GB and rounds to zero here

**Files:** [`hub.bicep`](../infra/modules/network/hub.bicep) ·
[`spoke.bicep`](../infra/modules/network/spoke.bicep) ·
[`peering.bicep`](../infra/modules/network/peering.bicep) ·
[`private-dns-zone.bicep`](../infra/modules/network/private-dns-zone.bicep) ·
[`nsg.bicep`](../infra/modules/network/nsg.bicep)

---

## 2.1 The address plan

The whole plan is one typed object, so a reviewer sees the entire allocation on one screen:

```bicep
param addressing addressPlan = {
  hubVnet: '10.10.0.0/16'
  bastionSubnet: '10.10.0.0/26'
  jumpboxSubnet: '10.10.1.0/24'
  spokeVnet: '10.20.0.0/16'
  applicationGatewaySubnet: '10.20.0.0/24'
  appServiceSubnet: '10.20.1.0/24'
  privateEndpointSubnet: '10.20.2.0/24'
}
```

The type behind it is in [`types.bicep`](../infra/types.bicep), and each field carries the
constraint that matters:

```bicep
type addressPlan = {
  @description('Azure Bastion requires a subnet named AzureBastionSubnet of at least /26.')
  bastionSubnet: string
  @description('Application Gateway needs a dedicated subnet; nothing else may live in it.')
  applicationGatewaySubnet: string
  @description('Delegated to Microsoft.Web/serverFarms for App Service VNet integration.')
  appServiceSubnet: string
  // ...
}
```

Two rules are non-negotiable and both are enforced by Azure, not by the template:

- The Bastion subnet must be **named** `AzureBastionSubnet` and be **/26 or larger**.
- The Application Gateway subnet must contain **nothing but the gateway**.

### Subnets that exist before they are needed

The hub creates `AzureBastionSubnet` and `snet-jumpbox` even when neither Bastion nor a
jumpbox is deployed. Subnets are free, and carving one out of a VNet that is already peered
and populated is a change nobody enjoys making later. A stable address plan is worth more
than a minimal one.

---

## 2.2 NSGs: writing down what is allowed

Every subnet gets an NSG, including the ones whose Azure defaults would already be
sufficient. The reason is auditability — a reviewer should read the allowed paths out of the
template rather than reconstructing them from implicit defaults.

The Application Gateway rules include one that surprises people:

```bicep
{
  name: 'AllowGatewayManagerInbound'
  properties: {
    priority: 100
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: 'GatewayManager'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '65200-65535'
  }
}
```

That is Azure's control plane talking to your gateway instances, not user traffic. Omit it
and the gateway deploys, then reports an unhealthy control plane and stops accepting
configuration changes. `GatewayManager` is a **service tag** — a named set of Microsoft IP
ranges that Azure keeps current, so the rule never needs maintaining.

Azure Bastion has its own mandatory rule set — four inbound, four outbound — spelled out in
[`hub.bicep`](../infra/modules/network/hub.bicep). Bastion refuses to deploy without them
and the error names the NSG rather than the missing rule.

### The NSG that does not do what it looks like it does

`snet-pep` carries an NSG with a deny-all rule, and that NSG does **not** filter traffic to
the private endpoints in it:

```bicep
{
  name: privateEndpointSubnetName
  properties: {
    addressPrefix: privateEndpointSubnetPrefix
    networkSecurityGroup: { id: privateEndpointNsg.outputs.id }
    privateEndpointNetworkPolicies: 'Disabled'
  }
}
```

`privateEndpointNetworkPolicies: 'Disabled'` is what lets private endpoints be created here
without argument — and the same switch is what exempts the endpoint NICs from NSG
evaluation. Set it to `Enabled` and the NSG applies to them, at which point the deny-all
rule blocks your own application.

This is worth internalising: **a private endpoint subnet with an NSG is not automatically a
filtered subnet.** Chapter 10 has you test it.

---

## 2.3 Peering is two resources

```bicep
module hubToSpokePeering 'modules/network/peering.bicep' = {
  scope: networkResourceGroup
  name: 'peering-hub-to-spoke'
  params: {
    localVnetName: hub.outputs.name
    remoteVnetId: spoke.outputs.id
    peeringName: 'peer-hub-to-spoke'
  }
}

module spokeToHubPeering 'modules/network/peering.bicep' = {
  // ... the same module, the other way round
}
```

A peering is directional and lives in the resource group of its own VNet. One direction
alone produces a peering stuck in `Initiated` instead of `Connected` — traffic goes nowhere
and nothing errors. The same module deployed twice is also what allows the hub to move to a
different subscription later without the template changing shape.

---

## 2.4 Private DNS: the part everyone skips

A private endpoint gives a service a private IP. It does **not** change what the service's
hostname resolves to. Without a private DNS zone, `myvault.vault.azure.net` keeps resolving
to a public address, your traffic keeps going out to the internet, and the endpoint you paid
for sits idle. The architecture looks correct in the portal and is not.

Four zones, one per service:

```bicep
var privateDnsZoneNames = [
  'privatelink.vaultcore.azure.net'
  'privatelink.blob.${az.environment().suffixes.storage}'
  'privatelink.postgres.database.azure.com'
  'privatelink.azurewebsites.net'
]
```

The blob zone is built from `az.environment().suffixes.storage` rather than typed as
`core.windows.net`. That is the `no-hardcoded-env-urls` linter rule, raised to `error` in
[`bicepconfig.json`](../bicepconfig.json), and it is what makes the template work unchanged
in Azure Government or Azure China.

Each zone is linked to **both** VNets:

```bicep
resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (vnetId, index) in linkedVnetIds: {
    parent: zone
    name: 'link-${last(split(vnetId, '/'))}'
    properties: {
      virtualNetwork: { id: vnetId }
      registrationEnabled: false
    }
  }
]
```

Both, because the gateway resolves the app's hostname from the spoke and a jumpbox resolves
the database's hostname from the hub. `registrationEnabled: false` because auto-registration
writes A records for VMs; private endpoints write their own through the DNS zone group.

### How the resolution actually works

1. Something in the VNet asks for `kvztwpdev1234.vault.azure.net`.
2. Azure's public DNS answers with a CNAME to `kvztwpdev1234.privatelink.vaultcore.azure.net`.
3. The private zone is linked to this VNet, so that name resolves inside it — to the A
   record the private endpoint's DNS zone group wrote.
4. The answer is `10.20.2.x`.

Step 3 is the one that fails silently. From outside the VNet the same lookup returns a
public IP, and that is correct — the difference is the whole point.

---

## 2.5 Deploy just the network

Nothing so far costs money, so deploy the network on its own first:

```bash
az deployment sub what-if --location westeurope --template-file infra/main.bicep --parameters infra/main.dev.bicepparam --exclude-change-types Ignore NoChange
```

Read the output. It should create three resource groups, two VNets, six subnets, six NSGs
and four DNS zones with eight links, plus everything from later chapters. Nothing should be
marked `Delete`.

---

## 2.6 Verify

```bash
az network vnet peering list --resource-group rg-ztwp-network-dev-weu --vnet-name vnet-ztwp-hub-dev-weu --query "[].{name:name, state:peeringState}" -o table
```

`Connected`, not `Initiated`. If it says `Initiated`, only one direction was created.

```bash
az network private-dns link vnet list --resource-group rg-ztwp-network-dev-weu --zone-name privatelink.vaultcore.azure.net -o table
```

Two links per zone, eight in total.

```bash
az network vnet subnet show --resource-group rg-ztwp-network-dev-weu --vnet-name vnet-ztwp-spoke-dev-weu --name snet-app --query "delegations[].serviceName" -o tsv
```

`Microsoft.Web/serverFarms`. Without this, App Service integration fails later with an error
that blames the app rather than the subnet.

---

## Exercises

1. **Break the DNS on purpose.** Delete the VNet link on
   `privatelink.vaultcore.azure.net` for the spoke, then run `nameresolver` from the Kudu
   console (chapter 04) against the vault hostname. You get a public IP. Redeploy to restore
   it. Nothing else in the platform changes, and nothing errors — which is exactly what
   makes this failure mode dangerous.

2. **Make the PE NSG real.** Set `privateEndpointNetworkPolicies` to `Enabled` in
   [`spoke.bicep`](../infra/modules/network/spoke.bicep), redeploy, and watch the app lose
   access to Key Vault because the deny-all rule now applies. Then write the allow rule that
   fixes it.

3. **Add a fourth subnet** for a future Azure Firewall (`AzureFirewallSubnet`, /26) in the
   hub. Note that it has to come out of the existing `10.10.0.0/16` without overlapping —
   this is why the address plan is a typed object and not seven loose strings.

---

## Checkpoint

- [ ] Both peerings report `Connected`
- [ ] Four zones, eight VNet links
- [ ] `snet-app` is delegated to `Microsoft.Web/serverFarms`
- [ ] `snet-agw` has the `Microsoft.Web` service endpoint (chapter 04 depends on it)
- [ ] You can explain why `snet-pep`'s NSG does not filter the endpoints in it

---

Next: [03 — Platform services](03-platform-services.md)
