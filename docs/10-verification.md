# 10 — Verification: the proof matrix

> Every claim this platform makes, the command that tests it, and the output that would
> appear if the claim were false. A control that cannot be tested is a diagram.

**Time:** 30 minutes · **Cost:** none

**Scripted version:** [`scripts/verify.ps1`](../scripts/verify.ps1) ·
[`scripts/verify.sh`](../scripts/verify.sh)

---

## The matrix

| # | Claim | Command | Pass | Fail looks like |
|---|---|---|---|---|
| 1 | The app has no usable public route | `curl -sI https://<app>.azurewebsites.net/` | `403` | `200` — the access restriction is gone and the WAF is bypassable |
| 2 | The gateway is the way in | `curl -s -o /dev/null -w '%{http_code}' http://<gw>/` | `200` | `502` — backend unhealthy; see chapter 05 |
| 3 | The WAF blocks injection | `curl "http://<gw>/?id=1' OR '1'='1"` | `403` | `200` — policy in Detection, or not attached |
| 4 | …and path traversal | `curl "http://<gw>/?file=../../etc/passwd"` | `403` | `200` — same |
| 5 | Storage is off the internet | `az storage blob list --account-name <st> --container-name app-data --auth-mode login` | network error | a listing — `publicNetworkAccess` is not `Disabled` |
| 6 | There is no account key to leak | `az storage account show --name <st> --query allowSharedKeyAccess` | `false` | `true` |
| 7 | The database is off the internet | `az postgres flexible-server show … --query network.publicNetworkAccess` | `Disabled` | `Enabled` |
| 8 | Private DNS resolves privately | `nameresolver <st>.blob.core.windows.net` in Kudu | `10.20.2.x` | a public IP — the zone link is missing |
| 9 | The app config holds no password | `az webapp config appsettings list … --query "[?name=='DATABASE_URL'].value"` | `@Microsoft.KeyVault(SecretUri=…)` | a connection string with a password in it |
| 10 | The identity has exactly two roles | `az role assignment list --assignee <principalId> --all` | Key Vault Secrets User + Storage Blob Data Contributor | anything at subscription scope |
| 11 | Policy denies a regression | create a public storage account | `RequestDisallowedByPolicy` | it succeeds |
| 12 | The stack denies portal drift | change the plan SKU in the portal | `RequestDisallowedByAzure` | it succeeds |
| 13 | The pipeline holds no secret | `gh run view <id> --log \| grep -i password` | names only | a value |

Run it all at once:

```bash
./scripts/verify.ps1 -Environment dev
```

---

## 10.1 The two different 403s

Checks 1 and 3 both return `403`, from different controls, and telling them apart is the
single most useful diagnostic skill in this platform.

```bash
curl -sI https://<app>.azurewebsites.net/ | head -3
```

```
HTTP/1.1 403 Ip Forbidden
```

That string — **`Ip Forbidden`** — is App Service's access restriction talking. The request
reached the app's front door and was refused by source.

```bash
curl -sI "http://<gateway-fqdn>/?id=1%27%20OR%20%271%27%3D%271" | head -3
```

```
HTTP/1.1 403 Forbidden
Server: Microsoft-Azure-Application-Gateway/v2
```

The `Server` header is the WAF. The request never left the gateway.

If check 1 returns 200, the request bypassed the firewall entirely — the app is directly
reachable and everything in chapter 05 became decorative.

---

## 10.2 Proving DNS from inside the VNet

The only check that needs a shell inside the network. Open:

```
https://<app-name>.scm.azurewebsites.net/webssh/host
```

```bash
nameresolver <storage-account>.blob.core.windows.net
```

Expected:

```
Server: 168.63.129.16
Non-authoritative answer:
Name: <account>.privatelink.blob.core.windows.net
Addresses: 10.20.2.5
```

Three things to read there:

- **168.63.129.16** — Azure's platform DNS resolver, reachable from inside every VNet.
- the **CNAME to `privatelink.…`** — Azure's public DNS handing off to the private zone.
- **10.20.2.5** — the endpoint NIC in `snet-pep`.

Run the same lookup from your laptop and you get a public address. Both answers are correct;
the difference *is* the private endpoint.

```bash
tcpping <postgres>.postgres.database.azure.com:5432
```

A connection from Kudu, nothing from your laptop.

---

## 10.3 Reading the private IPs from outside

```bash
az network private-endpoint list --query "[].{name:name, nic:networkInterfaces[0].id}" -o tsv
```

```bash
az network nic show --ids <nicId> --query "ipConfigurations[0].properties.privateIPAddress" -o tsv
```

Two commands rather than one, because the private IP cannot be produced as a template output
— the NIC's name is not knowable at the start of the deployment. The reasoning is in
[chapter 03](03-platform-services.md#a-small-bicep-lesson-hiding-in-the-outputs) and in the
comments of [`private-endpoint.bicep`](../infra/modules/shared/private-endpoint.bicep).

---

## 10.4 Confirming the blocks reached the log

Roughly five minutes after the WAF checks:

```kusto
AGWFirewallLogs
| where TimeGenerated > ago(30m)
| where Action == "Blocked"
| project TimeGenerated, ClientIp, RequestUri, Message
| order by TimeGenerated desc
```

Two rows, your own IP, and the rule that fired. That closes the loop: the control acted, and
the action is recorded somewhere an investigator can find it.

---

## 10.5 What is deliberately not proven

Being straight about the limits:

- **No penetration test.** These checks confirm the controls are configured and reachable as
  designed. They do not establish that the WAF stops a determined attacker — the CRS is
  bypassable, and Prevention mode with default rules is a baseline, not a guarantee.
- **No load test.** The gateway autoscales between 1 and 2 instances in the dev profile;
  nothing here establishes behaviour under real traffic.
- **No data-plane authorisation test against PostgreSQL.** Connectivity is proven with
  `tcpping`; whether the application's identity can actually query is a chapter this lab
  does not have.
- **No egress control.** Outbound traffic from the app is unrestricted. Azure Firewall in the
  hub with a route table on the spoke would fix that, at roughly USD 1.25 an hour.

---

## Exercises

1. **Break one thing and watch exactly one check fail.** Remove the `snet-agw` access
   restriction: check 1 flips to 200 and nothing else changes. That is what a good test
   matrix looks like — one failure, one cause.

2. **Write check 14.** Prove that the NSG on `snet-pep` does *not* filter private endpoint
   traffic while `privateEndpointNetworkPolicies` is `Disabled`
   ([chapter 02](02-network.md#the-nsg-that-does-not-do-what-it-looks-like-it-does)), then
   flip it to `Enabled` and prove that it does.

3. **Add the matrix to CI** as a post-deployment job in
   [`deploy.yml`](../.github/workflows/deploy.yml), so every deployment ends by proving
   itself rather than by reporting success.

---

## Checkpoint

- [ ] All thirteen rows pass, or you can explain the ones that do not
- [ ] You can tell the two 403s apart from the response headers alone
- [ ] `nameresolver` from Kudu returns a `10.20.2.x` address
- [ ] The blocked requests are visible in `AGWFirewallLogs`

---

Next: [11 — Testing Bicep](11-testing.md)
