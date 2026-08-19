#!/usr/bin/env bash
#
# The proof matrix from docs/10-verification.md, as a script. POSIX twin of verify.ps1.
# Reads only: it curls, it queries, it reports.
#
#   ./scripts/verify.sh dev
#
set -uo pipefail

ENVIRONMENT="${1:-dev}"
WORKLOAD="${2:-ztwp}"
STACK_NAME="${WORKLOAD}-${ENVIRONMENT}"
PASSED=0
FAILED=0

claim() {
  local description="$1" expected="$2" actual="$3" want="$4"
  echo ""
  echo "  ${description}"
  echo "    expected: ${expected}"
  echo "    actual:   ${actual}"
  if [[ "${actual}" == "${want}" ]]; then
    PASSED=$((PASSED + 1)); echo "    PASS"
  else
    FAILED=$((FAILED + 1)); echo "    FAIL"
  fi
}

status_of() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" || echo "000"; }

echo "==> Reading the deployment stack"
OUTPUTS="$(az stack sub show --name "${STACK_NAME}" --query outputs -o json --only-show-errors)"
read_output() { echo "${OUTPUTS}" | python -c "import json,sys;print(json.load(sys.stdin)['$1']['value'])"; }

GATEWAY_FQDN="$(read_output gatewayFqdn)"
APP_HOSTNAME="$(read_output appDefaultHostName)"
STORAGE_ACCOUNT="$(read_output storageAccountName)"

claim "The application has no usable public route" \
      "403" "$(status_of "https://${APP_HOSTNAME}/")" "403"

claim "The gateway is the way in" \
      "200" "$(status_of "http://${GATEWAY_FQDN}/")" "200"

claim "The WAF blocks SQL injection before the app sees it" \
      "403" "$(status_of "http://${GATEWAY_FQDN}/?id=1%27%20OR%20%271%27%3D%271")" "403"

claim "The WAF blocks path traversal too" \
      "403" "$(status_of "http://${GATEWAY_FQDN}/?file=../../etc/passwd")" "403"

if az storage blob list --account-name "${STORAGE_ACCOUNT}" --container-name app-data \
     --auth-mode login --only-show-errors --output none 2>/dev/null; then
  STORAGE_REACHABLE="reachable"
else
  STORAGE_REACHABLE="refused"
fi
claim "Storage refuses traffic from this machine" \
      "refused" "${STORAGE_REACHABLE}" "refused"

claim "Shared keys are gone, not merely unused" \
      "false" \
      "$(az storage account show --name "${STORAGE_ACCOUNT}" --query allowSharedKeyAccess -o tsv --only-show-errors)" \
      "false"

echo ""
echo "======================================================================"
echo "  passed: ${PASSED}    failed: ${FAILED}"
echo "======================================================================"
echo ""
echo "Blocked requests reach Log Analytics after a few minutes:"
echo '  AGWFirewallLogs | where Action == "Blocked" | project TimeGenerated, RuleId, Message, ClientIp'

[[ "${FAILED}" -eq 0 ]] || exit 1
