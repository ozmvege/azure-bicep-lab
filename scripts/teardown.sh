#!/usr/bin/env bash
#
# Delete the stack and everything it manages.
#
#   ./scripts/teardown.sh dev
#
# --action-on-unmanage deleteAll is the whole point: it deletes the managed resources and
# the resource groups. Use detachAll and you keep paying roughly USD 0.44 an hour for a
# gateway nobody is using.
#
set -euo pipefail

ENVIRONMENT="${1:-dev}"
WORKLOAD="${2:-ztwp}"
STACK_NAME="${WORKLOAD}-${ENVIRONMENT}"

echo "==> Deleting stack ${STACK_NAME} and every resource it manages"
az stack sub delete \
  --name "${STACK_NAME}" \
  --action-on-unmanage deleteAll \
  --yes

echo "==> Anything left over?"
az group list --query "[?starts_with(name, 'rg-${WORKLOAD}-')].name" -o tsv || true
echo "The bootstrap resource group is not managed by the stack and survives on purpose."
