metadata description = '''
The bootstrap Key Vault: one vault, one job, deployed once and then left alone.

The platform deployment needs a database password it must not invent, must not read from a
file in the repository and must not receive on a command line that lands in shell history.
A vault that exists before the platform solves this: the operator seeds a secret into it
once, and main.bicepparam reads it at deploy time with az.getSecret.

enabledForTemplateDeployment is what makes that read legal. Without it, az.getSecret fails
with an authorization error that names the vault and not the missing flag.
'''

param name string
param location string
param tags object

@description('Operator IP in CIDR form. Empty leaves the vault open to any network, which is only acceptable while nothing is in it yet.')
param managementIpAddress string = ''

@description('Object ID of the human or pipeline identity that seeds secrets. Empty skips the role assignment.')
param operatorObjectId string = ''

var keyVaultSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: empty(managementIpAddress) ? 'Allow' : 'Deny'
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

resource operatorAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(operatorObjectId)) {
  scope: vault
  name: guid(vault.id, operatorObjectId, keyVaultSecretsOfficerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsOfficerRoleId)
    principalId: operatorObjectId
    principalType: 'User'
  }
}

output id string = vault.id
output name string = vault.name
output uri string = vault.properties.vaultUri
