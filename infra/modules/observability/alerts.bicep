metadata description = '''
Two alerts, chosen because they fail in opposite directions.

  Unhealthy backend   a metric alert on the gateway. Fires when the probe stops passing,
                      which in this platform almost always means the private DNS or the
                      access restriction is wrong rather than the app being down.

  WAF block burst     a log alert over AGWFirewallLogs. A handful of blocks is background
                      noise on any public address; a burst is either an attack or a rule
                      that needs an exclusion, and both are worth a message.

Both hang off one action group. Leave alertEmail empty and neither alert is deployed —
alerts with nowhere to go are worse than no alerts, because they look like coverage.
'''

param name string
param location string
param tags object

@description('Gateway to watch.')
param applicationGatewayId string

@description('Workspace the log alert queries.')
param workspaceId string

@description('Recipient for both alerts. Empty disables the whole module.')
param alertEmail string = ''

@description('Blocked requests in five minutes before the log alert fires.')
param wafBlockThreshold int = 10

var enabled = !empty(alertEmail)

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (enabled) {
  name: 'ag-${name}'
  // Action groups are global; the resource group still has a region, the resource does not.
  location: 'global'
  tags: tags
  properties: {
    groupShortName: substring(name, 0, min(length(name), 12))
    enabled: true
    emailReceivers: [
      {
        name: 'operator'
        emailAddress: empty(alertEmail) ? 'placeholder@example.com' : alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource unhealthyBackendAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enabled) {
  name: 'alert-${name}-unhealthy-backend'
  location: 'global'
  tags: tags
  properties: {
    description: 'Application Gateway reports at least one unhealthy backend host.'
    severity: 1
    enabled: true
    scopes: [
      applicationGatewayId
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'UnhealthyHostCount'
          metricNamespace: 'Microsoft.Network/applicationGateways'
          metricName: 'UnhealthyHostCount'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Maximum'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    autoMitigate: true
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

resource wafBlockAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (enabled) {
  name: 'alert-${name}-waf-blocks'
  location: location
  tags: tags
  properties: {
    displayName: 'WAF blocked request burst'
    description: 'More than the configured number of blocked requests within five minutes.'
    severity: 2
    enabled: true
    scopes: [
      workspaceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          // AGWFirewallLogs is the resource-specific table. It only exists because the
          // gateway's diagnostic setting uses logAnalyticsDestinationType: Dedicated.
          query: '''
AGWFirewallLogs
| where Action == "Blocked"
| summarize BlockedRequests = count() by bin(TimeGenerated, 5m)
'''
          timeAggregation: 'Total'
          metricMeasureColumn: 'BlockedRequests'
          operator: 'GreaterThan'
          threshold: wafBlockThreshold
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

output actionGroupId string = enabled ? actionGroup.id : ''
