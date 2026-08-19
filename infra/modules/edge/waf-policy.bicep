metadata description = '''
The WAF policy, kept as its own resource rather than inline on the gateway.

A separate policy can be attached to several gateways, to a single listener, or to one
path-based rule, and it can be edited without touching the gateway. Exclusions live here
too — the first thing anyone needs after switching Prevention on and watching a legitimate
request get blocked.
'''

param name string
param location string
param tags object

@description('Detection logs and lets everything through. Prevention blocks. Start in Detection, promote once the logs are quiet.')
param mode 'Detection' | 'Prevention' = 'Prevention'

@description('OWASP Core Rule Set version.')
param ruleSetVersion string = '3.2'

@description('Bot protection ruleset. Off by default: it is chatty against synthetic lab traffic.')
param enableBotProtection bool = false

resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    policySettings: {
      state: 'Enabled'
      mode: mode
      requestBodyCheck: true
      maxRequestBodySizeInKb: 128
      fileUploadLimitInMb: 100
    }
    managedRules: {
      managedRuleSets: concat(
        [
          {
            ruleSetType: 'OWASP'
            ruleSetVersion: ruleSetVersion
          }
        ],
        enableBotProtection
          ? [
              {
                ruleSetType: 'Microsoft_BotManagerRuleSet'
                ruleSetVersion: '1.0'
              }
            ]
          : []
      )
      // Worked example of an exclusion. The Kudu deployment endpoint sends headers the
      // CRS reads as protocol anomalies; the alternative to an exclusion is disabling a
      // rule globally, which is a much larger hole.
      exclusions: [
        {
          matchVariable: 'RequestHeaderNames'
          selectorMatchOperator: 'Equals'
          selector: 'x-ms-request-id'
        }
      ]
    }
  }
}

output id string = wafPolicy.id
output name string = wafPolicy.name
