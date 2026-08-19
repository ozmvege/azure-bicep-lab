# 05 — Edge: Application Gateway and the WAF

> The only public IP in the platform, the OWASP rule set in front of it, and the health
> probe that doubles as an integration test for everything built so far.

**Time:** 45 minutes · **Cost:** ~USD 0.44/hour — **this is the expensive chapter**

**Files:** [`application-gateway.bicep`](../infra/modules/edge/application-gateway.bicep) ·
[`waf-policy.bicep`](../infra/modules/edge/waf-policy.bicep)

---

## 5.1 The backend is a hostname

```bicep
backendAddressPools: [
  {
    name: backendPoolName
    properties: {
      backendAddresses: [ { fqdn: backendHostName } ]
    }
  }
]
```

`backendHostName` is the App Service default hostname — `app-ztwp-dev-weu.azurewebsites.net`
— and not an IP address. The gateway resolves it from inside the spoke VNet, so:

- if the private DNS zone and the app's endpoint or access restriction are wired correctly,
  the gateway reaches the app the way it should;
- if they are not, it silently reaches the *public* endpoint instead, and everything appears
  to work while the traffic path is wrong.

The health probe is therefore also the test for chapters 02 to 04. A healthy backend means
the DNS work landed.

### Host headers

```bicep
backendHttpSettingsCollection: [
  {
    properties: {
      port: 443
      protocol: 'Https'
      pickHostNameFromBackendAddress: true
      probe: { id: '${gatewayId}/probes/${probeName}' }
    }
  }
]
probes: [
  {
    properties: {
      protocol: 'Https'
      path: '/'
      pickHostNameFromBackendHttpSettings: true
      match: { statusCodes: [ '200-399' ] }
    }
  }
]
```

App Service is multi-tenant and routes by `Host`. Send it the gateway's own hostname and it
answers 404 for a site it does not host — which presents as a healthy gateway with an
unhealthy backend, and sends people looking at the network for an hour. Both `pickHostName…`
flags exist to prevent exactly that.

---

## 5.2 Self-referencing IDs

A gateway's listeners, rules, pools and settings all reference each other, and they are all
children of a resource that does not exist yet:

```bicep
var gatewayId = resourceId('Microsoft.Network/applicationGateways', name)
// ...
httpListener: { id: '${gatewayId}/httpListeners/${httpListenerName}' }
```

`resourceId()` composes the ID from the name without needing the resource, which is the
standard way to write a gateway in Bicep. Nothing is deployed twice; ARM resolves the whole
graph in one PUT.

The optional HTTPS path shows how conditional configuration composes:

```bicep
var enableHttps = !empty(certificateKeyVaultUri) && !empty(certificateIdentityId)

frontendPorts: concat(
  [ { name: 'port80', properties: { port: 80 } } ],
  enableHttps ? [ { name: 'port443', properties: { port: 443 } } ] : []
)
```

With a certificate the port-80 rule becomes a permanent redirect and a second rule serves
HTTPS; without one, port 80 serves the app directly. The WAF works identically either way,
which is why the lab's default path needs no certificate and no custom domain.

> **Naming trap.** The parameter is `certificateKeyVaultUri`, not the obvious
> `httpsCertificateSecretId` that matches the ARM property. The `secure-secrets-in-params`
> linter rule matches on the word *secret* and demands `@secure()` — which would hide the
> value in what-if output for something that is only ever an address.

---

## 5.3 The WAF policy as its own resource

```bicep
resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2024-05-01' = {
  properties: {
    policySettings: {
      state: 'Enabled'
      mode: mode                    // Detection or Prevention
      requestBodyCheck: true
      maxRequestBodySizeInKb: 128
      fileUploadLimitInMb: 100
    }
    managedRules: {
      managedRuleSets: [ { ruleSetType: 'OWASP', ruleSetVersion: '3.2' } ]
      exclusions: [ … ]
    }
  }
}
```

A separate policy can be attached to several gateways, to one listener, or to a single
path-based rule, and it can be edited without touching the gateway. Inline WAF configuration
on the gateway is the older model and cannot do any of that.

### Detection first, then Prevention

The two modes:

