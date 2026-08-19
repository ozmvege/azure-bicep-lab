targetScope = 'subscription'

metadata description = '''
Zero-trust web platform — orchestrator.

Deployed at subscription scope because it creates the resource groups it then fills. The
three groups are drawn along lifecycle lines rather than by resource type:

  rg-<w>-network-<env>    hub and spoke VNets, peerings, private DNS, Bastion, jumpbox
  rg-<w>-platform-<env>   Log Analytics, Key Vault, Storage, PostgreSQL
  rg-<w>-app-<env>        App Service plan and site, WAF policy, Application Gateway

Nothing in here declares a resource directly. Every resource comes from a module, every
module gets a typed parameter object, and the orchestrator's only job is deciding what
depends on what.

Prerequisites and the full walkthrough: docs/01-toolchain.md.
'''

import { environmentName, tagSet, addressPlan, skuProfile, wafMode } from 'types.bicep'
import { resourceName, globalName, dnsLabel } from 'naming.bicep'

// ---------------------------------------------------------------------------------------
// Identity of the deployment
// ---------------------------------------------------------------------------------------

@description('Short workload identifier. Appears in every resource name.')
@minLength(3)
@maxLength(10)
param workload string = 'ztwp'

param environment environmentName = 'dev'

@description('Everything lands in one region. Multi-region is a different lab.')
param location string = deployment().location

param costCentre string = 'lab'

// ---------------------------------------------------------------------------------------
// Network plan
// ---------------------------------------------------------------------------------------

@description('The complete IP plan. Overridable per environment, but the defaults do not overlap with anything RFC 1918 that a home network is likely to use.')
param addressing addressPlan = {
  hubVnet: '10.10.0.0/16'
  bastionSubnet: '10.10.0.0/26'
  jumpboxSubnet: '10.10.1.0/24'
  spokeVnet: '10.20.0.0/16'
  applicationGatewaySubnet: '10.20.0.0/24'
  appServiceSubnet: '10.20.1.0/24'
  privateEndpointSubnet: '10.20.2.0/24'
}

// ---------------------------------------------------------------------------------------
// Size and cost
// ---------------------------------------------------------------------------------------

@description('SKU profile for this environment. The dev profile is chosen so a full run costs about a euro.')
param skus skuProfile = {
  appServicePlan: 'B1'
  applicationGateway: 'WAF_v2'
  gatewayCapacity: 1
  gatewayMaxCapacity: 2
  postgresSku: 'Standard_B1ms'
  postgresTier: 'Burstable'
  postgresStorageGb: 32
  zoneRedundant: false
  logRetentionDays: 30
}

// ---------------------------------------------------------------------------------------
// Switches
// ---------------------------------------------------------------------------------------

@description('Detection logs and allows; Prevention blocks. Chapter 05 has you run both.')
param wafPolicyMode wafMode = 'Prevention'

@description('Take the App Service off the public internet entirely and reach it through a private endpoint. Also removes Kudu from the internet — see docs/04-compute.md.')
param enableAppPrivateEndpoint bool = false

@description('PostgreSQL is the most expensive optional component after the gateway.')
param deployDatabase bool = true

@description('Bastion is roughly EUR 0.19/hour on top of everything else.')
param deployBastion bool = false

@description('Requires deployBastion and an SSH public key.')
param deployJumpbox bool = false

@description('Contents of ~/.ssh/id_ed25519.pub. Not a secret — the private half never leaves the operator machine.')
param jumpboxSshPublicKey string = ''

@description('Policy assignments with a Deny effect. Set to DoNotEnforce to evaluate without blocking.')
param policyEnforcementMode 'Default' | 'DoNotEnforce' = 'Default'

// ---------------------------------------------------------------------------------------
// Operator context
// ---------------------------------------------------------------------------------------

@description('Operator public IP in CIDR form, e.g. 203.0.113.4/32. Grants Key Vault data-plane access and Kudu access, nothing else. Find it with: curl -s https://api.ipify.org')
param managementIpAddress string = ''

@description('Recipient for the two alerts. Empty deploys neither alert nor action group.')
param alertEmail string = ''

@description('Read from the bootstrap vault by main.<env>.bicepparam. Never typed, never committed.')
@secure()
param postgresAdministratorPassword string = ''

@description('Object ID of a user or group to make PostgreSQL Entra administrator. Optional.')
param entraAdminObjectId string = ''

param entraAdminName string = ''

// ---------------------------------------------------------------------------------------
// Derived values
// ---------------------------------------------------------------------------------------

var tags tagSet = {
  workload: workload
  environment: environment
  managedBy: 'bicep'
  costCentre: costCentre
}

var privateDnsZoneNames = [
  'privatelink.vaultcore.azure.net'
  'privatelink.blob.${az.environment().suffixes.storage}'
  'privatelink.postgres.database.azure.com'
  'privatelink.azurewebsites.net'
]

var vaultZoneIndex = 0
var blobZoneIndex = 1
var postgresZoneIndex = 2
var sitesZoneIndex = 3

