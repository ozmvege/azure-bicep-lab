# 06 — Observability: one workspace, the right tables, two alerts

> Where a blocked request shows up, how to find it, and which two alerts are worth the noise
> they will eventually make.

**Time:** 30 minutes · **Cost:** ~0 — 30-day retention and 1 GB/day sit inside the free
allowance

**Files:** [`monitoring.bicep`](../infra/modules/observability/monitoring.bicep) ·
[`alerts.bicep`](../infra/modules/observability/alerts.bicep)

---

## 6.1 One workspace for the platform

```bicep
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
    workspaceCapping: { dailyQuotaGb: dailyQuotaGb }
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}
```

One workspace, in the platform group, for everything. Splitting logs per resource group
feels tidier and makes the one query that matters — correlate a blocked request at the
gateway with what the app did next — impossible to write.

`workspaceCapping.dailyQuotaGb: 1` is a hard stop. A lab should not be able to ingest its
way into a surprise, and a runaway diagnostic setting is the classic way that happens.

Every service in the platform points a diagnostic setting here. They all look like this:

```bicep
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(workspaceId)) {
  name: 'diag-to-law'
  scope: keyVault
  properties: {
    workspaceId: workspaceId
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}
```

`categoryGroup: 'allLogs'` rather than naming each category, because category names differ
per resource type and go stale as Azure adds new ones.

---

## 6.2 The one setting that changes every query

```bicep
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: gateway
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
  }
}
```

`logAnalyticsDestinationType: 'Dedicated'` sends gateway logs to **resource-specific
tables** — `AGWAccessLogs`, `AGWFirewallLogs`, `AGWPerformanceLogs` — instead of dumping
everything into the shared `AzureDiagnostics` table.

Why it matters:

| | `AzureDiagnostics` (default) | Dedicated tables |
|---|---|---|
| Schema | one wide table, every resource type, columns suffixed `_s`, `_d` | typed columns per resource type |
| A WAF query | `where Category == "ApplicationGatewayFirewallLog" \| where action_s == "Blocked"` | `AGWFirewallLogs \| where Action == "Blocked"` |
| Column limit | 500 across all resource types in the workspace | per table |
| Cost | identical | identical |

Every query below assumes Dedicated. If you inherited a workspace on the legacy schema, the
`AzureDiagnostics` equivalent is given alongside the first one.

---

## 6.3 The queries

Open the workspace → **Logs**, and give it a few minutes after generating traffic.

### What did the WAF block?

```kusto
AGWFirewallLogs
| where TimeGenerated > ago(1h)
| where Action == "Blocked"
| project TimeGenerated, ClientIp, RequestUri, RuleId=RuleSetType, Message, Details
| order by TimeGenerated desc
```

Legacy schema:

```kusto
AzureDiagnostics
| where Category == "ApplicationGatewayFirewallLog"
| where action_s == "Blocked"
| project TimeGenerated, clientIp_s, requestUri_s, ruleId_s, Message
```

Run your injection from [chapter 05](05-edge-waf.md), wait, and find it. This is the moment
the platform stops being a diagram.

### Which rules fire most — the input to your exclusions

```kusto
AGWFirewallLogs
| where TimeGenerated > ago(24h)
| summarize Hits = count() by RuleId, Action
| order by Hits desc
```

In Detection mode this list is the exclusion backlog. Anything at the top that is legitimate
traffic needs an exclusion before Prevention goes on.

### Is the backend healthy, in numbers rather than a portal blade?

```kusto
AGWAccessLogs
| where TimeGenerated > ago(1h)
| summarize Requests = count() by HttpStatus = httpStatus_d, BackendStatus = backendHttpStatus_d
| order by Requests desc
```

### Who touched the Key Vault?

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where TimeGenerated > ago(24h)
| project TimeGenerated, OperationName, CallerIPAddress, identity_claim_appid_g, ResultSignature
| order by TimeGenerated desc
```

Run this after the app has started. The caller you see fetching `database-connection-string`
is the app's managed identity — the reference from [chapter 04](04-compute.md) resolving,
recorded as an auditable event.

### The correlation that justifies one workspace

```kusto
let blocked =
    AGWFirewallLogs
    | where Action == "Blocked"
    | project TimeGenerated, ClientIp, RequestUri;
let served =
    AGWAccessLogs
    | project TimeGenerated, ClientIp = clientIp_s, RequestUri = requestUri_s, Status = httpStatus_d;
blocked
| join kind=leftouter (served) on ClientIp
| summarize Blocked = count(), Served = countif(isnotempty(Status)) by ClientIp
| order by Blocked desc
```

One client, both tables, one query. Two workspaces and this is a manual export.

---

## 6.4 Two alerts

```bicep
param alertEmail string = ''
var enabled = !empty(alertEmail)
```

Leave `alertEmail` empty and neither alert nor the action group is deployed. That is
deliberate: alerts with nowhere to go are worse than no alerts, because they look like
coverage.

### Unhealthy backend — a metric alert

```bicep
criteria: {
  'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
  allOf: [
    {
      metricNamespace: 'Microsoft.Network/applicationGateways'
      metricName: 'UnhealthyHostCount'
      operator: 'GreaterThan'
      threshold: 0
      timeAggregation: 'Maximum'
    }
  ]
}
```

In this platform an unhealthy backend almost never means the app is down. It means the
access restriction, the service endpoint or the private DNS changed — which is to say, it is
a *network* alert wearing an application costume.

### WAF block burst — a log alert

```bicep
query: '''
AGWFirewallLogs
| where Action == "Blocked"
| summarize BlockedRequests = count() by bin(TimeGenerated, 5m)
'''
timeAggregation: 'Total'
metricMeasureColumn: 'BlockedRequests'
operator: 'GreaterThan'
threshold: wafBlockThreshold
```

A handful of blocks is background radiation on any public address. A burst is either an
attack or a rule that needs an exclusion, and both deserve a message. The threshold —
10 in five minutes — is a starting point; set it from your own traffic after a day.

Note that the log alert only works because of the Dedicated destination type. On the legacy
schema the query must be rewritten, and the alert quietly returns nothing until it is.

---

## 6.5 Verify

```bash
az monitor diagnostic-settings list --resource <gateway-resource-id> -o table
```

```bash
az monitor log-analytics query --workspace <workspace-customer-id> --analytics-query "AGWFirewallLogs | where TimeGenerated > ago(1h) | summarize count() by Action" -o table
```

If `AGWFirewallLogs` does not exist yet, either no traffic has been blocked or the
diagnostic setting is not Dedicated. Send one injection and wait five minutes before
concluding anything.

---

## Exercises

1. **Generate and find your own attack.** Send ten different malicious-looking requests,
   then write a query that groups them by rule ID and tells you which one is noisiest.

2. **Add an alert** for `AppServiceHTTPLogs` showing 5xx responses above a threshold, using
   the existing scheduled query rule as a template. Notice you now need a second action
   group — or a shared one, which is the better design.

3. **Cost check.** Query `Usage | where TimeGenerated > ago(24h) | summarize sum(Quantity)
   by DataType` and see which resource is loudest. In this platform it is usually the
   gateway access log.

---

## Checkpoint

- [ ] Every service has a diagnostic setting pointing at the one workspace
- [ ] `AGWFirewallLogs` contains the request you blocked in chapter 05
- [ ] You can name the rule ID that fired
- [ ] Both alerts exist (or you know why they do not)

---

Next: [07 — Governance](07-governance.md)
