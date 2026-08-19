#!/usr/bin/env bash
#
# Deploy the platform as a deployment stack.
#
#   ./scripts/deploy.sh dev westeurope
#
# Why a stack and not `az deployment sub create`:
#   * resources dropped from the template are removed from Azure instead of lingering
#   * the deny assignment blocks portal edits to anything the stack manages
#   * teardown is one command that cannot miss a resource group
#
set -euo pipefail

ENVIRONMENT="${1:-dev}"
LOCATION="${2:-westeurope}"
WORKLOAD="${3:-ztwp}"
STACK_NAME="${WORKLOAD}-${ENVIRONMENT}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> What-if first. Read it."
az deployment sub what-if \
  --location "${LOCATION}" \
  --template-file "${REPO_ROOT}/infra/main.bicep" \
  --parameters "${REPO_ROOT}/infra/main.${ENVIRONMENT}.bicepparam" \
  --exclude-change-types Ignore NoChange

read -r -p "Deploy stack ${STACK_NAME}? [y/N] " reply
[[ "${reply}" == "y" || "${reply}" == "Y" ]] || { echo "Aborted."; exit 1; }

echo "==> Creating the deployment stack"
az stack sub create \
  --name "${STACK_NAME}" \
  --location "${LOCATION}" \
  --template-file "${REPO_ROOT}/infra/main.bicep" \
  --parameters "${REPO_ROOT}/infra/main.${ENVIRONMENT}.bicepparam" \
  --action-on-unmanage deleteResources \
  --deny-settings-mode denyWriteAndDelete \
  --deny-settings-apply-to-child-scopes \
  --description "Zero-trust web platform, ${ENVIRONMENT}" \
  --yes

echo "==> Outputs"
az stack sub show --name "${STACK_NAME}" --query outputs -o json
