#!/usr/bin/env bash
#
# Phase zero: create the bootstrap Key Vault and seed the database password into it.
# POSIX twin of bootstrap.ps1 — see that file for the reasoning.
#
#   ./scripts/bootstrap.sh dev westeurope
#
set -euo pipefail

ENVIRONMENT="${1:-dev}"
LOCATION="${2:-westeurope}"
WORKLOAD="${3:-ztwp}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Checking the signed-in context"
az account show --query "{subscription:name, id:id}" -o tsv

OPERATOR_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
MANAGEMENT_IP="$(curl -fsS https://api.ipify.org)/32"
echo "    detected IP  : ${MANAGEMENT_IP}"

echo "==> Deploying the bootstrap resource group and vault"
OUTPUTS="$(az deployment sub create \
  --name "bootstrap-${WORKLOAD}-${ENVIRONMENT}" \
  --location "${LOCATION}" \
  --template-file "${REPO_ROOT}/infra/bootstrap.bicep" \
  --parameters workload="${WORKLOAD}" environment="${ENVIRONMENT}" \
               managementIpAddress="${MANAGEMENT_IP}" \
               operatorObjectId="${OPERATOR_OBJECT_ID}" \
  --query properties.outputs -o json --only-show-errors)"

VAULT_NAME="$(echo "${OUTPUTS}" | python -c 'import json,sys;print(json.load(sys.stdin)["bootstrapVaultName"]["value"])')"
RESOURCE_GROUP="$(echo "${OUTPUTS}" | python -c 'import json,sys;print(json.load(sys.stdin)["bootstrapResourceGroupName"]["value"])')"
SUBSCRIPTION_ID="$(echo "${OUTPUTS}" | python -c 'import json,sys;print(json.load(sys.stdin)["subscriptionId"]["value"])')"

echo "==> Seeding the database password"
if az keyvault secret show --vault-name "${VAULT_NAME}" --name postgres-admin-password --query id -o tsv >/dev/null 2>&1; then
  echo "    secret already present — leaving it alone"
else
  # Alphanumeric only: the connection string is a URI and @ or / inside a password breaks it.
  PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
  az keyvault secret set \
    --vault-name "${VAULT_NAME}" \
    --name postgres-admin-password \
    --value "${PASSWORD}" \
    --only-show-errors --output none
  unset PASSWORD
  echo "    32-character password generated and stored"
fi

cat <<EOF

Put these three values into infra/main.${ENVIRONMENT}.bicepparam:

param postgresAdministratorPassword = az.getSecret(
  '${SUBSCRIPTION_ID}',
  '${RESOURCE_GROUP}',
  '${VAULT_NAME}',
  'postgres-admin-password'
)

Also set: param managementIpAddress = '${MANAGEMENT_IP}'
EOF
