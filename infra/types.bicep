metadata description = '''
Shared type contracts for the zero-trust web platform.

Everything in here is exported and imported by the orchestrator and the modules, so a
parameter that does not fit the contract fails at compile time — before a deployment is
ever submitted to Azure. This is the whole point of user-defined types: the error arrives
in the editor, not thirty seconds into a rollout.
'''

@export()
@description('Deployment environment. Drives SKUs, redundancy and WAF mode.')
type environmentName = 'dev' | 'prod'

@export()
@description('Web Application Firewall mode. Detection logs, Prevention blocks.')
type wafMode = 'Detection' | 'Prevention'

@export()
@description('Tags stamped onto every resource group and every resource in the platform.')
type tagSet = {
  @description('Short workload identifier, e.g. ztwp.')
  @minLength(3)
  @maxLength(10)
  workload: string

  environment: environmentName

  @description('Always bicep. If a resource is not tagged with this, someone made it by hand.')
  managedBy: 'bicep'

  @description('Free-text owner or cost centre, surfaced in Cost Management.')
  costCentre: string

  @description('Any additional tags the organisation requires.')
  *: string
}

@export()
@description('''
The complete IP plan. Kept as one object so the address space is reviewable in a single
place instead of being scattered across seven parameters.
''')
type addressPlan = {
  @description('Hub VNet CIDR. /16 leaves room for the platform services a real hub grows.')
  hubVnet: string

  @description('Azure Bastion requires a subnet named AzureBastionSubnet of at least /26.')
  bastionSubnet: string

  @description('Optional jumpbox subnet in the hub.')
  jumpboxSubnet: string

  @description('Spoke VNet CIDR — everything the workload owns.')
  spokeVnet: string

  @description('Application Gateway needs a dedicated subnet; nothing else may live in it.')
  applicationGatewaySubnet: string

  @description('Delegated to Microsoft.Web/serverFarms for App Service VNet integration.')
  appServiceSubnet: string

  @description('Every private endpoint NIC in the platform lands here.')
  privateEndpointSubnet: string
}

@export()
@description('The SKU and redundancy profile for one environment. dev is cheap, prod is honest.')
type skuProfile = {
  @description('B1 is the cheapest tier that still supports VNet integration and private endpoints.')
  appServicePlan: 'B1' | 'B2' | 'P0v3' | 'P1v3' | 'P2v3'

  @description('WAF_v2 is the point of the lab; Standard_v2 exists as a cost escape hatch.')
  applicationGateway: 'Standard_v2' | 'WAF_v2'

  @description('Fixed instance count for the gateway. Autoscale takes over above this floor.')
  @minValue(1)
  @maxValue(10)
  gatewayCapacity: int

  @description('Upper bound for gateway autoscale.')
  @minValue(2)
  @maxValue(125)
  gatewayMaxCapacity: int

  @description('Burstable tiers are fine for a lab and cost cents per hour.')
  postgresSku: string

  postgresTier: 'Burstable' | 'GeneralPurpose' | 'MemoryOptimized'

  @description('Smallest supported PostgreSQL Flexible Server disk is 32 GB.')
  @minValue(32)
  postgresStorageGb: int

  @description('Zone redundancy costs nothing extra on the gateway and everything on the plan.')
  zoneRedundant: bool

  @description('Log Analytics retention. 30 days is included in the free allowance.')
  @minValue(30)
  @maxValue(730)
  logRetentionDays: int
}

@export()
@description('One private endpoint to create, described independently of the resource it fronts.')
type privateEndpointRequest = {
  @description('Short name, used to build the endpoint and NIC names.')
  name: string

  @description('Resource ID of the service being fronted.')
  serviceId: string

  @description('Private link group ID: sites, vault, blob, postgresqlServer, ...')
  groupId: string

  @description('Resource ID of the matching privatelink.* zone.')
  dnsZoneId: string
}

@export()
@description('Diagnostic category selection for a resource, resolved per resource type.')
type diagnosticProfile = {
  workspaceId: string
  @description('Dedicated writes to resource-specific tables (AGWFirewallLogs); AzureDiagnostics is the legacy shared table.')
  destinationType: 'Dedicated' | 'AzureDiagnostics'
}
