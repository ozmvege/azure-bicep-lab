# 09 — CI/CD: a pipeline with no secret in it

> Federated credentials instead of a client secret, what-if on every pull request, and
> PSRule reading the templates the way a very well-read reviewer would.

**Time:** 45 minutes · **Cost:** none — GitHub Actions is free for public repositories

**Files:** [`ci.yml`](../.github/workflows/ci.yml) ·
[`deploy.yml`](../.github/workflows/deploy.yml) ·
[`destroy.yml`](../.github/workflows/destroy.yml) ·
[`ps-rule.yaml`](../.ps-rule/ps-rule.yaml)

---

## 9.1 Why not a client secret

The traditional pipeline holds `AZURE_CREDENTIALS`: a service principal's client secret, in
a GitHub secret, valid for a year or two, rotated when someone remembers. Anyone who can
run a workflow can usually exfiltrate it, and it works from anywhere on the internet.

OpenID Connect replaces it with a token that GitHub mints per run, that Entra ID validates
against a **federated credential** naming the exact repository and branch, and that expires
in minutes. Nothing long-lived exists to steal.

---

## 9.2 Set it up

Create an app registration and give it access to the subscription:

```bash
az ad app create --display-name "github-ztwp-lab" --query appId -o tsv
```

```bash
az ad sp create --id <appId>
```

```bash
az role assignment create --assignee <appId> --role Owner --scope /subscriptions/<subscriptionId>
```

> **Owner, not Contributor** — the platform creates role assignments and policy definitions.
> If that is more than you want a pipeline to hold, split it: Contributor plus *User Access
> Administrator* plus *Resource Policy Contributor* is the least-privilege version.

Now the federated credential. This is the part that replaces the secret:

```bash
az ad app federated-credential create --id <appId> --parameters '{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<owner>/<repo>:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

The `subject` is the whole security boundary. `repo:owner/repo:ref:refs/heads/main` means:
only a workflow in that repository, running on that branch, gets a token. A fork cannot
match it. A pull request cannot match it — pull requests carry
`repo:owner/repo:pull_request`, and the environment-based subject is different again:

| Trigger | `subject` |
|---|---|
| push to a branch | `repo:owner/repo:ref:refs/heads/main` |
| pull request | `repo:owner/repo:pull_request` |
| GitHub environment | `repo:owner/repo:environment:dev` |
| tag | `repo:owner/repo:ref:refs/tags/v1.0.0` |

The workflows here use environments, so create one credential per environment:

```bash
az ad app federated-credential create --id <appId> --parameters '{
  "name": "github-env-dev",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<owner>/<repo>:environment:dev",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

Then three repository secrets — none of which is actually secret, they are identifiers:

```bash
gh secret set AZURE_CLIENT_ID --body "<appId>"
```

```bash
gh secret set AZURE_TENANT_ID --body "$(az account show --query tenantId -o tsv)"
```

```bash
gh secret set AZURE_SUBSCRIPTION_ID --body "$(az account show --query id -o tsv)"
```

And the environments, where the approval gate lives:

```bash
gh api -X PUT repos/<owner>/<repo>/environments/dev
```

---

## 9.3 The one line people forget

```yaml
permissions:
  contents: read
  id-token: write
```

Without `id-token: write` the runner cannot request an OIDC token, and `azure/login` fails
with an error about a missing token rather than about permissions. Set it at job level
rather than workflow level when only one job needs it.

```yaml
- name: Sign in with OIDC
  uses: azure/login@v2
  with:
    client-id: ${{ secrets.AZURE_CLIENT_ID }}
    tenant-id: ${{ secrets.AZURE_TENANT_ID }}
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

No `creds:` key. Its presence is what makes the action fall back to the old secret-based
path.

---

## 9.4 What CI actually checks

[`ci.yml`](../.github/workflows/ci.yml) has three jobs, in increasing order of cost.

### compile — no Azure at all

```yaml
- name: Build every template
  run: |
    for file in $(find infra -name '*.bicep' -not -path 'infra/tests/*'); do
      bicep build "$file" --stdout > /dev/null
    done
- name: Lint
  run: bicep lint ${{ env.TEMPLATE }}
