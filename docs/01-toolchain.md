# 01 — Toolchain, naming, and the bootstrap vault

> Get the tools right, understand where every resource name comes from, and solve the
> chicken-and-egg problem of the database password before it becomes a hardcoded string.

**Time:** 20 minutes · **Cost:** effectively zero (one Key Vault)

---

## 1.1 The tools

```bash
az version
```

Azure CLI 2.60 or newer. Then the Bicep CLI, which is a separate binary the CLI downloads
for itself:

```bash
az bicep install
```

```bash
az bicep version
```

This lab was written and compiled against **Bicep 0.46.1**. Anything from 0.42 upward has
the features used here: user-defined types and functions, `@export()`, `using none`,
`extends` in parameter files, and the test framework.

One thing to know early: `az bicep` has no `test` subcommand. The standalone binary it
installs does.

```bash
az bicep install && ~/.azure/bin/bicep --version
```

On Windows that path is `C:\Users\<you>\.azure\bin\bicep.exe`. Both
[`scripts/validate.ps1`](../scripts/validate.ps1) and the CI workflow deal with this
already.

---

## 1.2 Subscription baseline

```bash
az login
```

```bash
az account set --subscription "<name or id>"
```

You need **Owner**. Two things in this lab are not available to Contributor:

- **Role assignments** — [`modules/shared/rbac.bicep`](../infra/modules/shared/rbac.bicep)
  grants the application's managed identity access to Key Vault and Storage. Writing role
  assignments is a permission Contributor deliberately lacks.
- **Policy definitions at subscription scope** — chapter 07.

Register the resource providers. A first deployment into a fresh subscription fails on a
missing provider far more often than on anything in the template:

```bash
for provider in Microsoft.Network Microsoft.Web Microsoft.KeyVault Microsoft.Storage Microsoft.DBforPostgreSQL Microsoft.OperationalInsights Microsoft.Insights Microsoft.Resources; do az provider register --namespace $provider; done
```

```bash
az provider list --query "[?registrationState=='Registered'].namespace" -o tsv | sort
```

---

## 1.3 Where names come from

Nothing in this repository names a resource by hand. Every name is derived by a function in
[`infra/naming.bicep`](../infra/naming.bicep), so a name is reproducible from its inputs and
a naming change happens in one file.

```bicep
@export()
@description('Hyphenated name: <abbreviation>-<workload>-<purpose>-<environment>-<region>.')
func resourceName(abbreviation string, workload string, purpose string, environment string, location string) string =>
  toLower(empty(purpose)
    ? '${abbreviation}-${workload}-${environment}-${regionCode(location)}'
    : '${abbreviation}-${workload}-${purpose}-${environment}-${regionCode(location)}')
```

`regionCode` is a lookup with a fallback, which is worth reading for the syntax alone:

```bicep
func regionCode(location string) string => {
  westeurope: 'weu'
  northeurope: 'neu'
  germanywestcentral: 'gwc'
  // ...
}[?toLower(replace(location, ' ', ''))] ?? substring(toLower(replace(location, ' ', '')), 0, 3)
```

`[?key]` is the safe-dereference operator: it yields `null` instead of failing when the key
is absent, and `??` supplies the fallback. An unlisted region degrades to the first three
letters of its name rather than breaking the deployment.

Storage accounts and key vaults have their own rules — globally unique, no hyphens, 24
characters — so they get a second function:

```bicep
func globalName(abbreviation string, workload string, environment string, seed string) string =>
  toLower(take('${abbreviation}${workload}${environment}${uniqueString(seed)}', 24))
```

`take` rather than `substring`, and that is not a style preference. `substring` throws when
the string is shorter than the requested length. With a short workload name this one is:
`st` + `ztwp` + `dev` + a 13-character `uniqueString` is 22 characters, and
`substring(…, 0, 23)` fails on it at deployment time. The offline assertion in
[`infra/tests/naming-assertions.bicep`](../infra/tests/naming-assertions.bicep) caught that
before Azure ever saw it — the story is in [chapter 11](11-testing.md).

**User-defined functions cannot read variables and cannot call runtime functions** such as
`resourceGroup()`, `subscription()` or `reference()`. That is why the uniqueness seed is a
parameter rather than something the function fetches for itself.

