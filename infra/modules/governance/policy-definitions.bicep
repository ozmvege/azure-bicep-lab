targetScope = 'subscription'

metadata description = '''
Three custom policy definitions and the initiative that bundles them.

Custom rather than built-in, for two reasons. Built-in definitions are referenced by GUID,
which makes a template unreadable and unverifiable at review time. And these three encode
decisions this platform actually made — including one that no built-in policy expresses:
the Key Vault here keeps publicNetworkAccess enabled and relies on networkAcls.defaultAction
being Deny, so a policy that simply demands publicNetworkAccess Disabled would reject the
platform it is meant to protect.

The rule bodies live in policy-rules/*.json and are pulled in with loadJsonContent. That is
not stylistic: a policy rule is full of ARM expressions like [parameters('effect')], and a
string starting with [ inside a Bicep file gets escaped to [[ on compile. Keeping the rules
in JSON side-steps the escaping entirely and keeps them readable to anyone who has only
ever seen policy in the portal.

Nothing here uses deployIfNotExists or modify, so no managed identity and no role
assignment is needed to assign these — which is what keeps the lab runnable on a
subscription where you are Contributor rather than Owner.
'''

@description('Prefix for the definition names, e.g. ztwp.')
param namePrefix string

var denyStoragePublicBlobAccess = loadJsonContent('policy-rules/deny-storage-public-blob-access.json')
var denyPublicNetworkAccess = loadJsonContent('policy-rules/deny-public-network-access.json')
var requireHttpsAppService = loadJsonContent('policy-rules/require-https-app-service.json')

resource storagePublicBlobAccess 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-deny-storage-public-blob-access'
  properties: {
    policyType: 'Custom'
    mode: 'Indexed'
    displayName: 'Storage accounts must not allow anonymous blob access'
    description: 'allowBlobPublicAccess must be false. Anonymous containers are how storage accounts end up in the news.'
    metadata: {
      category: 'Storage'
      version: '1.0.0'
    }
    parameters: denyStoragePublicBlobAccess.parameters
    policyRule: denyStoragePublicBlobAccess.policyRule
  }
}

resource publicNetworkAccess 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-deny-public-network-access'
  properties: {
    policyType: 'Custom'
    mode: 'Indexed'
    displayName: 'Data services must not be reachable from the public internet'
    description: 'Storage and PostgreSQL must disable public network access; Key Vault must default-deny in its network ACLs.'
    metadata: {
      category: 'Network'
      version: '1.0.0'
    }
    parameters: denyPublicNetworkAccess.parameters
    policyRule: denyPublicNetworkAccess.policyRule
  }
}

resource httpsAppService 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-require-https-app-service'
  properties: {
    policyType: 'Custom'
    mode: 'Indexed'
    displayName: 'App Service must be HTTPS-only on a current TLS version'
    description: 'httpsOnly must be true and minTlsVersion must be at least the configured floor.'
    metadata: {
      category: 'App Service'
      version: '1.0.0'
    }
    parameters: requireHttpsAppService.parameters
    policyRule: requireHttpsAppService.policyRule
  }
}

resource initiative 'Microsoft.Authorization/policySetDefinitions@2023-04-01' = {
  name: '${namePrefix}-zero-trust-baseline'
  properties: {
    policyType: 'Custom'
    displayName: 'Zero-trust web platform baseline'
    description: 'The three rules this platform is built to satisfy, assigned as one unit.'
    metadata: {
      category: 'Security'
      version: '1.0.0'
    }
    parameters: {
      effect: {
        type: 'String'
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Deny'
        metadata: {
          displayName: 'Effect for every rule in the initiative'
        }
      }
    }
    policyDefinitions: [
      {
        policyDefinitionReferenceId: 'denyStoragePublicBlobAccess'
        policyDefinitionId: storagePublicBlobAccess.id
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
      }
      {
        policyDefinitionReferenceId: 'denyPublicNetworkAccess'
        policyDefinitionId: publicNetworkAccess.id
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
      }
      {
        policyDefinitionReferenceId: 'requireHttpsAppService'
        policyDefinitionId: httpsAppService.id
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
      }
    ]
  }
}

output initiativeId string = initiative.id
output initiativeName string = initiative.name