// ---------------------------------------------------------------------------------------
// Resource groups
// ---------------------------------------------------------------------------------------

resource networkResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceName('rg', workload, 'network', environment, location)
  location: location
  tags: tags
}

resource platformResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceName('rg', workload, 'platform', environment, location)
  location: location
  tags: tags
}

resource appResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceName('rg', workload, 'app', environment, location)
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------------------

module hub 'modules/network/hub.bicep' = {
  scope: networkResourceGroup
  name: 'network-hub'
  params: {
    name: resourceName('vnet', workload, 'hub', environment, location)
    location: location
    tags: tags
    addressPrefix: addressing.hubVnet
    bastionSubnetPrefix: addressing.bastionSubnet
    jumpboxSubnetPrefix: addressing.jumpboxSubnet
  }
}

module spoke 'modules/network/spoke.bicep' = {
  scope: networkResourceGroup
  name: 'network-spoke'
  params: {
    name: resourceName('vnet', workload, 'spoke', environment, location)
    location: location
    tags: tags
    addressPrefix: addressing.spokeVnet
    applicationGatewaySubnetPrefix: addressing.applicationGatewaySubnet
    appServiceSubnetPrefix: addressing.appServiceSubnet
    privateEndpointSubnetPrefix: addressing.privateEndpointSubnet
  }
}

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
  scope: networkResourceGroup
  name: 'peering-spoke-to-hub'
  params: {
    localVnetName: spoke.outputs.name
    remoteVnetId: hub.outputs.id
    peeringName: 'peer-spoke-to-hub'
  }
}

// One zone per service, each linked to both VNets. The indexes above are how the platform
// modules find the zone they need; a lookup object built with toObject() would read better
// but cannot be built from module outputs.
module privateDnsZones 'modules/network/private-dns-zone.bicep' = [
  for zoneName in privateDnsZoneNames: {
    scope: networkResourceGroup
    name: 'dns-${replace(zoneName, '.', '-')}'
    params: {
      zoneName: zoneName
      tags: tags
      linkedVnetIds: [
        hub.outputs.id
        spoke.outputs.id
      ]
    }
  }
]

module bastion 'modules/network/bastion.bicep' = if (deployBastion) {
  scope: networkResourceGroup
  name: 'network-bastion'
  params: {
    name: resourceName('bas', workload, '', environment, location)
    location: location
    tags: tags
    subnetId: hub.outputs.bastionSubnetId
    sku: 'Basic'
  }
}

module jumpbox 'modules/network/jumpbox.bicep' = if (deployJumpbox && !empty(jumpboxSshPublicKey)) {
  scope: networkResourceGroup
  name: 'network-jumpbox'
  params: {
    name: resourceName('vm', workload, 'jump', environment, location)
    location: location
    tags: tags
    subnetId: hub.outputs.jumpboxSubnetId
    sshPublicKey: jumpboxSshPublicKey
  }
}

// ---------------------------------------------------------------------------------------
// Platform services
// ---------------------------------------------------------------------------------------

module monitoring 'modules/observability/monitoring.bicep' = {
  scope: platformResourceGroup
  name: 'platform-monitoring'
  params: {
    name: resourceName('log', workload, '', environment, location)
    location: location
    tags: tags
    retentionInDays: skus.logRetentionDays
  }
}

module postgres 'modules/platform/postgresql.bicep' = if (deployDatabase) {
  scope: platformResourceGroup
  name: 'platform-postgres'
  params: {
    name: resourceName('psql', workload, '', environment, location)
    location: location
    tags: tags
    privateEndpointSubnetId: spoke.outputs.privateEndpointSubnetId
    privateDnsZoneId: privateDnsZones[postgresZoneIndex].outputs.id
    skuName: skus.postgresSku
    tier: skus.postgresTier
    storageSizeGb: skus.postgresStorageGb
    administratorPassword: postgresAdministratorPassword
    entraAdminObjectId: entraAdminObjectId
    entraAdminName: entraAdminName
    workspaceId: monitoring.outputs.id
  }
}

module keyVault 'modules/platform/key-vault.bicep' = {
  scope: platformResourceGroup
  name: 'platform-key-vault'
  params: {
    name: globalName('kv', workload, environment, subscription().id)
    location: location
    tags: tags
    privateEndpointSubnetId: spoke.outputs.privateEndpointSubnetId
    privateDnsZoneId: privateDnsZones[vaultZoneIndex].outputs.id
    managementIpAddress: managementIpAddress
    workspaceId: monitoring.outputs.id
    createDatabaseSecret: deployDatabase
    databasePassword: postgresAdministratorPassword
    // The ! is a promise to the compiler that this branch only runs when the module was
    // deployed. Without it Bicep raises BCP318 on every conditional module output, because
    // it cannot see that the same flag guards both the module and the reference.
    databaseHost: deployDatabase ? postgres!.outputs.fullyQualifiedDomainName : ''
    databaseUser: deployDatabase ? postgres!.outputs.administratorLogin : ''
    databaseName: deployDatabase ? postgres!.outputs.databaseName : ''
  }
}

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

