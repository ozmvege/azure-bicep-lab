metadata description = '''
Azure Bastion — optional, and off by default because it is the second most expensive thing
in this platform after the gateway.

Note the SKU choice. The Developer SKU is free but runs on shared infrastructure and does
not traverse VNet peering, which makes it useless in a hub-and-spoke topology: the whole
point here is reaching a jumpbox in the hub and, through peering, resources in the spoke.
Basic is therefore the cheapest SKU that actually fits the architecture.
'''

param name string
param location string
param tags object

@description('The AzureBastionSubnet in the hub.')
param subnetId string

@description('Basic is the entry point. Standard adds native client support and scaling.')
param sku 'Basic' | 'Standard' = 'Basic'

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${name}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

output id string = bastion.id
output publicIp string = publicIp.properties.ipAddress
