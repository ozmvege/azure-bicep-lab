metadata description = '''
One private endpoint plus its DNS zone group.

Six services in this platform are reachable only over Private Link. Rather than six almost
identical blocks, they all call this module with a different group ID and zone. The DNS
zone group is what makes the endpoint useful: without it the privatelink record is never
written and the FQDN keeps resolving to the public IP.
'''

@description('Name of the private endpoint, e.g. pep-ztwp-kv-dev-weu.')
param name string

param location string

@description('Tags inherited from the orchestrator.')
param tags object

@description('Subnet the endpoint NIC is placed in. Must have privateEndpointNetworkPolicies disabled.')
param subnetId string

@description('Resource ID of the service being fronted.')
param serviceId string

@description('Private Link group ID: sites, vault, blob, postgresqlServer, ...')
param groupId string

@description('Resource ID of the matching privatelink.* private DNS zone.')
param dnsZoneId string

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${name}-connection'
        properties: {
          privateLinkServiceId: serviceId
          groupIds: [
            groupId
          ]
        }
      }
    ]
  }

  resource dnsZoneGroup 'privateDnsZoneGroups@2024-05-01' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: replace(split(dnsZoneId, '/')[8], '.', '-')
          properties: {
            privateDnsZoneId: dnsZoneId
          }
        }
      ]
    }
  }
}

@description('Resource ID of the endpoint.')
output id string = privateEndpoint.id

@description('''
The NIC the endpoint created for itself. The private IP lives on this interface, but it
cannot be resolved inside the template: the NIC name is not known at the start of the
deployment, so neither an `existing` reference (BCP307) nor reference() (BCP181) can reach
it. The verification chapter reads it afterwards with

  az network nic show --ids <nicId> --query "ipConfigurations[0].properties.privateIPAddress"
''')
output nicId string = privateEndpoint.properties.networkInterfaces[0].id
