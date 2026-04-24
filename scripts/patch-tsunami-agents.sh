#!/usr/bin/env bash
# Merge-safe patch for the six Tsunami Automation business-role agents.
#
# Snapshots the live state to ./report/ first, then for each manifest in
# scripts/agents/tsunami/*.json:
#   - If the agent exists: deep-merge manifest into live record.
#     * Default: live non-null fields WIN (preserves any UI tuning).
#     * With --force: manifest fields WIN (overwrites live).
#     * Always clears adapterConfig.instructionsFilePath (migration 0036).
#   - If missing: POST /api/companies/{id}/agent-hires.
#
# Never deletes, never clears unrelated fields, never touches other
# agents. Safe to re-run.
#
# Env vars required:
#   PAPERCLIP_API_URL       e.g. https://paperclip.example.com
#   PAPERCLIP_API_KEY       Bearer token for a board user
#   PAPERCLIP_COMPANY_ID    UUID of the Tsunami company
#
# Flags:
#   --dry-run   Show the diff per agent, write nothing.
#   --force     Manifest fields win on conflicts (still never clobbers
#               adapterType, adapterConfig.model, or adapterConfig.cwd
#               unless those are explicitly set in the manifest).
#
# Exit codes: 0 success, 1 config/env error, 2 snapshot failure,
#             3 API failure.

set -euo pipefail

DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 1
      ;;
  esac
done

: "${PAPERCLIP_API_URL:?PAPERCLIP_API_URL is required}"
: "${PAPERCLIP_API_KEY:?PAPERCLIP_API_KEY is required}"
: "${PAPERCLIP_COMPANY_ID:?PAPERCLIP_COMPANY_ID is required}"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/agents/tsunami"
REPORT_DIR="${REPO_ROOT}/report"
TS="$(date -u +%Y%m%d-%H%M%S)"
SNAPSHOT_FILE="${REPORT_DIR}/tsunami-snapshot-${TS}.json"

mkdir -p "${REPORT_DIR}"

auth=(-H "Authorization: Bearer ${PAPERCLIP_API_KEY}")
ct=(-H "Content-Type: application/json")

log() { printf '%s\n' "$*" >&2; }
api() {
  local method="$1" path="$2"
  shift 2
  curl -sS -X "$method" "${PAPERCLIP_API_URL}${path}" "${auth[@]}" "${ct[@]}" "$@"
}

# --- 1. Snapshot live state --------------------------------------------------

log "==> Snapshotting live state → ${SNAPSHOT_FILE}"
agents_json="$(api GET "/api/companies/${PAPERCLIP_COMPANY_ID}/agents" || true)"
goals_json="$(api GET "/api/companies/${PAPERCLIP_COMPANY_ID}/goals" || true)"
issues_json="$(api GET "/api/companies/${PAPERCLIP_COMPANY_ID}/issues?limit=200" || true)"

if ! printf '%s' "$agents_json" | jq -e . >/dev/null 2>&1; then
  log "FATAL: snapshot failed — /api/companies/${PAPERCLIP_COMPANY_ID}/agents did not return valid JSON."
  log "Response: $agents_json"
  exit 2
fi

jq -n \
  --arg ts "$TS" \
  --arg company "$PAPERCLIP_COMPANY_ID" \
  --argjson agents "$agents_json" \
  --argjson goals "${goals_json:-null}" \
  --argjson issues "${issues_json:-null}" \
  '{timestamp:$ts, companyId:$company, agents:$agents, goals:$goals, issues:$issues}' \
  > "${SNAPSHOT_FILE}"

log "    Snapshot OK ($(jq '.agents | (if type=="array" then length else (.items // []|length) end)' "${SNAPSHOT_FILE}") agents)"

# Normalize agents payload (some endpoints wrap in {items:[...]})
agents_list="$(jq '(.agents | if type=="array" then . else (.items // []) end)' "${SNAPSHOT_FILE}")"

# --- 2. Deep-merge helper (jq) ----------------------------------------------
#
# Live-wins merge: fill-in-nulls only.
#   merge_live_wins(live; manifest) = manifest ∪ (live where live value is not null/empty)
# Manifest-wins merge (--force):
#   merge_manifest_wins(live; manifest) = live ∪ manifest (manifest overrides)
# Both variants always clear adapterConfig.instructionsFilePath.

jq_merge_live_wins='
  def deep_merge($live; $man):
    if ($live | type) == "object" and ($man | type) == "object" then
      ($man | to_entries | map(.key) + ($live | to_entries | map(.key))) | unique as $keys
      | reduce $keys[] as $k ({};
          .[$k] =
            (if ($live[$k] == null) or ($live[$k] == "") or ($live[$k] == {}) or ($live[$k] == []) then
              $man[$k] // $live[$k]
             elif ($live[$k] | type) == "object" and ($man[$k] | type) == "object" then
              deep_merge($live[$k]; $man[$k])
             else
              $live[$k]
             end))
    else
      $live // $man
    end;
  deep_merge($live; $man)
  | .adapterConfig.instructionsFilePath = ""
'

jq_merge_manifest_wins='
  def deep_merge($live; $man):
    if ($live | type) == "object" and ($man | type) == "object" then
      ($man | to_entries | map(.key) + ($live | to_entries | map(.key))) | unique as $keys
      | reduce $keys[] as $k ({};
          .[$k] =
            (if $man[$k] == null then $live[$k]
             elif ($live[$k] | type) == "object" and ($man[$k] | type) == "object" then
              deep_merge($live[$k]; $man[$k])
             else
              $man[$k]
             end))
    else
      $man // $live
    end;
  deep_merge($live; $man)
  | .adapterConfig.instructionsFilePath = ""
