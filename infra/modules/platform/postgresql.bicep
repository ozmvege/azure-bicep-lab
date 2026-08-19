metadata description = '''
PostgreSQL Flexible Server reachable only through a private endpoint.

Flexible Server offers two networking models and they are mutually exclusive. VNet
injection (a delegated subnet) is the older one and locks the server to a single VNet
forever. This lab uses the other one: public access disabled, plus a private endpoint —
the same shape as every other service here, and the only model that survives a hub-and-spoke
where clients arrive from more than one network.

Entra ID authentication is switched on alongside password authentication. The password is
still what the connection string uses, because a lab that also has to explain OAuth token
acquisition stops being a lab about networking.
'''

param name string
param location string
param tags object

param privateEndpointSubnetId string

@description('privatelink.postgres.database.azure.com zone.')
param privateDnsZoneId string

@description('Compute SKU, e.g. Standard_B1ms.')
param skuName string = 'Standard_B1ms'

param tier 'Burstable' | 'GeneralPurpose' | 'MemoryOptimized' = 'Burstable'

@minValue(32)
param storageSizeGb int = 32

param postgresVersion string = '16'

param administratorLogin string = 'pgadmin'

@description('Sourced from the bootstrap Key Vault by main.bicepparam — never typed, never committed.')
@secure()
param administratorPassword string

param databaseName string = 'appdb'

@description('Object ID of a user or group to make Entra administrator. Empty skips it.')
param entraAdminObjectId string = ''

@description('UPN or group name matching entraAdminObjectId. Shown in the portal.')
param entraAdminName string = ''

param entraAdminType 'User' | 'Group' | 'ServicePrincipal' = 'User'

param workspaceId string = ''

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: tier
  }
  properties: {
    version: postgresVersion
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
      tenantId: tenant().tenantId
    }
    storage: {
      storageSizeGB: storageSizeGb
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    network: {
      // No delegatedSubnetResourceId and no firewall rules: the server has no public
      // surface, and the private endpoint below is the only route to port 5432.
      publicNetworkAccess: 'Disabled'
    }
    highAvailability: {
      mode: tier == 'Burstable' ? 'Disabled' : 'ZoneRedundant'
    }
  }

  resource database 'databases@2024-08-01' = {
    name: databaseName
    properties: {
      charset: 'UTF8'
      collation: 'en_US.utf8'
    }
  }
}

resource entraAdministrator 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = if (!empty(entraAdminObjectId)) {
  parent: postgres
  name: empty(entraAdminObjectId) ? 'placeholder' : entraAdminObjectId
  properties: {
    principalType: entraAdminType
    principalName: entraAdminName
    tenantId: tenant().tenantId
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(workspaceId)) {
  name: 'diag-to-law'
  scope: postgres
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

module privateEndpoint '../shared/private-endpoint.bicep' = {
  name: 'pep-${name}'
  params: {
    name: 'pep-${name}'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    serviceId: postgres.id
    groupId: 'postgresqlServer'
    dnsZoneId: privateDnsZoneId
  }
}

output id string = postgres.id
output name string = postgres.name
output fullyQualifiedDomainName string = postgres.properties.fullyQualifiedDomainName
output databaseName string = databaseName
output administratorLogin string = administratorLogin
output privateEndpointNicId string = privateEndpoint.outputs.nicId
