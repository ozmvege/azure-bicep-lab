metadata description = '''
Assignment of the baseline initiative to one resource group.

Scope is the whole lesson here. The definitions live at subscription scope because that is
the lowest scope a definition can exist at; the assignment lands on a single resource
group, so a Deny effect cannot take the rest of the subscription down with it. Widening
later is one parameter; narrowing after an outage is a conversation.
'''

param name string

@description('Resource ID of the initiative created at subscription scope.')
param policySetDefinitionId string

@description('Deny blocks non-compliant deployments outright. Audit only records them.')
param effect 'Audit' | 'Deny' | 'Disabled' = 'Deny'

@description('DoNotEnforce is what-if for policy: evaluation runs, nothing is blocked.')
param enforcementMode 'Default' | 'DoNotEnforce' = 'Default'

resource assignment 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: name
  properties: {
    displayName: 'Zero-trust web platform baseline'
    description: 'Storage, PostgreSQL, Key Vault and App Service must stay off the public internet.'
    policyDefinitionId: policySetDefinitionId
    enforcementMode: enforcementMode
    parameters: {
      effect: {
        value: effect
      }
    }
    // Shown in the portal and returned in the deployment error, which is the difference
    // between "denied by policy" and a support ticket.
    nonComplianceMessages: [
      {
        message: 'This platform requires private networking. See docs/07-governance.md.'
      }
    ]
  }
}

output id string = assignment.id
output name string = assignment.name
