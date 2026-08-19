metadata description = '''
The spoke virtual network — everything the workload owns.

Three subnets, three jobs, and no overlap between them:

  snet-agw   the only subnet with a public frontend; Application Gateway demands it alone
  snet-app   delegated to Microsoft.Web/serverFarms for App Service VNet integration
  snet-pep   every private endpoint NIC in the platform

The delegation on snet-app is not optional decoration: without it App Service refuses to
integrate, and the error surfaces on the app rather than on the network.
'''

param name string
param location string
param tags object

param addressPrefix string
param applicationGatewaySubnetPrefix string
param appServiceSubnetPrefix string
param privateEndpointSubnetPrefix string

var applicationGatewaySubnetName = 'snet-agw'
var appServiceSubnetName = 'snet-app'
var privateEndpointSubnetName = 'snet-pep'

module applicationGatewayNsg 'nsg.bicep' = {
  name: 'nsg-agw'
  params: {
    name: 'nsg-agw-${last(split(name, '-'))}'
    location: location
    tags: tags
    securityRules: [
      {
        // Without this rule the gateway deploys and then reports an unhealthy control
        // plane. It is infrastructure traffic, not user traffic, and it is mandatory.
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'AllowWebInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '80'
            '443'
          ]
        }
      }
    ]
  }
}

module appServiceNsg 'nsg.bicep' = {
  name: 'nsg-app'
  params: {
    name: 'nsg-app-${last(split(name, '-'))}'
    location: location
    tags: tags
    securityRules: [
      {
        // VNet integration is outbound only. Nothing legitimately initiates a connection
        // into this subnet, so the intent is written down rather than left to defaults.
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

module privateEndpointNsg 'nsg.bicep' = {
  name: 'nsg-pep'
  params: {
    name: 'nsg-pep-${last(split(name, '-'))}'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'AllowVnetHttpsInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '443'
            '5432'
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

resource spokeVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
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
        name: applicationGatewaySubnetName
        properties: {
          addressPrefix: applicationGatewaySubnetPrefix
          networkSecurityGroup: {
            id: applicationGatewayNsg.outputs.id
          }
          // The service endpoint is what lets the App Service access restriction name this
          // subnet instead of an IP address. Traffic from the gateway to the app then
          // leaves with a subnet identity, and the app can refuse everything else.
          serviceEndpoints: [
            {
              service: 'Microsoft.Web'
              locations: [
                location
              ]
            }
          ]
        }
      }
      {
        name: appServiceSubnetName
        properties: {
          addressPrefix: appServiceSubnetPrefix
          networkSecurityGroup: {
            id: appServiceNsg.outputs.id
          }
          delegations: [
            {
              name: 'serverFarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          networkSecurityGroup: {
            id: privateEndpointNsg.outputs.id
          }
          // Disabled is what lets a private endpoint be created here without argument.
          // The trade-off is documented in docs/02-network.md: with policies disabled the
          // NSG above does not filter traffic to the endpoint NICs themselves.
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

output id string = spokeVnet.id
output name string = spokeVnet.name
output applicationGatewaySubnetId string = '${spokeVnet.id}/subnets/${applicationGatewaySubnetName}'
output appServiceSubnetId string = '${spokeVnet.id}/subnets/${appServiceSubnetName}'
output privateEndpointSubnetId string = '${spokeVnet.id}/subnets/${privateEndpointSubnetName}'
