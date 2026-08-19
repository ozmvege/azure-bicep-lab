using 'main.bicep'

// Values every environment shares. dev and prod pull this in with `extends` and then
// override only what differs, so a change to the network plan happens in one file instead
// of drifting between two.

param workload = 'ztwp'
param costCentre = 'lab'
param location = 'westeurope'

param addressing = {
  hubVnet: '10.10.0.0/16'
  bastionSubnet: '10.10.0.0/26'
  jumpboxSubnet: '10.10.1.0/24'
  spokeVnet: '10.20.0.0/16'
  applicationGatewaySubnet: '10.20.0.0/24'
  appServiceSubnet: '10.20.1.0/24'
  privateEndpointSubnet: '10.20.2.0/24'
}
