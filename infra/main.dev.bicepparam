using none
extends 'main.shared.bicepparam'

// ---------------------------------------------------------------------------------------
// dev — the profile the lab is written against.
//
// Cheap where it can be, honest where it matters: the WAF is real, the private endpoints
// are real, and the only thing dialled down is the size of the boxes. The App Service
// keeps its public endpoint (locked to the gateway subnet) so that the Kudu console stays
// reachable for the verification chapter.
//
// Before deploying, replace the three bootstrap coordinates below with the outputs of
// bootstrap.bicep, and set managementIpAddress to your own address:
//
//   curl -s https://api.ipify.org
//   az deployment sub show -n bootstrap --query properties.outputs
// ---------------------------------------------------------------------------------------

param environment = 'dev'

param skus = {
  appServicePlan: 'B1'
  applicationGateway: 'WAF_v2'
  gatewayCapacity: 1
  gatewayMaxCapacity: 2
  postgresSku: 'Standard_B1ms'
  postgresTier: 'Burstable'
  postgresStorageGb: 32
  zoneRedundant: false
  logRetentionDays: 30
}

param wafPolicyMode = 'Prevention'
param enableAppPrivateEndpoint = false
param deployDatabase = true
param deployBastion = false
param deployJumpbox = false
param policyEnforcementMode = 'Default'

param managementIpAddress = '203.0.113.4/32'
param alertEmail = ''

// The password is read from the bootstrap vault at deploy time. It is never in this file,
// never in the ARM template, and never in the deployment history — az.getSecret is resolved
// by the deployment engine, not by the client.
param postgresAdministratorPassword = az.getSecret(
  '00000000-0000-0000-0000-000000000000',
  'rg-ztwp-bootstrap-dev-weu',
  'kvbsztwpdev00000',
  'postgres-admin-password'
)