// ---------------------------------------------------------------------------------------
// Application
// ---------------------------------------------------------------------------------------

module app 'modules/app/app-service.bicep' = {
  scope: appResourceGroup
  name: 'app-service'
  params: {
    name: resourceName('app', workload, '', environment, location)
    planName: resourceName('asp', workload, '', environment, location)
    location: location
    tags: tags
    skuName: skus.appServicePlan
    zoneRedundant: skus.zoneRedundant
    appServiceSubnetId: spoke.outputs.appServiceSubnetId
    applicationGatewaySubnetId: spoke.outputs.applicationGatewaySubnetId
    managementIpAddress: managementIpAddress
    enablePrivateEndpoint: enableAppPrivateEndpoint
    privateEndpointSubnetId: spoke.outputs.privateEndpointSubnetId
    privateDnsZoneId: privateDnsZones[sitesZoneIndex].outputs.id
    databaseSecretUri: keyVault.outputs.connectionStringSecretUri
    storageBlobEndpoint: storage.outputs.blobEndpoint
    storageContainerName: storage.outputs.containerName
    workspaceId: monitoring.outputs.id
  }
}

// Deployed into the platform group because that is where the vault and the account live —
// a role assignment belongs to the resource it grants access to, not to the identity.
module appRbac 'modules/shared/rbac.bicep' = {
  scope: platformResourceGroup
  name: 'app-rbac'
  params: {
    principalId: app.outputs.principalId
    keyVaultName: keyVault.outputs.name
    storageAccountName: storage.outputs.name
  }
}

// ---------------------------------------------------------------------------------------
// Edge
// ---------------------------------------------------------------------------------------

module wafPolicy 'modules/edge/waf-policy.bicep' = {
  scope: appResourceGroup
  name: 'edge-waf-policy'
  params: {
    name: resourceName('waf', workload, '', environment, location)
    location: location
    tags: tags
    mode: wafPolicyMode
  }
}

module applicationGateway 'modules/edge/application-gateway.bicep' = {
  scope: appResourceGroup
  name: 'edge-application-gateway'
  params: {
    name: resourceName('agw', workload, '', environment, location)
    location: location
    tags: tags
    subnetId: spoke.outputs.applicationGatewaySubnetId
    skuName: skus.applicationGateway
    minCapacity: skus.gatewayCapacity
    maxCapacity: skus.gatewayMaxCapacity
    zoneRedundant: skus.zoneRedundant
    backendHostName: app.outputs.defaultHostName
    firewallPolicyId: wafPolicy.outputs.id
    publicIpDnsLabel: dnsLabel(workload, environment, subscription().id)
    workspaceId: monitoring.outputs.id
  }
}

module alerts 'modules/observability/alerts.bicep' = {
  scope: appResourceGroup
  name: 'observability-alerts'
  params: {
    name: resourceName('alert', workload, '', environment, location)
    location: location
    tags: tags
    applicationGatewayId: applicationGateway.outputs.id
    workspaceId: monitoring.outputs.id
    alertEmail: alertEmail
  }
}

// ---------------------------------------------------------------------------------------
// Governance
// ---------------------------------------------------------------------------------------

module policyDefinitions 'modules/governance/policy-definitions.bicep' = {
  name: 'governance-policy-definitions'
  params: {
    namePrefix: workload
  }
}

// Assigned after the workload exists. A Deny assignment that lands mid-deployment blocks
// the very resources it was written to describe, and the failure looks like a template bug.
module platformPolicyAssignment 'modules/governance/policy-assignment.bicep' = {
  scope: platformResourceGroup
  name: 'governance-assignment-platform'
  params: {
    name: '${workload}-baseline'
    policySetDefinitionId: policyDefinitions.outputs.initiativeId
    enforcementMode: policyEnforcementMode
  }
  dependsOn: [
    keyVault
    storage
  ]
}

module appPolicyAssignment 'modules/governance/policy-assignment.bicep' = {
  scope: appResourceGroup
  name: 'governance-assignment-app'
  params: {
    name: '${workload}-baseline'
    policySetDefinitionId: policyDefinitions.outputs.initiativeId
    enforcementMode: policyEnforcementMode
  }
  dependsOn: [
    app
  ]
}

// ---------------------------------------------------------------------------------------
// Outputs — everything the verification chapter needs, and nothing secret
// ---------------------------------------------------------------------------------------

@description('The only public address in the platform.')
output gatewayFqdn string = applicationGateway.outputs.fqdn

output gatewayPublicIp string = applicationGateway.outputs.publicIpAddress

@description('Reaching this directly should fail. That is the test.')
output appDefaultHostName string = app.outputs.defaultHostName

output keyVaultName string = keyVault.outputs.name
output storageAccountName string = storage.outputs.name
output logAnalyticsWorkspaceId string = monitoring.outputs.id
output postgresFqdn string = deployDatabase ? postgres!.outputs.fullyQualifiedDomainName : ''

output resourceGroups object = {
  network: networkResourceGroup.name
  platform: platformResourceGroup.name
  app: appResourceGroup.name
}
