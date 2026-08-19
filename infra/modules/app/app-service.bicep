metadata description = '''
The application tier: a Linux App Service with two independent network edges.

  Outbound  VNet integration into the delegated subnet, with vnetRouteAllEnabled so that
            every outbound connection — including the Key Vault reference lookups — goes
            through the VNet and resolves against the private DNS zones.

  Inbound   Two mutually exclusive modes, chosen with enablePrivateEndpoint:

            false  public endpoint, but the only accepted source is the Application
                   Gateway subnet (via the Microsoft.Web service endpoint) plus the
                   operator IP on the SCM site. Everything else gets 403 Ip Forbidden.
                   Kudu stays reachable, which is what makes the verification chapter
                   possible without a jumpbox.

            true   publicNetworkAccess disabled and a private endpoint instead. Stricter,
                   and it takes the SCM site off the internet with it: from that point on,
                   deployments and the console need the jumpbox or a VPN.

The dev profile uses the first, the prod profile the second. That difference is the lesson,
not an oversight.
'''

param name string
param planName string
param location string
param tags object

@description('B1 is the cheapest SKU that supports both VNet integration and private endpoints.')
param skuName string = 'B1'

@description('Zone redundancy requires a Premium v3 plan and at least three instances.')
param zoneRedundant bool = false

@description('Delegated subnet for outbound VNet integration.')
param appServiceSubnetId string

@description('Gateway subnet allowed to reach the app while it still has a public endpoint.')
param applicationGatewaySubnetId string

@description('Operator IP in CIDR form for the SCM/Kudu site. Empty leaves SCM open to any source.')
param managementIpAddress string = ''

@description('Swap the public endpoint for a private one. See the note at the top of this file.')
param enablePrivateEndpoint bool = false

param privateEndpointSubnetId string = ''

@description('privatelink.azurewebsites.net zone.')
param privateDnsZoneId string = ''

@description('Key Vault secret URI. Becomes a Key Vault reference rather than a value.')
param databaseSecretUri string = ''

param storageBlobEndpoint string = ''
param storageContainerName string = ''

param workspaceId string = ''

var isPremium = startsWith(skuName, 'P')

var baseAppSettings = [
  {
    name: 'WEBSITE_RUN_FROM_PACKAGE'
    value: '0'
  }
  {
    name: 'STORAGE_BLOB_ENDPOINT'
    value: storageBlobEndpoint
  }
  {
    name: 'STORAGE_CONTAINER'
    value: storageContainerName
  }
]

// A Key Vault reference is resolved by the platform using the app's managed identity. The
// app never sees the vault, the pipeline never sees the secret, and `az webapp config
// appsettings list` shows this expression instead of a password.
var secretAppSettings = empty(databaseSecretUri)
  ? []
  : [
      {
        name: 'DATABASE_URL'
        value: '@Microsoft.KeyVault(SecretUri=${databaseSecretUri})'
      }
    ]

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: skuName
    capacity: zoneRedundant ? 3 : 1
  }
  kind: 'linux'
  properties: {
    reserved: true
    zoneRedundant: isPremium && zoneRedundant
  }
}

resource app 'Microsoft.Web/sites@2024-04-01' = {
  name: name
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: enablePrivateEndpoint ? 'Disabled' : 'Enabled'
    virtualNetworkSubnetId: appServiceSubnetId
    vnetRouteAllEnabled: true
    clientAffinityEnabled: false
    siteConfig: {
      linuxFxVersion: 'NODE|20-lts'
      alwaysOn: true
      http20Enabled: true
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      healthCheckPath: '/'
      appSettings: concat(baseAppSettings, secretAppSettings)
      ipSecurityRestrictionsDefaultAction: 'Deny'
      ipSecurityRestrictions: enablePrivateEndpoint
        ? []
        : [
            {
              vnetSubnetResourceId: applicationGatewaySubnetId
              action: 'Allow'
              priority: 100
              name: 'AllowApplicationGatewaySubnet'
              description: 'Traffic arrives over the Microsoft.Web service endpoint from snet-agw.'
            }
          ]
      // The SCM site carries its own rules. Sharing the main rules would lock the operator
      // out of the console, since the console is not the Application Gateway.
      scmIpSecurityRestrictionsUseMain: false
      scmIpSecurityRestrictionsDefaultAction: empty(managementIpAddress) ? 'Allow' : 'Deny'
      scmIpSecurityRestrictions: empty(managementIpAddress)
        ? []
        : [
            {
              ipAddress: managementIpAddress
              action: 'Allow'
              priority: 100
              name: 'AllowOperator'
              description: 'Kudu console and deployments from the operator workstation.'
            }
          ]
    }
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(workspaceId)) {
  name: 'diag-to-law'
  scope: app
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

module privateEndpoint '../shared/private-endpoint.bicep' = if (enablePrivateEndpoint) {
  name: 'pep-${name}'
  params: {
    name: 'pep-${name}'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    serviceId: app.id
    groupId: 'sites'
    dnsZoneId: privateDnsZoneId
  }
}

output id string = app.id
output name string = app.name
output defaultHostName string = app.properties.defaultHostName
output principalId string = app.identity.principalId
output planId string = plan.id
