# 08 — Deployment stacks: lifecycle, drift, and a teardown that cannot miss

> A plain deployment adds and updates. It never removes, and it never stops anyone editing
> what it built. A stack does both — and it is the reason this lab can promise that teardown
> leaves nothing behind.

**Time:** 30 minutes · **Cost:** none beyond what is already running

**Files:** [`deploy.ps1`](../scripts/deploy.ps1) · [`teardown.ps1`](../scripts/teardown.ps1) ·
[`deploy.yml`](../.github/workflows/deploy.yml) · [`destroy.yml`](../.github/workflows/destroy.yml)

---

## 8.1 What a plain deployment does not do

Deploy a template with five resources, delete one from the template, deploy again in
incremental mode. Azure has five resources. The one you removed is still there, still
billed, and now invisible to your source of truth — the state most infrastructure repos
quietly live in.

Complete mode fixes it at resource-group scope and is a blunt instrument: it deletes
everything in the group that is not in the template, including things another team owns.

A **deployment stack** is a resource that remembers what it manages:

```bash
az stack sub create \
  --name ztwp-dev \
  --location westeurope \
  --template-file infra/main.bicep \
  --parameters infra/main.dev.bicepparam \
  --action-on-unmanage deleteResources \
  --deny-settings-mode denyWriteAndDelete \
  --deny-settings-apply-to-child-scopes \
  --yes
```

Two flags carry the whole idea.

### `--action-on-unmanage`

What happens to a resource that leaves the stack's management — because it was deleted from
the template, or because the stack itself is being deleted.

| Value | Effect |
|---|---|
| `detachAll` | leave everything in Azure, unmanaged. The safe-looking option that keeps the bill running |
| `deleteResources` | delete resources, keep resource groups |
| `deleteAll` | delete resources **and** resource groups |

The deploy script uses `deleteResources`, so a resource dropped from the template disappears
from Azure. The teardown uses `deleteAll` — that is the difference between deleting a stack
and deleting what a stack built.

### `--deny-settings-mode`

The stack writes a **deny assignment** onto the resources it manages. Unlike RBAC, a deny
assignment cannot be overridden by being Owner.

| Value | Effect |
|---|---|
| `none` | no protection |
| `denyDelete` | resources can be modified but not deleted |
| `denyWriteAndDelete` | resources cannot be modified or deleted outside the stack |

`--deny-settings-apply-to-child-scopes` extends this to resources created *inside* the
managed ones later — which is what stops someone adding a firewall rule to the database by
hand.

---

## 8.2 Tamper with it, from the portal

This is the exercise worth doing properly, because it is the one that changes how people
think about IaC.

1. Portal → the App Service plan `asp-ztwp-dev-weu` → **Scale up** → pick a different tier →
   **Apply**.

Expected:

```
Failed to update App Service plan.
RequestDisallowedByAzure: Resource 'asp-ztwp-dev-weu' was disallowed by a deny assignment.
```

2. Now try to delete the storage account. Same refusal.

3. Then make the *same* change through the template — edit `appServicePlan` in
   [`main.dev.bicepparam`](../infra/main.dev.bicepparam), run `./scripts/deploy.ps1`, and
   watch it apply without complaint.

The platform now has exactly one door, and it is the repository. Not by convention, not by a
policy everyone agrees to follow — enforced by Azure, against Owners included.

```bash
az stack sub show --name ztwp-dev --query "{denyMode:denySettings.mode, applyToChildren:denySettings.applyToChildScopes, resources:length(resources)}" -o json
```

### Getting back in when you need to

```bash
az stack sub create --name ztwp-dev … --deny-settings-mode none --yes
```

Redeploy with `none`, make the change, put it back. Deliberate, logged, and two commands —
which is roughly the amount of friction an emergency change deserves.

`--deny-settings-excluded-principals` and `--deny-settings-excluded-actions` carve out
narrower exceptions, for example a break-glass identity or a specific data action.

---

## 8.3 Remove something and watch it go

Comment out the `storage` module in [`main.bicep`](../infra/main.bicep) and redeploy:

```bash
./scripts/deploy.ps1 -Environment dev
```

The what-if shows a **Delete**. Confirm, and the storage account is gone — because
`--action-on-unmanage deleteResources` says a resource that leaves the template leaves
Azure. Restore the module and redeploy to bring it back.

This is the behaviour that makes a repository an actual source of truth rather than an
aspiration. It is also why the what-if step in
[`deploy.ps1`](../scripts/deploy.ps1) is not optional: with a stack, a careless edit
deletes rather than orphans.

---

## 8.4 Teardown

```bash
./scripts/teardown.ps1 -Environment dev
```

which is:

```bash
az stack sub delete --name ztwp-dev --action-on-unmanage deleteAll --yes
```

`deleteAll` removes the managed resources **and** their resource groups. Get this wrong —
`detachAll` — and the stack disappears while roughly USD 0.44 an hour keeps accruing on a
gateway nobody is looking at.

```bash
az group list --query "[?starts_with(name, 'rg-ztwp-')].name" -o tsv
```

Only `rg-ztwp-bootstrap-dev-weu` should remain. It is not managed by the stack and survives
on purpose, so the next run reuses the same password.

---

## 8.5 The same thing in CI

[`deploy.yml`](../.github/workflows/deploy.yml) runs the identical command against a GitHub
environment, so approvals and the federated credential both apply.
[`destroy.yml`](../.github/workflows/destroy.yml) is manual-dispatch only and requires
typing `DESTROY`:

```yaml
if: inputs.confirmation == 'DESTROY'
```

A destroy workflow that anyone can trigger with a click is a liability; one that does not
exist at all leaves teardown to memory at the end of a long day. This is the middle.

---

## Exercises

1. **Try every unmanage mode.** Deploy with `detachAll`, remove a module, redeploy, and find
   the orphan in the portal. That orphan is what every non-stack deployment leaves behind.

2. **Break glass properly.** Use `--deny-settings-excluded-principals` with your own object
   ID, then repeat the portal edit. It now succeeds — and you have a concrete answer for the
   "what if we need to change something at 3 a.m." objection.

3. **Stack at resource-group scope.** `az stack group create` manages one group instead of a
   subscription. Work out which scope this platform needs and why the subscription-scope
   stack is the one that can delete the resource groups themselves.

---

## Checkpoint

- [ ] A portal edit to a managed resource is refused with `RequestDisallowedByAzure`
- [ ] The same change through the template succeeds
- [ ] A module removed from the template deletes its resource
- [ ] You know which `--action-on-unmanage` value teardown uses, and why the other two are wrong

---

Next: [09 — CI/CD with OIDC](09-cicd-oidc.md)
