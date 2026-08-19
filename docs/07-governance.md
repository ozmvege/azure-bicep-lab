# 07 — Governance: policy that denies a real deployment

> Three custom definitions, an initiative that bundles them, and an assignment scoped
> narrowly enough that a Deny effect cannot take the subscription down with it. Then a
> deployment that gets rejected, on purpose.

**Time:** 40 minutes · **Cost:** none — policy is free

**Files:** [`policy-definitions.bicep`](../infra/modules/governance/policy-definitions.bicep) ·
[`policy-assignment.bicep`](../infra/modules/governance/policy-assignment.bicep) ·
[`policy-rules/`](../infra/modules/governance/policy-rules)

---

## 7.1 Why the rules live in JSON

A policy rule is full of ARM expressions:

```json
"then": { "effect": "[parameters('effect')]" }
```

Write that string inside a Bicep file and the compiler escapes the leading bracket, because
a string starting with `[` is how ARM marks an expression. You get `[[parameters('effect')]`
where you meant a literal, and the fix — escaping the escape — is unreadable.

`loadJsonContent()` sidesteps it entirely:

```bicep
var denyPublicNetworkAccess = loadJsonContent('policy-rules/deny-public-network-access.json')

resource publicNetworkAccess 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-deny-public-network-access'
  properties: {
    policyType: 'Custom'
    mode: 'Indexed'
    parameters: denyPublicNetworkAccess.parameters
    policyRule: denyPublicNetworkAccess.policyRule
  }
}
```

The rule stays readable to anyone who has only ever seen policy in the portal, and it can be
pasted straight into the policy editor to test.

> Worth knowing anyway: in the compiled template you will see `[[parameters('effect')]`, and
> that is **correct**. ARM converts `[[` back to `[` when it writes the policy, so the policy
> engine receives the expression rather than a pre-evaluated value.

---

## 7.2 The three rules

### Storage must not allow anonymous blob access

```json
{
  "if": {
    "allOf": [
      { "field": "type", "equals": "Microsoft.Storage/storageAccounts" },
      { "field": "Microsoft.Storage/storageAccounts/allowBlobPublicAccess", "notEquals": "false" }
    ]
  },
  "then": { "effect": "[parameters('effect')]" }
}
```

`notEquals: "false"` rather than `equals: "true"` — that is intentional. The property may be
absent, and an absent property is not `true`, so `equals: "true"` would let an unset account
through.

### Data services must not be reachable from the internet

```json
"anyOf": [
  { "allOf": [ { "field": "type", "equals": "Microsoft.Storage/storageAccounts" },
               { "field": "Microsoft.Storage/storageAccounts/publicNetworkAccess", "notEquals": "Disabled" } ] },
  { "allOf": [ { "field": "type", "equals": "Microsoft.DBforPostgreSQL/flexibleServers" },
               { "field": "Microsoft.DBforPostgreSQL/flexibleServers/network.publicNetworkAccess", "notEquals": "Disabled" } ] },
  { "allOf": [ { "field": "type", "equals": "Microsoft.KeyVault/vaults" },
               { "field": "Microsoft.KeyVault/vaults/networkAcls.defaultAction", "notEquals": "Deny" } ] }
]
```

