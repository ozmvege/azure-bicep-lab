# 11 — Testing Bicep offline, and the bug it caught here

> Assertions that run in under a second with no subscription attached, what they can and
> cannot cover, and a real defect in this repository that they found before Azure did.

**Time:** 25 minutes · **Cost:** none

**Files:** [`tests/main.tests.bicep`](../infra/tests/main.tests.bicep) ·
[`tests/naming-assertions.bicep`](../infra/tests/naming-assertions.bicep)

---

## 11.1 The four things that can go wrong, and what catches each

| Failure | Caught by | Needs Azure? | Speed |
|---|---|---|---|
| Syntax, types, missing parameters | `bicep build` | no | instant |
| Style and safety rules | `bicep lint` | no | instant |
| Wrong logic in a function or expression | **`bicep test`** | no | ~1 second |
| Architecture and best practice | PSRule for Azure | no | seconds |
| Invalid values, quota, RBAC, policy | `az deployment … what-if` / `validate` | **yes** | ~30 seconds |
| Anything about runtime behaviour | deploy and verify (ch. 10) | yes | minutes |

The third row is the one most IaC repositories leave empty, and it is the row that covers
the logic people actually write themselves.

---

## 11.2 The test framework

Two files. Assertions live in the file whose expressions they test:

```bicep
// infra/tests/naming-assertions.bicep
import { regionCode, resourceName, globalName, dnsLabel } from '../naming.bicep'

param location string
param workload string
param environment string
param seed string

assert regionIsMapped = regionCode(location) == 'weu'
assert unknownRegionDegrades = regionCode('antarcticacentral') == 'ant'
assert hyphenatedNameShape = resourceName('rg', workload, 'network', environment, location) == 'rg-ztwp-network-dev-weu'
assert emptyPurposeDropsSegment = resourceName('app', workload, '', environment, location) == 'app-ztwp-dev-weu'
assert globalNameFitsStorageLimit = length(globalName('st', workload, environment, seed)) <= 24
```

And a test file supplies the parameters:

```bicep
// infra/tests/main.tests.bicep
test namingConventions 'naming-assertions.bicep' = {
  params: {
    location: 'westeurope'
    workload: 'ztwp'
    environment: 'dev'
    seed: '/subscriptions/00000000-0000-0000-0000-000000000000'
  }
}
```

```bash
~/.azure/bin/bicep test infra/tests/main.tests.bicep
```

```
[✓] Evaluation namingConventions Passed!
```

Both features are experimental and enabled in [`bicepconfig.json`](../bicepconfig.json):

```json
"experimentalFeaturesEnabled": { "assertions": true, "testFramework": true }
```

Every compilation then prints an experimental-features warning. That is the trade for having
any offline test at all, and it is worth it.

> `az bicep` has no `test` subcommand — only the standalone binary does.
> [`scripts/validate.ps1`](../scripts/validate.ps1) resolves the path for you.

---

## 11.3 The bug

The first version of `globalName` was:

```bicep
func globalName(abbreviation string, workload string, environment string, seed string) string =>
  toLower(substring('${abbreviation}${workload}${environment}${uniqueString(seed)}', 0, 23))
```

Storage account names are capped at 24 characters, so trimming looks sensible. The first
test run said otherwise:

```
[-] Evaluation namingConventions Skipped!
Reason: Evaluating template failed: Unable to evaluate the template language function
'substring'. The index and length parameters must refer to a location within the string.
The index parameter: '0', the length parameter: '23', the length of the string parameter: '22'.
```

`st` + `ztwp` + `dev` + a 13-character `uniqueString` is **22** characters. `substring`
throws when asked for more than the string holds — it does not clamp.

The fix:

```bicep
func globalName(abbreviation string, workload string, environment string, seed string) string =>
  toLower(take('${abbreviation}${workload}${environment}${uniqueString(seed)}', 24))
```

`take` returns what exists and never throws.

What matters is **where** this would otherwise have surfaced. The function is only evaluated
when the template is deployed, so `bicep build` was perfectly happy. The failure would have
arrived partway through a real deployment, after the resource groups and the network were
already created, as a `substring` error with no resource name attached — and only for short
workload names, so `workload = 'zerotrust'` would have hidden it completely.

One assertion, one second, no subscription.

---

## 11.4 What assertions cannot do

Be clear about the boundary. `bicep test` evaluates the template locally, so it sees
parameters, variables, functions and expressions. It does **not**:

- know whether a SKU exists in your region
- know whether you have quota
- evaluate policy
- resolve `reference()` or anything about a deployed resource
- know whether a private endpoint group ID is valid

All of those need `what-if` or `validate`, which need a subscription. The offline tests are
the fast inner loop, not a replacement for the outer one.

---

## 11.5 The full local loop

```bash
./scripts/validate.ps1
```

- compiles every template
- compiles both parameter files
- lints against the elevated rules
- runs the assertions

Then, with a subscription:

```bash
az deployment sub validate --location westeurope --template-file infra/main.bicep --parameters infra/main.dev.bicepparam
```

`validate` submits the template to ARM, which checks values, quota, RBAC and policy without
creating anything. `what-if` goes one step further and diffs against what exists.

---

## Exercises

1. **Write an assertion for the address plan** — that the Bastion subnet is inside the hub
   VNet's range, for instance. You will discover Bicep has no CIDR-containment function,
   which is itself the lesson: assertions test *your* logic, not Azure's.

2. **Make a test fail on purpose.** Change `regionIsMapped` to expect `'weu2'`, run, and read
   the failure output. Knowing what a failure looks like is half of trusting a green run.

3. **Add the region table assertion.** Every code in `regionCode` should be three or four
   characters; write one assertion that checks the whole map at once with a lambda over
   `items()`.

4. **Wire it into a pre-commit hook** so `bicep build` and `bicep test` run before every
   commit. It costs a second and removes a class of pull request entirely.

---

## Checkpoint

- [ ] `bicep test infra/tests/main.tests.bicep` passes
- [ ] You have made it fail and read the output
- [ ] You can name three failure classes assertions cannot catch
- [ ] `./scripts/validate.ps1` is part of your routine before committing

---

Next: [12 — Azure Verified Modules](12-avm.md)
