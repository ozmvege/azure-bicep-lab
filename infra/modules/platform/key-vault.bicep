metadata description = '''
The workload Key Vault: RBAC instead of access policies, no data-plane traffic from the
public internet, and a private endpoint for everything inside the VNet.

Two details are worth reading twice.

  1. networkAcls.bypass is AzureServices and enabledForTemplateDeployment is true. Without
     both of those, the ARM resource provider cannot write the secrets this template
     creates, and the deployment fails on a vault it just built itself.
  2. purge protection is deliberately not enabled. On a production vault it should be; in
     a lab it turns every teardown into a 90-day name reservation.
'''

param name string
param location string
param tags object

@description('Subnet for the private endpoint NIC.')
param privateEndpointSubnetId string

@description('privatelink.vaultcore.azure.net zone to register in.')
param privateDnsZoneId string

@description('''
Operator IP address in CIDR form, e.g. 203.0.113.4/32. The vault is otherwise unreachable
from outside the VNet, which also means unreachable from the machine running the lab.
Leave empty to lock it down completely and work through the jumpbox instead.
''')
param managementIpAddress string = ''

@description('Log Analytics workspace for the audit log. Empty disables diagnostics.')
param workspaceId string = ''

@description('Database password, passed straight through from the bootstrap vault.')
@secure()
param databasePassword string = ''

@description('Host, user and database name the connection string is assembled from.')
param databaseHost string = ''
param databaseUser string = ''
param databaseName string = ''

@description('''
Whether to write that secret. This looks redundant next to the parameter above, and it is
not: the outputs-should-not-contain-secrets linter rule fires on any output expression that
so much as tests a secure value, including empty(). Keeping the switch and the secret in
separate parameters is what lets this module hand back the secret URI at all.
''')
param createDatabaseSecret bool = false

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    // Access policies are the old model: 16 KB of JSON that no RBAC report ever sees.
    enableRbacAuthorization: true
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: empty(managementIpAddress)
        ? []
        : [
            {
              value: managementIpAddress
            }
          ]
      virtualNetworkRules: []
    }
  }
}

// Assembled here rather than in main.bicep so that no variable outside this module ever
// holds the password. Percent-encoding matters: a password containing @ or / breaks the
// URI, which is why the bootstrap generator restricts the alphabet it draws from.
var connectionString = 'postgresql://${databaseUser}:${databasePassword}@${databaseHost}:5432/${databaseName}?sslmode=require'

resource connectionStringSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (createDatabaseSecret) {
  parent: keyVault
  name: 'database-connection-string'
  properties: {
    value: connectionString
    contentType: 'text/plain'
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(workspaceId)) {
  name: 'diag-to-law'
  scope: keyVault
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
    serviceId: keyVault.id
    groupId: 'vault'
    dnsZoneId: privateDnsZoneId
  }
}

output id string = keyVault.id
output name string = keyVault.name
output uri string = keyVault.properties.vaultUri

@description('Secret URI for the App Service Key Vault reference. Not the secret — the address of it.')
output connectionStringSecretUri string = createDatabaseSecret
  ? '${keyVault.properties.vaultUri}secrets/database-connection-string'
  : ''

output privateEndpointNicId string = privateEndpoint.outputs.nicId