Look at the third branch. Key Vault is checked on `networkAcls.defaultAction`, not on
`publicNetworkAccess` — because this platform deliberately leaves the latter `Enabled` so
the ARM provider can write secrets ([chapter 03](03-platform-services.md#34-key-vault-two-switches-that-look-wrong-until-they-dont)).

**This is the reason the definitions are custom.** A built-in policy demanding
`publicNetworkAccess: Disabled` on every vault would reject the platform it was assigned to
protect. Governance has to encode the decisions the architecture actually made, not the ones
a generic rule assumes.

### App Service must be HTTPS-only on a current TLS version

```json
"anyOf": [
  { "field": "Microsoft.Web/sites/httpsOnly", "notEquals": "true" },
  { "field": "Microsoft.Web/sites/siteConfig.minTlsVersion", "less": "[parameters('minimumTlsVersion')]" }
]
```

A second parameter — `minimumTlsVersion` — so the floor can be raised to `1.3` at assignment
time without editing the definition.

### Finding aliases

`Microsoft.DBforPostgreSQL/flexibleServers/network.publicNetworkAccess` is an **alias**, and
aliases are not guessable. List them:

```bash
az provider show --namespace Microsoft.DBforPostgreSQL --expand "resourceTypes/aliases" --query "resourceTypes[?resourceType=='flexibleServers'].aliases[].name" -o tsv
```

A wrong alias does not error. The condition simply never matches, and you get a policy that
appears to be enforcing and is not — the failure mode worth being paranoid about.

---

## 7.3 Initiative and assignment: two scopes, deliberately

```bicep
targetScope = 'subscription'   // policy-definitions.bicep
```

Definitions and the initiative live at subscription scope, because that is the lowest scope
a definition can exist at. The **assignment** lands on individual resource groups:

```bicep
module platformPolicyAssignment 'modules/governance/policy-assignment.bicep' = {
  scope: platformResourceGroup
  params: {
    name: '${workload}-baseline'
    policySetDefinitionId: policyDefinitions.outputs.initiativeId
    enforcementMode: policyEnforcementMode
  }
  dependsOn: [ keyVault, storage ]
}
```

Widening the scope later is one parameter. Narrowing it after a Deny effect has blocked
something unrelated across the subscription is a conversation with other people.

`dependsOn` is doing real work here. A Deny assignment that lands mid-deployment blocks the
very resources it was written to describe, and the failure reads like a template bug.

### Two modes worth knowing

```bicep
param enforcementMode 'Default' | 'DoNotEnforce' = 'Default'
```

`DoNotEnforce` is what-if for policy: evaluation runs and compliance is recorded, but nothing
is blocked. It is how a Deny policy is introduced to an environment that already has
resources in it.

```bicep
nonComplianceMessages: [
  { message: 'This platform requires private networking. See docs/07-governance.md.' }
]
```

That message is returned in the deployment error. The difference between "denied by policy"
and a support ticket is usually one sentence.

### No DeployIfNotExists, on purpose

Every rule here uses `Audit`, `Deny` or `Disabled`. None uses `deployIfNotExists` or
`modify`, which would require the assignment to carry a managed identity and that identity to
hold a role — turning a Contributor-friendly lab into one that needs User Access
Administrator on every assignment. Remediation policy is powerful and is a different lab.

---

## 7.4 Watch it deny something

The platform complies, so nothing is blocked during a normal deployment. Break it
deliberately:

```bash
az group create --name rg-policy-test --location westeurope
```

```bash
az policy assignment create --name ztwp-baseline-test --resource-group rg-policy-test --policy-set-definition ztwp-zero-trust-baseline
```

Now try to create a storage account the policy hates:

```bash
az storage account create --name sttestpolicy$RANDOM --resource-group rg-policy-test --location westeurope --sku Standard_LRS --allow-blob-public-access true
```

Expected:

```
(RequestDisallowedByPolicy) Resource 'sttestpolicy…' was disallowed by policy.
Policy identifiers: '[{"policyAssignment":{"name":"ztwp-baseline-test"…
```

The deployment never happened. Not "was created and flagged" — refused.

Then the same command with `--allow-blob-public-access false --public-network-access Disabled`
succeeds. Clean up:

```bash
az group delete --name rg-policy-test --yes --no-wait
```

---

## 7.5 Verify

```bash
az policy assignment list --scope /subscriptions/<sub>/resourceGroups/rg-ztwp-platform-dev-weu --query "[].{name:name, mode:enforcementMode, definition:policyDefinitionId}" -o table
```

```bash
az policy state summarize --resource-group rg-ztwp-platform-dev-weu --query "value[0].results" -o json
```

Compliance evaluation runs on a schedule and lags a deployment by up to 30 minutes. Force
it:

```bash
az policy state trigger-scan --resource-group rg-ztwp-platform-dev-weu
```

---

## Exercises

1. **Add a fourth rule** requiring the four platform tags on every resource, and watch it
   fail against something you created by hand in an earlier exercise.

2. **Deny by region.** Write a rule that only permits `westeurope` and `germanywestcentral`,
   assign it, and try to deploy to `eastus`. This is the single most effective cost control
   in most organisations.

3. **Audit first.** Set `policyEnforcementMode = 'DoNotEnforce'`, redeploy, and confirm the
   non-compliant storage account is now *recorded* rather than blocked. That is the migration
   path for an existing environment.

---

## Checkpoint

- [ ] Three definitions and one initiative exist at subscription scope
- [ ] Two assignments exist, each on one resource group
- [ ] A non-compliant storage account is refused with `RequestDisallowedByPolicy`
- [ ] You can explain why the Key Vault rule checks `networkAcls.defaultAction`

---

Next: [08 — Deployment stacks](08-deployment-stacks.md)
