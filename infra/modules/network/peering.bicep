metadata description = '''
One direction of a VNet peering.

Peerings are two resources, not one, and each lives in the resource group of its own VNet.
This module is deployed twice — once scoped to the hub resource group, once to the spoke —
which is also why the hub and the spoke can sit in different subscriptions later without
the template changing shape.
'''

@description('Name of the VNet this peering hangs off (the local side).')
param localVnetName string

@description('Resource ID of the VNet on the far side.')
param remoteVnetId string

@description('Peering name, e.g. peer-hub-to-spoke.')
param peeringName string

@description('''
Set on the hub side when the hub holds a VPN or ExpressRoute gateway the spoke should use.
Left false here — this platform has no on-premises leg.
''')
param allowGatewayTransit bool = false

@description('Set on the spoke side to consume the hub gateway. Mutually exclusive with allowGatewayTransit.')
param useRemoteGateways bool = false

resource localVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: localVnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: localVnet
  name: peeringName
  properties: {
    remoteVirtualNetwork: {
      id: remoteVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: allowGatewayTransit
    useRemoteGateways: useRemoteGateways
  }
}

output id string = peering.id
