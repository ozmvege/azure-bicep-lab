metadata description = '''
The Log Analytics workspace every diagnostic setting in the platform points at.

One workspace, in the hub, for the whole platform. Splitting logs per resource group feels
tidier and makes the one query that matters — correlate a blocked request at the gateway
with what the app did next — impossible to write.
'''

param name string
param location string
param tags object

@description('30 days is inside the free allowance. Longer retention is billed per GB per month.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Hard cap in GB/day. -1 means uncapped; a lab should not be uncapped.')
param dailyQuotaGb int = 1

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

output id string = workspace.id
output name string = workspace.name
output customerId string = workspace.properties.customerId
