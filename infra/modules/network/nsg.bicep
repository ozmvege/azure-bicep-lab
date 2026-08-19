metadata description = '''
A network security group with an explicit rule set.

Every subnet in this platform gets one, including the subnets whose default rules would
already be sufficient. The reason is auditability: a reviewer should be able to read the
allowed paths out of the template instead of reconstructing them from Azure's implicit
defaults.
'''

param name string
param location string
param tags object

@description('Rules in the shape Microsoft.Network/networkSecurityGroups expects.')
param securityRules object[] = []

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    securityRules: securityRules
  }
}

output id string = networkSecurityGroup.id
output name string = networkSecurityGroup.name
