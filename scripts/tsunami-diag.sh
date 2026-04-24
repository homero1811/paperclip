#!/usr/bin/env bash
# Read-only diagnostic snapshot for Tsunami Automation.
#
# Pulls:
#   - All agents (+ status, budget, last heartbeat).
#   - Failed heartbeat runs (last 20).
#   - Blocked issues company-wide.
#   - Budget incidents + remaining monthly budget.
#   - Plugin job failures (if any).
#
# Output:
#   - Markdown table to stdout.
#   - Raw JSON saved to ./report/tsunami-diag-{YYYYMMDD-HHMMSS}.json so
#     two runs (before / after a patch) can be diffed.
#
# Env vars required:
#   PAPERCLIP_API_URL, PAPERCLIP_API_KEY, PAPERCLIP_COMPANY_ID
#
# This script writes nothing to the database or to any live resource.

set -euo pipefail

: "${PAPERCLIP_API_URL:?PAPERCLIP_API_URL is required}"
: "${PAPERCLIP_API_KEY:?PAPERCLIP_API_KEY is required}"
: "${PAPERCLIP_COMPANY_ID:?PAPERCLIP_COMPANY_ID is required}"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORT_DIR="${REPO_ROOT}/report"
TS="$(date -u +%Y%m%d-%H%M%S)"
OUT_JSON="${REPORT_DIR}/tsunami-diag-${TS}.json"
mkdir -p "${REPORT_DIR}"

auth=(-H "Authorization: Bearer ${PAPERCLIP_API_KEY}")

api() {
  local path="$1"
  curl -sS "${PAPERCLIP_API_URL}${path}" "${auth[@]}" 2>/dev/null || printf '{}'
}
norm() {
  # Normalize list endpoints that may wrap results in {items:[...]}.
  jq 'if type == "array" then . elif .items then .items else . end'
}

agents="$(api "/api/companies/${PAPERCLIP_COMPANY_ID}/agents" | norm)"
failed_runs="$(api "/api/companies/${PAPERCLIP_COMPANY_ID}/heartbeat-runs?status=failed&limit=20" | norm)"
blocked_issues="$(api "/api/companies/${PAPERCLIP_COMPANY_ID}/issues?status=blocked&limit=100" | norm)"
budget_incidents="$(api "/api/companies/${PAPERCLIP_COMPANY_ID}/budget-incidents?limit=20" | norm)"
plugin_failures="$(api "/api/companies/${PAPERCLIP_COMPANY_ID}/plugin-jobs?status=failed&limit=20" | norm)"

jq -n \
  --arg ts "$TS" \
  --arg company "$PAPERCLIP_COMPANY_ID" \
  --argjson agents "$agents" \
  --argjson failedRuns "$failed_runs" \
  --argjson blockedIssues "$blocked_issues" \
  --argjson budgetIncidents "$budget_incidents" \
  --argjson pluginFailures "$plugin_failures" \
  '{
    timestamp: $ts,
    companyId: $company,
    agents: $agents,
    failedRuns: $failedRuns,
    blockedIssues: $blockedIssues,
    budgetIncidents: $budgetIncidents,
    pluginFailures: $pluginFailures
  }' > "${OUT_JSON}"

# -- Markdown report ---------------------------------------------------------

agent_count=$(printf '%s' "$agents" | jq 'length')
failed_count=$(printf '%s' "$failed_runs" | jq 'length')
blocked_count=$(printf '%s' "$blocked_issues" | jq 'length')
incident_count=$(printf '%s' "$budget_incidents" | jq 'length')
plugin_fail_count=$(printf '%s' "$plugin_failures" | jq 'length')

cat <<MD
# Tsunami Automation diagnostic — ${TS}

Company: \`${PAPERCLIP_COMPANY_ID}\`

| Signal | Count |
|---|---|
| Agents | ${agent_count} |
| Failed heartbeat runs (last 20) | ${failed_count} |
| Blocked issues | ${blocked_count} |
| Budget incidents | ${incident_count} |
| Failed plugin jobs | ${plugin_fail_count} |

## Agents

| Name | Role | Adapter / model | Status | Last heartbeat | Budget (spent / cap) |
|---|---|---|---|---|---|
MD
printf '%s' "$agents" | jq -r '
  .[] | [
    .name,
    (.role // "-"),
    ((.adapterType // "-") + " / " + ((.adapterConfig.model // "-") | tostring)),
    (.status // "-"),
    (.lastHeartbeatAt // "-"),
    (((.spentMonthlyCents // 0) | tostring) + " / " + ((.budgetMonthlyCents // 0) | tostring))
  ] | "| " + join(" | ") + " |"'

cat <<MD

## Failed heartbeat runs (last 20)

MD
if [ "$failed_count" = "0" ]; then
  echo "_none_"
else
  cat <<MD
| Run id | Agent | Started | Error summary |
|---|---|---|---|
MD
  printf '%s' "$failed_runs" | jq -r '
    .[] | [
      (.id // "-"),
      (.agentName // .agentId // "-"),
      (.startedAt // "-"),
      ((.error // .failureReason // "") | tostring | .[:80])
    ] | "| " + join(" | ") + " |"'
fi

cat <<MD

## Blocked issues

MD
if [ "$blocked_count" = "0" ]; then
  echo "_none_"
else
  cat <<MD
| Issue | Assignee | Updated |
|---|---|---|
MD
  printf '%s' "$blocked_issues" | jq -r '
    .[] | [
      (.identifier // .id // "-") + " — " + (.title // "-"),
      (.assigneeAgentId // .assigneeUserId // "-"),
      (.updatedAt // "-")
    ] | "| " + join(" | ") + " |"'
fi

cat <<MD

## Budget incidents

MD
if [ "$incident_count" = "0" ]; then
  echo "_none_"
else
  printf '%s' "$budget_incidents" | jq -r '
    .[] | "- " + (.createdAt // "-") + " — " + (.agentName // .agentId // "-")
         + ": " + (.kind // .reason // "-")'
fi

cat <<MD

## Failed plugin jobs

MD
if [ "$plugin_fail_count" = "0" ]; then
  echo "_none_"
else
  printf '%s' "$plugin_failures" | jq -r '
    .[] | "- " + (.createdAt // "-") + " — " + (.plugin // "-")
         + ": " + ((.error // .failureReason // "") | tostring | .[:120])'
fi

cat <<MD

---

Raw JSON saved to: \`${OUT_JSON}\`
MD
