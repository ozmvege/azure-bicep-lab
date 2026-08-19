# Cost and cleanup

> What this lab costs per hour, how to make Azure tell you before it becomes a problem, and
> how to prove nothing survived.

---

## What it costs

Prices are West Europe list prices at the time of writing, in USD, and are indicative — check
the [pricing calculator](https://azure.microsoft.com/pricing/calculator/) for your region.

| Resource | Profile | ~USD/hour | ~USD/month if left running |
|---|---|---|---|
| **Application Gateway WAF_v2** | dev | **0.44** + capacity units | **~320** |
| App Service Plan B1 | dev | 0.018 | 13 |
| PostgreSQL Flexible B1ms + 32 GB | dev | 0.017 | 12 |
| Private endpoints × 6 | dev | 0.06 | 44 |
| Public IP (Standard, static) | dev | 0.005 | 4 |
| Log Analytics | dev | ~0 | first 5 GB/month free |
| Key Vault | dev | ~0 | per operation |
| Storage (LRS, near-empty) | dev | ~0 | pennies |
| VNets, subnets, NSGs, DNS zones, peering | dev | 0 | 0 |
| **Total, dev profile** | | **~0.55** | **~390** |
| *Azure Bastion Basic* | optional | *0.19* | *139* |
| *Jumpbox B2s* | optional | *0.05* | *35* |

**A full lab run — deploy, verify, tear down — takes about two hours and costs roughly USD
0.60 to 1.50.**

The prod profile is a different animal: P1v3 × 3 instances, GeneralPurpose PostgreSQL with
zone-redundant HA, and a gateway scaled to 2–10. Around **USD 2.50 an hour**. Deploy it to
compare configurations, not to leave running.

### Where the money actually is

The gateway is 80 % of the bill, and its fixed cost is charged whether or not a single
request arrives. There is no stop button — an Application Gateway cannot be deallocated the
way a VM can. **Deleting it is the only way to stop paying for it.** That single fact is why
teardown is a workflow, a script and a chapter in this repository rather than a line at the
bottom of the README.

### Cheaper variants

| Want | Change | Saves |
|---|---|---|
| Skip the database | `deployDatabase = false` | ~0.03/hour |
| Skip the WAF, keep everything else | `applicationGateway: 'Standard_v2'` | ~0.10/hour |
| Skip the edge entirely | comment out the gateway module in `main.bicep` | ~0.44/hour |
| Everything except the gateway | as above — the network, private endpoints, identity and policy chapters all still work | |

Chapters 02, 03, 04, 07, 08, 09, 11 and 12 need no gateway at all. Only chapters 05, 06 and
parts of 10 do.

---

## Set a budget before you start

```bash
az account show --query id -o tsv
```

```bash
az consumption budget create --budget-name ztwp-lab --amount 10 --time-grain Monthly --start-date $(date -u +%Y-%m-01) --end-date $(date -u -d '+1 year' +%Y-%m-01) --category Cost
```

The portal route — **Cost Management + Billing → Budgets → Add** — also lets you attach
alerts at 50/80/100 % with an email address, which the CLI form above does not.

For a lab, also set a **cost anomaly alert**: Cost Management → Cost alerts → Anomaly alerts.
It notices a gateway left running long before the monthly budget does.

Watch the current spend:

```bash
az consumption usage list --start-date $(date -u -d '-1 day' +%Y-%m-%d) --end-date $(date -u +%Y-%m-%d) --query "[?contains(instanceName, 'ztwp')].{resource:instanceName, cost:pretaxCost, currency:currencyCode}" -o table
```

Cost data lags by 8 to 24 hours. It is a check, not a monitor.

---

## Teardown

```bash
./scripts/teardown.ps1 -Environment dev
```

or

```bash
az stack sub delete --name ztwp-dev --action-on-unmanage deleteAll --yes
```

`deleteAll` — not `deleteResources`, and certainly not `detachAll`. It removes the managed
resources **and** their resource groups. See
[chapter 08](08-deployment-stacks.md#81-what-a-plain-deployment-does-not-do).

From CI, [`destroy.yml`](../.github/workflows/destroy.yml) does the same and requires typing
`DESTROY`.

---

## Prove it worked

```bash
az group list --query "[?starts_with(name, 'rg-ztwp-')].name" -o tsv
```

Only `rg-ztwp-bootstrap-dev-weu` should appear. It is deliberately outside the stack — it
holds the database password so the next run does not need a new one.

```bash
az stack sub list --query "[].name" -o tsv
```

Empty.

The two things that hide from a resource-group listing:

```bash
az keyvault list-deleted --query "[].{name:name, scheduledPurge:properties.scheduledPurgeDate}" -o table
```

Soft-deleted vaults still hold their names (7 days here, since purge protection is off).
Purge them if you want the name back sooner:

```bash
az keyvault purge --name <vault-name>
```

```bash
az policy definition list --query "[?policyType=='Custom' && starts_with(name, 'ztwp')].name" -o tsv
```

Policy definitions live at **subscription** scope, so the stack does not remove them. They
cost nothing and are harmless, but for a clean subscription:

```bash
az policy set-definition delete --name ztwp-zero-trust-baseline
```

```bash
for definition in ztwp-deny-storage-public-blob-access ztwp-deny-public-network-access ztwp-require-https-app-service; do az policy definition delete --name $definition; done
```

Finally, when you are done with the lab for good:

```bash
az group delete --name rg-ztwp-bootstrap-dev-weu --yes
```

---

## The complete cleanup checklist

- [ ] `az stack sub list` is empty
- [ ] No `rg-ztwp-*` groups except bootstrap (or none at all)
- [ ] No soft-deleted key vaults you care about
- [ ] Custom policy definitions removed, if you want the subscription tidy
- [ ] The app registration and federated credentials from [chapter 09](09-cicd-oidc.md)
      deleted if the pipeline was a one-off:

```bash
az ad app delete --id <appId>
```

- [ ] Budget alert left in place — it costs nothing and catches the next lab