- name: Offline assertions
  run: bicep test infra/tests/main.tests.bicep
```

Every module is compiled individually, not just `main.bicep`. Compiling main alone would
pass over a module that has drifted out of use and no longer compiles.

`bicep lint` is meaningful because [`bicepconfig.json`](../bicepconfig.json) raises the
rules that matter to `error`. With default severities this step passes on almost anything.

### psrule — the second opinion

```yaml
- uses: microsoft/ps-rule@v2.9.0
  with:
    modules: PSRule.Rules.Azure
    inputPath: infra/
    outputFormat: Sarif
    outputPath: reports/ps-rule.sarif
```

PSRule for Azure expands the templates the way ARM would and applies several hundred rules
from the Well-Architected Framework. The SARIF output lands in the GitHub Security tab, next
to code scanning results.

The configuration matters:

```yaml
configuration:
  AZURE_BICEP_FILE_EXPANSION: true
  AZURE_PARAMETER_FILE_EXPANSION: true
```

Without expansion, PSRule reads the Bicep as text and finds almost nothing.

Suppressions are in [`ps-rule.yaml`](../.ps-rule/ps-rule.yaml), and each one names a lab
constraint — purge protection off so teardown can reuse the vault name, `B1` plan, no TLS
certificate on the gateway in the default path. Every one of them would be wrong in
production. Writing them down with reasons is the difference between a suppression and a
blind spot.

### whatif — the only job that touches the subscription

```yaml
az deployment sub what-if \
  --location "${{ env.LOCATION }}" \
  --template-file "${{ env.TEMPLATE }}" \
  --parameters "${{ env.PARAMETERS }}" \
  --exclude-change-types Ignore NoChange \
  --no-pretty-print > whatif.json
```

The result is posted as a pull request comment. A reviewer sees the resource diff next to
the code diff, which is the difference between reviewing a template and reviewing a change.

`--exclude-change-types Ignore NoChange` removes the noise. Without it, a 300-line what-if
is mostly unchanged resources and the three that matter are lost in it.

---

## 9.5 Deploy and destroy

[`deploy.yml`](../.github/workflows/deploy.yml) runs the stack command from
[chapter 08](08-deployment-stacks.md) against a GitHub environment, so a required reviewer
on `prod` becomes an approval gate on the deployment itself.

[`destroy.yml`](../.github/workflows/destroy.yml) is manual only and gated on typing
`DESTROY`:

```yaml
if: inputs.confirmation == 'DESTROY'
```

---

## 9.6 Verify

Open a pull request that changes something small — the App Service SKU, say — and confirm:

- [ ] `compile` passes, and fails if you introduce an unused parameter
- [ ] `psrule` uploads SARIF and the findings appear under **Security**
- [ ] `whatif` comments on the PR with the resource diff
- [ ] nothing in any log contains a password or a key

That last one is not rhetorical:

```bash
gh run view <run-id> --log | grep -iE "password|secret|key" | head
```

You should find parameter *names* and no values. The database password never enters the
pipeline — `az.getSecret` is resolved by ARM, not by the runner
([chapter 01](01-toolchain.md#14-the-bootstrap-problem)).

---

## Exercises

1. **Make the credential fail.** Change the federated credential's subject to a branch that
   does not exist and rerun. `azure/login` fails with `AADSTS70021: No matching federated
   identity record found` — the error you want to recognise on sight.

2. **Add a `prod` environment** with a required reviewer, and confirm `deploy.yml` waits.

3. **Turn a suppression into a fix.** Remove `Azure.KeyVault.PurgeProtect` from
   [`ps-rule.yaml`](../.ps-rule/ps-rule.yaml), watch the rule fail, then decide whether the
   right answer is enabling purge protection or keeping the suppression. Both are defensible;
   the point is deciding rather than inheriting.

4. **Deploy from the pipeline end to end**, then run
   [`scripts/verify.ps1`](../scripts/verify.ps1) locally against what it built.

---

## Checkpoint

- [ ] No client secret exists anywhere in the repository or the GitHub secrets
- [ ] The federated credential names your repository and environment
- [ ] A pull request produces a what-if comment
- [ ] PSRule findings appear in the Security tab

---

Next: [10 — Verification](10-verification.md)
