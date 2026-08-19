using none
extends 'main.shared.bicepparam'

// ---------------------------------------------------------------------------------------
// prod — what the same platform looks like when cost stops being the deciding factor.
//
// Four things change, and each one is a decision rather than a bigger number:
//
//   enableAppPrivateEndpoint  the app leaves the public internet entirely. Kudu goes with
//                             it, which is why Bastion is switched on in the same breath.
//   zoneRedundant             the plan runs three instances across zones and the gateway
//                             spreads with it. This is the single biggest cost jump.
//   postgres GeneralPurpose   Burstable cannot do zone-redundant high availability.
//   logRetentionDays 90       30 days is the free allowance, not an incident timeline.
//
// Do not deploy this profile to try the lab out. It is the comparison, not the exercise.
// ---------------------------------------------------------------------------------------

param environment = 'prod'

param skus = {
  appServicePlan: 'P1v3'
  applicationGateway: 'WAF_v2'
  gatewayCapacity: 2
  gatewayMaxCapacity: 10
  postgresSku: 'Standard_D2ds_v5'
  postgresTier: 'GeneralPurpose'
  postgresStorageGb: 128
  zoneRedundant: true
  logRetentionDays: 90
}

param wafPolicyMode = 'Prevention'
param enableAppPrivateEndpoint = true
param deployDatabase = true
param deployBastion = true

// Set to true and paste the public half of an SSH key to get a maintenance jumpbox. It is
// left off here because a jumpbox without a key deploys nothing and says nothing about it.
param deployJumpbox = false
param jumpboxSshPublicKey = ''

param policyEnforcementMode = 'Default'

param managementIpAddress = '203.0.113.4/32'
param alertEmail = 'operations@example.com'

param postgresAdministratorPassword = az.getSecret(
  '00000000-0000-0000-0000-000000000000',
  'rg-ztwp-bootstrap-prod-weu',
  'kvbsztwpprod00000',
  'postgres-admin-password'
)
