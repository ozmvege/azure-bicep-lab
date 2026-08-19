metadata description = '''
Data-plane role assignments for the application's managed identity.

These are the assignments that make "no secrets in configuration" true rather than
aspirational: the app authenticates to Key Vault and Storage as itself. Role assignments
are scoped to the individual resources, never to the resource group, so the identity gets
exactly the two permissions it needs and nothing that arrives later by inheritance.

Deploying this module requires Owner or User Access Administrator — writing role
assignments is a privilege Contributor deliberately does not have.
'''

@description('Principal ID of the managed identity receiving the roles.')
param principalId string

@description('Vault the identity may read secrets from.')
param keyVaultName string

@description('Storage account the identity may read and write blobs in.')
param storageAccountName string

// Built-in role definition IDs are stable GUIDs across every tenant.
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

resource keyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  // A GUID derived from scope + principal + role: deterministic, so redeploying is a
  // no-op instead of a conflict.
  name: guid(keyVault.id, principalId, keyVaultSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageBlobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, principalId, storageBlobDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

output keyVaultRoleAssignmentId string = keyVaultSecretsUser.id
output storageRoleAssignmentId string = storageBlobDataContributor.id