| Mode | Behaviour | When |
|---|---|---|
| `Detection` | logs the match, forwards the request | first deployment, and after any rule change |
| `Prevention` | logs the match, returns 403 | once the logs are quiet |

Going straight to Prevention on a real application blocks legitimate traffic within the
hour. The CRS is broad by design: rule 942 fires on SQL keywords, 941 on anything resembling
markup, 920 on protocol anomalies. Applications that accept JSON bodies, rich text or file
uploads trip several of them while behaving perfectly.

The workflow: deploy in Detection, run real traffic, query the log (chapter 06), write
exclusions for what you find, then promote.

### Exclusions, with a worked example

```bicep
exclusions: [
  {
    matchVariable: 'RequestHeaderNames'
    selectorMatchOperator: 'Equals'
    selector: 'x-ms-request-id'
  }
]
```

An exclusion tells the WAF to ignore one *part of the request* — one header, one cookie, one
query argument — rather than switching a rule off everywhere. The alternative, disabling
rule 942100 globally, removes SQL injection detection from the entire application to fix one
endpoint.

---

## 5.4 Deploy and watch the backend come up

```bash
./scripts/deploy.ps1 -Environment dev
```

The gateway takes **five to eight minutes** to create, and the backend stays unhealthy for a
minute or two afterwards. That is normal.

```bash
az network application-gateway show-backend-health --name agw-ztwp-dev-weu --resource-group rg-ztwp-app-dev-weu --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address, health:health}" -o table
```

`Healthy`. If it says `Unhealthy`, the reason is almost always one of three things, all
covered in [troubleshooting](troubleshooting.md#the-gateway-backend-is-unhealthy):

1. the App Service access restriction does not allow `snet-agw`;
2. the `Microsoft.Web` service endpoint is missing from that subnet;
3. the probe is not picking the hostname from the backend.

---

## 5.5 Exercise the WAF

Through the gateway, an ordinary request:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://<gateway-fqdn>/
```

**200.**

Now the same gateway, with an obvious injection attempt:

```bash
curl -s -o /dev/null -w '%{http_code}\n' "http://<gateway-fqdn>/?id=1%27%20OR%20%271%27%3D%271"
```

**403.** The request never reached the application.

A different rule family, to show the first was not a coincidence:

```bash
curl -s -o /dev/null -w '%{http_code}\n' "http://<gateway-fqdn>/?file=../../etc/passwd"
```

**403.**

And the control that matters most — the same injection sent straight to the app, bypassing
the gateway:

```bash
curl -s -o /dev/null -w '%{http_code}\n' "https://<app>.azurewebsites.net/?id=1%27%20OR%20%271%27%3D%271"
```

**403 Ip Forbidden** — but from the *access restriction*, not the WAF. Two different
controls returning the same status code for different reasons is a useful thing to have
noticed: remove the access restriction and this request succeeds, having skipped the
firewall entirely.

---

## Exercises

1. **Switch to Detection** — set `wafPolicyMode = 'Detection'` in the dev parameter file,
   redeploy, and repeat the injection. Now it returns 200 and is still logged. Read the log
   entry in chapter 06 and confirm the rule ID is identical; only `Action` changed.

2. **Find the rule that fires.** Send `<script>alert(1)</script>` as a query argument and
   identify the rule ID in `AGWFirewallLogs`. Then write an exclusion narrow enough to allow
   that one argument without disabling the rule.

3. **Bot protection.** Set `enableBotProtection = true` in
   [`waf-policy.bicep`](../infra/modules/edge/waf-policy.bicep) and watch what a plain
   `curl` gets classified as. This is why it is off by default.

4. **Add a certificate.** Create a self-signed certificate in the Key Vault, create a
   user-assigned identity with `Key Vault Secrets User`, and pass both parameters. Port 80
   becomes a redirect and the platform speaks HTTPS end to end.

---

## Checkpoint

- [ ] The gateway reports a healthy backend
- [ ] A normal request through the gateway returns 200
- [ ] SQL injection and path traversal through the gateway return 403
- [ ] The app's own hostname returns 403 for a different reason, and you can say which

---

Next: [06 — Observability](06-observability.md)
