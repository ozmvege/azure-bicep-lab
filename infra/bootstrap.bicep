targetScope = 'subscription'

metadata description = '''
Phase zero. Run once per subscription, long before main.bicep.

It creates a resource group and a Key Vault to hold the one secret the platform cannot
generate for itself. Separating this from the main deployment is not ceremony: main.bicep
consumes the secret through az.getSecret in its parameter file, and a template cannot read
a secret from a vault it is creating in the same pass.

  az deployment sub create --location westeurope --template-file infra/bootstrap.bicep \
    --parameters workload=ztwp environment=dev operatorObjectId=$(az ad signed-in-user show --query id -o tsv)

Cost: a Key Vault with one secret. Effectively nothing, and it survives teardown of the
platform on purpose, so the next deployment does not need a new password.
'''

import { environmentName, tagSet } from 'types.bicep'
import { resourceName, globalName } from 'naming.bicep'

@minLength(3)
@maxLength(10)
param workload string = 'ztwp'

param environment environmentName = 'dev'

param location string = deployment().location

@description('Operator IP in CIDR form, e.g. 203.0.113.4/32. Find it with: curl -s https://api.ipify.org')
param managementIpAddress string = ''

@description('Object ID allowed to write secrets: az ad signed-in-user show --query id -o tsv')
param operatorObjectId string = ''

param costCentre string = 'lab'

var tags tagSet = {
  workload: workload
  environment: environment
  managedBy: 'bicep'
  costCentre: costCentre
  purpose: 'bootstrap'
}

resource bootstrapResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceName('rg', workload, 'bootstrap', environment, location)
  location: location
  tags: tags
}

module vault 'modules/platform/bootstrap-vault.bicep' = {
  scope: bootstrapResourceGroup
  name: 'bootstrap-vault'
  params: {
    name: globalName('kvbs', workload, environment, subscription().id)
    location: location
    tags: tags
    managementIpAddress: managementIpAddress
    operatorObjectId: operatorObjectId
  }
}

@description('Feed these three into main.bicepparam.')
output bootstrapResourceGroupName string = bootstrapResourceGroup.name
output bootstrapVaultName string = vault.outputs.name
output subscriptionId string = subscription().subscriptionId