'

# --- 3. Walk manifests -------------------------------------------------------

summary_rows=()
ceo_id=""

shopt -s nullglob
manifest_files=("${MANIFEST_DIR}"/*.json)
if [ ${#manifest_files[@]} -eq 0 ]; then
  log "FATAL: no manifests found in ${MANIFEST_DIR}"
  exit 1
fi

for manifest in "${manifest_files[@]}"; do
  agent_manifest="$(jq '.agents[0]' "$manifest")"
  if [ "$agent_manifest" = "null" ]; then
    log "  Skipping ${manifest} (no agents[0])"
    continue
  fi
  name="$(printf '%s' "$agent_manifest" | jq -r '.name')"
  role="$(printf '%s' "$agent_manifest" | jq -r '.role // empty')"

  log "==> ${name}"

  live="$(printf '%s' "$agents_list" | jq --arg n "$name" '.[] | select(.name == $n)' | head -n 200 || true)"
  if [ -z "$live" ] || [ "$live" = "null" ]; then
    # Missing — hire via agent-hires API.
    log "    not found → POST /agent-hires"
    if [ $DRY_RUN -eq 1 ]; then
      summary_rows+=("${name}|<dry-run>|would-hire|-")
      continue
    fi
    hire_body="$(jq -n --argjson a "$agent_manifest" '$a')"
    resp="$(api POST "/api/companies/${PAPERCLIP_COMPANY_ID}/agent-hires" -d "$hire_body" || true)"
    approval_id="$(printf '%s' "$resp" | jq -r '.approvalId // .id // empty')"
    if [ -n "$approval_id" ]; then
      summary_rows+=("${name}|<pending>|hire-submitted|approvalId=${approval_id}")
    else
      summary_rows+=("${name}|-|hire-failed|${resp:0:120}")
    fi
    continue
  fi

  agent_id="$(printf '%s' "$live" | jq -r '.id')"
  if [ "$role" = "ceo" ] || [ -z "$ceo_id" ] && [ "$role" = "ceo" ]; then
    ceo_id="$agent_id"
  fi

  if [ $FORCE -eq 1 ]; then
    merged="$(jq -n \
      --argjson live "$live" \
      --argjson man "$agent_manifest" \
      "${jq_merge_manifest_wins}")"
  else
    merged="$(jq -n \
      --argjson live "$live" \
      --argjson man "$agent_manifest" \
      "${jq_merge_live_wins}")"
  fi

  # Only include fields the PATCH endpoint accepts — drop id/companyId/timestamps.
  patch_body="$(printf '%s' "$merged" | jq '{
    name, role, title, icon, capabilities,
    adapterType, adapterConfig, runtimeConfig
  } | with_entries(select(.value != null))')"

  # Compute a tiny diff summary (changed top-level keys).
  changed="$(jq -n --argjson live "$live" --argjson merged "$merged" '
    [($merged | keys_unsorted[]) as $k
     | select($merged[$k] != $live[$k])
     | $k] | join(",")')"

  if [ -z "$changed" ] || [ "$changed" = "\"\"" ]; then
    log "    no-op (all fields already match)"
    summary_rows+=("${name}|${agent_id}|no-op|-")
    continue
  fi

  log "    fields to change: ${changed}"
  if [ $DRY_RUN -eq 1 ]; then
    summary_rows+=("${name}|${agent_id}|dry-run|${changed}")
    continue
  fi

  resp="$(api PATCH "/api/agents/${agent_id}" -d "$patch_body" || true)"
  if printf '%s' "$resp" | jq -e '.id // empty' >/dev/null 2>&1; then
    summary_rows+=("${name}|${agent_id}|merged|${changed}")
  else
    summary_rows+=("${name}|${agent_id}|patch-failed|${resp:0:120}")
  fi
done

# --- 4. Ensure CEO has canCreateAgents -------------------------------------

if [ -z "$ceo_id" ]; then
  ceo_id="$(printf '%s' "$agents_list" | jq -r '[.[] | select(.role == "ceo")][0].id // empty')"
fi
if [ -n "$ceo_id" ] && [ $DRY_RUN -eq 0 ]; then
  log "==> Ensuring CEO (${ceo_id}) has canCreateAgents=true"
  api PATCH "/api/agents/${ceo_id}/permissions" \
    -d '{"canCreateAgents": true}' >/dev/null || \
    log "    warning: permission patch failed"
fi

# --- 5. Summary --------------------------------------------------------------

printf '\n%-30s %-38s %-16s %s\n' "AGENT" "ID" "ACTION" "NOTES"
printf '%-30s %-38s %-16s %s\n' "------------------------------" "--------------------------------------" "----------------" "-------------------------"
for row in "${summary_rows[@]}"; do
  IFS='|' read -r n i a note <<<"$row"
  printf '%-30s %-38s %-16s %s\n' "$n" "$i" "$a" "$note"
done

printf '\nSnapshot: %s\n' "${SNAPSHOT_FILE}"
if [ $DRY_RUN -eq 1 ]; then
  printf 'Dry-run only — no writes performed.\n'
fi
