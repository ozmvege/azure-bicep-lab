metadata description = '''
One privatelink.* zone and its virtual network links.

A private endpoint without a matching private DNS zone is the single most common way to
build "private" infrastructure that still resolves to a public IP. The zone is linked to
every VNet that has to resolve the name — here both the hub and the spoke, so a jumpbox in
the hub sees the same addresses the application does.
'''

@description('Zone name, e.g. privatelink.vaultcore.azure.net.')
param zoneName string

param tags object

@description('Resource IDs of every VNet that must resolve names in this zone.')
param linkedVnetIds string[]

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  location: 'global'
  tags: tags
}

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (vnetId, index) in linkedVnetIds: {
    parent: zone
    name: 'link-${last(split(vnetId, '/'))}'
    location: 'global'
    tags: tags
    properties: {
      virtualNetwork: {
        id: vnetId
      }
      // Auto-registration is for VM records. Private endpoints write their own A records
      // through the DNS zone group, so this stays off.
      registrationEnabled: false
    }
  }
]

output id string = zone.id
output name string = zone.name
