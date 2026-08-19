metadata description = '''
Application Gateway v2 — the only public frontend in the platform.

The backend is the App Service default hostname, not an IP address. That matters: the
gateway resolves that hostname from inside the spoke VNet, so if the private DNS zone and
the private endpoint are wired correctly it reaches the app privately, and if they are not
it silently reaches the public endpoint instead. The health probe is therefore also the
integration test for the DNS work in chapter 02.

Host headers are picked from the backend address rather than overridden, because App
Service routes by Host: send it the gateway's hostname and it answers 404 for a site it
does not host.
'''

param name string
param location string
param tags object

@description('Dedicated gateway subnet. Nothing else may live in it.')
param subnetId string

@description('WAF_v2 enables the firewall policy. Standard_v2 exists only as a cost escape hatch.')
param skuName 'Standard_v2' | 'WAF_v2' = 'WAF_v2'

@minValue(1)
param minCapacity int = 1

@minValue(2)
param maxCapacity int = 3

@description('Spread instances across availability zones. Free on the gateway; leave on unless the region lacks zones.')
param zoneRedundant bool = true

@description('Backend FQDN — the App Service default hostname.')
param backendHostName string

@description('WAF policy resource ID. Ignored when the SKU is Standard_v2.')
param firewallPolicyId string = ''

@description('DNS label for the public IP: <label>.<region>.cloudapp.azure.com.')
param publicIpDnsLabel string

@description('''
Key Vault URI of a certificate, plus the user-assigned identity allowed to read it. Supply
both to get a real HTTPS listener and an HTTP-to-HTTPS redirect; leave both empty and the
gateway listens on port 80 only, which is enough to exercise the WAF.

The obvious name for this parameter is httpsCertificateSecretId, matching the ARM property
it feeds. The secure-secrets-in-params linter rule rejects that name: it matches on the
word "secret" and demands @secure(), which would then make the value unreadable in what-if
output for something that is only ever an address.
''')
param certificateKeyVaultUri string = ''

param certificateIdentityId string = ''

param workspaceId string = ''

var enableHttps = !empty(certificateKeyVaultUri) && !empty(certificateIdentityId)
var gatewayId = resourceId('Microsoft.Network/applicationGateways', name)

var frontendIpName = 'appGwPublicFrontendIp'
var backendPoolName = 'appServiceBackendPool'
var httpSettingsName = 'httpsBackendSettings'
var probeName = 'appServiceHealthProbe'
var httpListenerName = 'httpListener'
var httpsListenerName = 'httpsListener'
var certificateName = 'listenerCertificate'

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${name}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  zones: zoneRedundant ? ['1', '2', '3'] : []
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: publicIpDnsLabel
    }
  }
}

resource gateway 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: name
  location: location
  tags: tags
  zones: zoneRedundant ? ['1', '2', '3'] : []
  identity: empty(certificateIdentityId)
    ? null
    : {
        type: 'UserAssigned'
        userAssignedIdentities: {
          '${certificateIdentityId}': {}
        }
      }
  properties: {
    sku: {
      name: skuName
      tier: skuName
    }
    autoscaleConfiguration: {
      minCapacity: minCapacity
      maxCapacity: maxCapacity
    }
    firewallPolicy: skuName == 'WAF_v2' && !empty(firewallPolicyId)
      ? {
          id: firewallPolicyId
        }
      : null
    gatewayIPConfigurations: [
      {
        name: 'appGwIpConfig'
        properties: {
          subnet: {
            id: subnetId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: frontendIpName
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    frontendPorts: concat(
      [
        {
          name: 'port80'
          properties: {
            port: 80
          }
        }
      ],
      enableHttps
        ? [
            {
              name: 'port443'
              properties: {
                port: 443
              }
            }
          ]
        : []
    )
    sslCertificates: enableHttps
      ? [
          {
            name: certificateName
            properties: {
              keyVaultSecretId: certificateKeyVaultUri
            }
          }
        ]
      : []
    sslPolicy: {
      policyType: 'Predefined'
      policyName: 'AppGwSslPolicy20220101'
    }
    backendAddressPools: [
      {
        name: backendPoolName
        properties: {
          backendAddresses: [
            {
              fqdn: backendHostName
            }
          ]
        }
      }
    ]
    probes: [
      {
        name: probeName
        properties: {
          protocol: 'Https'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          // Without this the probe sends the gateway's own hostname and App Service
          // answers 404, which presents as a healthy gateway with an unhealthy backend.
          pickHostNameFromBackendHttpSettings: true
          minServers: 0
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: httpSettingsName
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 30
          probe: {
            id: '${gatewayId}/probes/${probeName}'
          }
        }
      }
    ]
    httpListeners: concat(
      [
        {
          name: httpListenerName
          properties: {
            frontendIPConfiguration: {
              id: '${gatewayId}/frontendIPConfigurations/${frontendIpName}'
            }
            frontendPort: {
              id: '${gatewayId}/frontendPorts/port80'
            }
            protocol: 'Http'
            requireServerNameIndication: false
          }
        }
      ],
      enableHttps
        ? [
            {
              name: httpsListenerName
              properties: {
                frontendIPConfiguration: {
                  id: '${gatewayId}/frontendIPConfigurations/${frontendIpName}'
                }
                frontendPort: {
                  id: '${gatewayId}/frontendPorts/port443'
                }
                protocol: 'Https'
                sslCertificate: {
                  id: '${gatewayId}/sslCertificates/${certificateName}'
                }
                requireServerNameIndication: false
              }
            }
          ]
        : []
    )
    redirectConfigurations: enableHttps
      ? [
          {
            name: 'httpToHttps'
            properties: {
              redirectType: 'Permanent'
              targetListener: {
                id: '${gatewayId}/httpListeners/${httpsListenerName}'
              }
              includePath: true
              includeQueryString: true
            }
          }
        ]
      : []
    requestRoutingRules: concat(
      [
        {
          name: 'httpRule'
          properties: {
            ruleType: 'Basic'
            priority: 100
            httpListener: {
              id: '${gatewayId}/httpListeners/${httpListenerName}'
            }
            // On port 80 the gateway either redirects to HTTPS or serves the app,
            // depending on whether a certificate was supplied.
            backendAddressPool: enableHttps
              ? null
              : {
                  id: '${gatewayId}/backendAddressPools/${backendPoolName}'
                }
            backendHttpSettings: enableHttps
              ? null
              : {
                  id: '${gatewayId}/backendHttpSettingsCollection/${httpSettingsName}'
                }
            redirectConfiguration: enableHttps
              ? {
                  id: '${gatewayId}/redirectConfigurations/httpToHttps'
                }
              : null
          }
        }
      ],
      enableHttps
        ? [
            {
              name: 'httpsRule'
              properties: {
                ruleType: 'Basic'
                priority: 110
                httpListener: {
                  id: '${gatewayId}/httpListeners/${httpsListenerName}'
                }
                backendAddressPool: {
                  id: '${gatewayId}/backendAddressPools/${backendPoolName}'
                }
                backendHttpSettings: {
                  id: '${gatewayId}/backendHttpSettingsCollection/${httpSettingsName}'
                }
              }
            }
          ]
        : []
    )
  }
}

// Dedicated destination writes to AGWAccessLogs / AGWFirewallLogs instead of dumping
// everything into the shared AzureDiagnostics table. The KQL in chapter 06 assumes it.
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(workspaceId)) {
  name: 'diag-to-law'
  scope: gateway
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output id string = gateway.id
output name string = gateway.name
output publicIpAddress string = publicIp.properties.ipAddress
output fqdn string = publicIp.properties.dnsSettings.fqdn