### Try it

Change `workload` in [`infra/main.shared.bicepparam`](../infra/main.shared.bicepparam) from
`ztwp` to something else and compile:

```bash
az bicep build-params --file infra/main.dev.bicepparam --stdout
```

Every resource name in the platform follows. Nothing else needs editing.

---

## 1.4 The bootstrap problem

PostgreSQL needs an administrator password. It must not be in the repository, must not be
in the ARM template, and must not be typed on a command line that lands in shell history.

The Bicep answer is `az.getSecret()` in a parameter file — it compiles to a Key Vault
*reference*, and the deployment engine resolves it server-side:

```json
"postgresAdministratorPassword": {
  "reference": {
    "keyVault": { "id": "/subscriptions/…/vaults/kvbsztwpdev…" },
    "secretName": "postgres-admin-password"
  }
}
```

That is the compiled output of
[`infra/main.dev.bicepparam`](../infra/main.dev.bicepparam) — the value never passes
through your machine.

Which leaves the ordering problem: a template cannot read a secret from a vault it is
creating in the same pass. Hence phase zero,
[`infra/bootstrap.bicep`](../infra/bootstrap.bicep): a resource group and one vault, whose
only job is to hold the seed. It is deployed once and deliberately survives every teardown,
so the next run reuses the same password.

```bash
./scripts/bootstrap.ps1 -Environment dev
```

The script detects your public IP, deploys the vault, grants you **Key Vault Secrets
Officer** on it, generates a 32-character alphanumeric password and writes it in. It never
prints the password.

> **Why alphanumeric only?** The connection string assembled in
> [`modules/platform/key-vault.bicep`](../infra/modules/platform/key-vault.bicep) is a URI.
> A password containing `@` or `/` breaks it, and the failure surfaces three modules later
> as a connection error with nothing pointing back at the password.

Two flags on the bootstrap vault matter:

```bicep
enableRbacAuthorization: true      // access policies are the old model
enabledForTemplateDeployment: true // without this, az.getSecret fails on authorization
```

The second one is the classic trap. Missing it produces an error naming the vault and not
the flag.

---

## 1.5 Wire up the parameter file

The bootstrap prints three values. Put them into
[`infra/main.dev.bicepparam`](../infra/main.dev.bicepparam):

```bicep
param postgresAdministratorPassword = az.getSecret(
  '<subscription id>',
  '<bootstrap resource group>',
  '<bootstrap vault name>',
  'postgres-admin-password'
)

param managementIpAddress = '<your ip>/32'
```

Note the top of that file:

```bicep
using none
extends 'main.shared.bicepparam'
```

`using none` says "this file names no template", which is what allows `--template-file` and
`--parameters` to be passed together. `extends` pulls in
[`main.shared.bicepparam`](../infra/main.shared.bicepparam) — the values dev and prod share,
declared once. Overriding a parameter is simply declaring it again below the `extends` line.

Confirm the merge worked:

```bash
az bicep build-params --file infra/main.dev.bicepparam --stdout
```

`workload`, `location` and `addressing` should appear in the output even though the dev file
never mentions them.

---

## 1.6 Validate before deploying anything

```bash
./scripts/validate.ps1
```

Compiles every template, compiles both parameter files, lints against the elevated rules in
[`bicepconfig.json`](../bicepconfig.json), and runs the offline assertions. It touches no
subscription and costs nothing — run it before every commit.

The linter config is worth a look, because the rules are `error` rather than `warning`:

```json
"no-unused-params":               { "level": "error" },
"outputs-should-not-contain-secrets": { "level": "error" },
"secure-parameter-default":       { "level": "error" },
"secure-secrets-in-params":       { "level": "error" }
```

Two of these bite during this lab, and both bites are instructive — see
[troubleshooting](troubleshooting.md#the-linter-rejects-something-that-looks-fine).

---

## Checkpoint

- [ ] `az bicep version` reports 0.42 or newer
- [ ] You are Owner on the subscription and the providers are registered
- [ ] The bootstrap vault exists and holds `postgres-admin-password`
- [ ] `main.dev.bicepparam` contains your `az.getSecret` coordinates and your IP
- [ ] `./scripts/validate.ps1` passes

---

Next: [02 — Network](02-network.md)
