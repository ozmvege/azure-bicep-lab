metadata description = '''
Blob storage with the four switches that decide whether "private" means anything:

  publicNetworkAccess  Disabled  — the account is not on the internet at all
  allowBlobPublicAccess false    — no container can ever be made anonymous
  allowSharedKeyAccess  false    — account keys stop working; Entra ID is the only way in
  minimumTlsVersion     TLS1_2   — old clients fail instead of downgrading

The third one is the interesting one. Disabling shared keys is what turns "we use managed
identity" from a claim into a property of the system: there is no key left to leak, and
az storage commands must run with --auth-mode login.
'''

param name string
param location string
param tags object

param privateEndpointSubnetId string

@description('privatelink.blob.core.windows.net zone.')
param privateDnsZoneId string

@description('Container created for the application to write to.')
param containerName string = 'app-data'

param workspaceId string = ''

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
    defaultToOAuthAuthentication: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
    encryption: {
      requireInfrastructureEncryption: false
      keySource: 'Microsoft.Storage'
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }

  resource blobService 'blobServices@2024-01-01' = {
    name: 'default'
    properties: {
      deleteRetentionPolicy: {
        enabled: true
        days: 7
      }
      containerDeleteRetentionPolicy: {
        enabled: true
        days: 7
      }
    }

    resource container 'containers@2024-01-01' = {
      name: containerName
      properties: {
        publicAccess: 'None'
      }
    }
  }
}

// Data-plane logging hangs off the blob service, not the account. A diagnostic setting on
// the account alone gives you metrics and no read/write/delete trail.
resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(workspaceId)) {
  name: 'diag-to-law'
  scope: storageAccount::blobService
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

module privateEndpoint '../shared/private-endpoint.bicep' = {
  name: 'pep-${name}-blob'
  params: {
    name: 'pep-${name}-blob'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    serviceId: storageAccount.id
    groupId: 'blob'
    dnsZoneId: privateDnsZoneId
  }
}

output id string = storageAccount.id
output name string = storageAccount.name
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output containerName string = containerName
output privateEndpointNicId string = privateEndpoint.outputs.nicId
