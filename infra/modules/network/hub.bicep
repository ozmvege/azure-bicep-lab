metadata description = '''
The hub virtual network.

The hub owns the things the workload should not: remote access (Bastion), and later a
firewall, a DNS forwarder or a VPN gateway. It is deployed with its subnets present even
when the optional Bastion host is switched off — subnets cost nothing, and carving one out
of a VNet that is already peered and populated is a change nobody enjoys making later.
'''

param name string
param location string
param tags object

@description('Hub address space.')
param addressPrefix string

@description('Must be at least /26 and the subnet must be named AzureBastionSubnet.')
param bastionSubnetPrefix string

@description('Subnet for the optional maintenance jumpbox.')
param jumpboxSubnetPrefix string

var bastionSubnetName = 'AzureBastionSubnet'
var jumpboxSubnetName = 'snet-jumpbox'

// Documented Azure Bastion rule set. Bastion refuses to deploy if these are missing, and
// the error it returns names the NSG rather than the rule, so they are spelled out here.
module bastionNsg 'nsg.bicep' = {
  name: 'nsg-bastion'
  params: {
    name: 'nsg-${bastionSubnetName}-${last(split(name, '-'))}'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'AllowHttpsInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 140
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionHostCommunication'
        properties: {
          priority: 150
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowSshRdpOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionCommunication'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowGetSessionInformation'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
        }
      }
    ]
  }
}

module jumpboxNsg 'nsg.bicep' = {
  name: 'nsg-jumpbox'
  params: {
    name: 'nsg-jumpbox-${last(split(name, '-'))}'
    location: location
    tags: tags
    securityRules: [
      {
        // The only way in is Bastion, which enters from inside the VNet.
        name: 'AllowBastionSshInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: bastionSubnetName
        properties: {
          addressPrefix: bastionSubnetPrefix
          networkSecurityGroup: {
            id: bastionNsg.outputs.id
          }
        }
      }
      {
        name: jumpboxSubnetName
        properties: {
          addressPrefix: jumpboxSubnetPrefix
          networkSecurityGroup: {
            id: jumpboxNsg.outputs.id
          }
        }
      }
    ]
  }
}

output id string = hubVnet.id
output name string = hubVnet.name
output bastionSubnetId string = '${hubVnet.id}/subnets/${bastionSubnetName}'
output jumpboxSubnetId string = '${hubVnet.id}/subnets/${jumpboxSubnetName}'
