#!/usr/bin/env bash
# Token efficiency + MCP usage report for Tsunami Automation.
#
# Read-only. Pulls two things from the Paperclip API:
#
#   1. Per-run `usageJson` from /api/companies/{id}/heartbeat-runs.
#      Gives us input / cached-input / output tokens per run, so we can
#      compute cache-hit rate and estimated cost per agent.
#
#   2. Raw run log from /api/heartbeat-runs/{id}/log (best-effort, capped
#      at SAMPLE_RUNS_PER_AGENT per agent). Parsed for `mcp__*` tool
#      names so we can tell whether an MCP server is actually being used.
#
# Output:
#   - Markdown report to stdout (two tables + red-flag section).
#   - Raw aggregates to ./report/tsunami-usage-<ts>.json.
#
# Env vars:
#   PAPERCLIP_API_URL         (required)
#   PAPERCLIP_API_KEY         (required)
#   PAPERCLIP_COMPANY_ID      (required)
#   WINDOW_DAYS               default: 7
#   SAMPLE_RUNS_PER_AGENT     default: 20  (bounds log fetches)
#   LOG_LIMIT_BYTES           default: 262144 (256 KB per run)
#   CACHE_HIT_RED_FLAG_PCT    default: 50  (flag cache-hit <%)
#
# This script writes nothing to the database or to any live resource.

set -euo pipefail

: "${PAPERCLIP_API_URL:?PAPERCLIP_API_URL is required}"
: "${PAPERCLIP_API_KEY:?PAPERCLIP_API_KEY is required}"
: "${PAPERCLIP_COMPANY_ID:?PAPERCLIP_COMPANY_ID is required}"

WINDOW_DAYS="${WINDOW_DAYS:-7}"
SAMPLE_RUNS_PER_AGENT="${SAMPLE_RUNS_PER_AGENT:-20}"
LOG_LIMIT_BYTES="${LOG_LIMIT_BYTES:-262144}"
CACHE_HIT_RED_FLAG_PCT="${CACHE_HIT_RED_FLAG_PCT:-50}"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORT_DIR="${REPO_ROOT}/report"
TS="$(date -u +%Y%m%d-%H%M%S)"
OUT_JSON="${REPORT_DIR}/tsunami-usage-${TS}.json"
mkdir -p "${REPORT_DIR}"

# Cutoff for the reporting window — everything started before this is ignored.
if date -u -v-"${WINDOW_DAYS}"d +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
  SINCE_ISO="$(date -u -v-"${WINDOW_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)"    # BSD
else
  SINCE_ISO="$(date -u -d "-${WINDOW_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)" # GNU
fi

auth=(-H "Authorization: Bearer ${PAPERCLIP_API_KEY}")

api() {
  local path="$1"
  curl -sS "${PAPERCLIP_API_URL}${path}" "${auth[@]}" 2>/dev/null || printf '{}'
}
norm() { jq 'if type == "array" then . elif .items then .items else . end'; }

# --- Model prices ($/Mtok) --------------------------------------------------
# Rough public list prices. Override any of these via env if you have
# negotiated rates (e.g. PRICE_CLAUDE_SONNET_IN=2.8).
#
# Keyed by <adapter>:<model> → "<input_usd_per_mtok>:<cached_input_usd_per_mtok>:<output_usd_per_mtok>"
#
# Cached-input is billed at a discount; we use a conservative 0.25× of
# the input price when we don't have a specific number.

prices_tsv=$(cat <<'EOF'
claude_local:claude-sonnet-4-6	3.00	0.30	15.00
claude_local:claude-sonnet-4-5	3.00	0.30	15.00
claude_local:claude-opus-4-7	15.00	1.50	75.00
claude_local:claude-haiku-4-5-20251001	0.80	0.08	4.00
codex_local:gpt-5-mini	0.25	0.0625	2.00
codex_local:gpt-5-nano	0.10	0.025	0.80
codex_local:o4-mini	1.10	0.275	4.40
codex_local:gpt-5	1.25	0.3125	10.00
gemini_local:gemini-2.5-pro	1.25	0.3125	10.00
gemini_local:gemini-2.5-flash	0.30	0.075	2.50
gemini_local:gemini-2.5-flash-lite	0.075	0.01875	0.30
gemini_local:gemini-2.0-flash	0.10	0.025	0.40
gemini_local:gemini-2.0-flash-lite	0.075	0.01875	0.30
EOF
)

price_for() {
  # $1 = adapter, $2 = model → prints "in cached out" (tab-separated), or empty if unknown.
  local key="$1:$2"
  echo "$prices_tsv" | awk -F'\t' -v k="$key" '$1==k {print $2"\t"$3"\t"$4; exit}'
}

# --- 1. Agents --------------------------------------------------------------

agents="$(api "/api/companies/${PAPERCLIP_COMPANY_ID}/agents" | norm)"
agent_count="$(printf '%s' "$agents" | jq 'length')"
if [ "$agent_count" = "0" ]; then
  echo "No agents found in company ${PAPERCLIP_COMPANY_ID}" >&2
  exit 1
fi

# --- 2. Fetch recent runs (all agents, one call) ----------------------------
# Endpoint returns full usage_json. We cap at 1000 (endpoint max) which is
# fine: for 6 Tsunami agents over 7 days at 30m–8h cadence we expect ~600
# runs max.

all_runs="$(api "/api/companies/${PAPERCLIP_COMPANY_ID}/heartbeat-runs?limit=1000" | norm)"
total_runs="$(printf '%s' "$all_runs" | jq 'length')"

# Filter to window.
runs="$(printf '%s' "$all_runs" | jq --arg since "$SINCE_ISO" '
  [.[] | select((.startedAt // .createdAt) != null
                and ((.startedAt // .createdAt) >= $since))]
')"
window_runs="$(printf '%s' "$runs" | jq 'length')"

# --- 3. Aggregate tokens per agent -----------------------------------------

agent_usage="$(printf '%s' "$runs" | jq '
  group_by(.agentId) |
  map({
    agentId: .[0].agentId,
    runs: length,
    succeededRuns: (map(select(.status == "succeeded")) | length),
    failedRuns: (map(select(.status == "failed")) | length),
    inputTokens:
      (map((.usageJson.inputTokens // .usageJson.input_tokens // 0)) | add // 0),
    cachedInputTokens:
      (map((.usageJson.cachedInputTokens // .usageJson.cache_read_input_tokens // 0)) | add // 0),
    outputTokens:
      (map((.usageJson.outputTokens // .usageJson.output_tokens // 0)) | add // 0)
  })
')"

# Join with agent metadata + compute cache-hit%, estimated cost.
report_rows="$(jq -n \
  --argjson agents "$agents" \
  --argjson usage "$agent_usage" \
  --arg pricesTsv "$prices_tsv" '
  def price($adapter; $model):
    ($pricesTsv | split("\n") | map(split("\t")) |
      map(select(.[0] == ($adapter + ":" + $model))) |
      (.[0] // null)) as $row |
    if $row == null then null
    else { in: ($row[1] | tonumber), cached: ($row[2] | tonumber), out: ($row[3] | tonumber) }
    end;

  [$agents[] as $a |
    ($usage | map(select(.agentId == $a.id)) | (.[0] // null)) as $u |
    ($a.adapterType // "") as $adapter |
    (($a.adapterConfig.model // "") | tostring) as $model |
    price($adapter; $model) as $p |
    ((($u.inputTokens // 0) + ($u.cachedInputTokens // 0)) // 0) as $totalIn |
    (if $totalIn > 0 then (($u.cachedInputTokens // 0) * 100.0 / $totalIn) else 0 end) as $cacheHitPct |
    (if $p == null then null
     else (($u.inputTokens // 0) * $p.in
         + ($u.cachedInputTokens // 0) * $p.cached
         + ($u.outputTokens // 0) * $p.out) / 1000000.0
     end) as $costUsd |
    ({
      id: $a.id,
      name: $a.name,
      role: $a.role,
      adapterType: $adapter,
      model: $model,
      mcpServersConfigured: ($a.adapterConfig.mcpServers // {} | keys),
      runs: ($u.runs // 0),
      succeededRuns: ($u.succeededRuns // 0),
      failedRuns: ($u.failedRuns // 0),
      inputTokens: ($u.inputTokens // 0),
      cachedInputTokens: ($u.cachedInputTokens // 0),
      outputTokens: ($u.outputTokens // 0),
      cacheHitPct: ($cacheHitPct | (. * 10 | round) / 10),
      avgTokensPerRun:
        (if ($u.runs // 0) > 0
         then (((($u.inputTokens // 0) + ($u.cachedInputTokens // 0) + ($u.outputTokens // 0)) / $u.runs) | round)
         else 0 end),
      estCostUsd:
        (if $costUsd == null then null else ($costUsd * 10000 | round) / 10000 end),
      pricingKnown: ($p != null)
    })
  ]
')"

# --- 4. MCP usage sampling (log scan) --------------------------------------
# For each agent with mcpServers configured, take the most recent N runs in
# the window and scan their logs for `mcp__<server>__<tool>` names.

mcp_report='[]'
runs_by_agent="$(printf '%s' "$runs" | jq 'group_by(.agentId) | map({agentId: .[0].agentId, runs: sort_by(.startedAt // .createdAt) | reverse})')"

for agent_id in $(printf '%s' "$report_rows" | jq -r '.[] | select(.mcpServersConfigured | length > 0) | .id'); do
  agent_name="$(printf '%s' "$report_rows" | jq -r --arg id "$agent_id" '.[] | select(.id==$id) | .name')"
  mcp_servers="$(printf '%s' "$report_rows" | jq -c --arg id "$agent_id" '.[] | select(.id==$id) | .mcpServersConfigured')"
  sample_ids="$(printf '%s' "$runs_by_agent" | jq -r --arg id "$agent_id" --argjson k "$SAMPLE_RUNS_PER_AGENT" '
    .[] | select(.agentId == $id) | .runs[:$k] | .[].id')"
  sampled=0
  tool_counts="{}"
  for run_id in $sample_ids; do
    sampled=$((sampled + 1))
    log_json="$(api "/api/heartbeat-runs/${run_id}/log?limitBytes=${LOG_LIMIT_BYTES}")"
    content="$(printf '%s' "$log_json" | jq -r '.content // .log // ""' 2>/dev/null || printf '')"
    [ -z "$content" ] && continue
    # Pull every mcp__<server>__<tool> name seen in this run's stream.
    names="$(printf '%s' "$content" | grep -oE 'mcp__[A-Za-z0-9_-]+__[A-Za-z0-9_-]+' || true)"
    [ -z "$names" ] && continue
    tool_counts="$(jq -n --argjson tc "$tool_counts" --arg names "$names" '
      $tc as $c |
      reduce ($names | split("\n") | map(select(. != ""))) [] as $n ($c;
        .[$n] = ((.[$n] // 0) + 1)
      )
    ')"
  done
  totals="$(printf '%s' "$tool_counts" | jq '[.[]] | add // 0')"
  mcp_report="$(jq -n \
    --argjson report "$mcp_report" \
    --arg id "$agent_id" \
    --arg name "$agent_name" \
    --argjson servers "$mcp_servers" \
    --argjson sampled "$sampled" \
    --argjson counts "$tool_counts" \
    --argjson totalCalls "$totals" '
    $report + [{
      agentId: $id,
      agentName: $name,
      mcpServersConfigured: $servers,
      runsSampled: $sampled,
      totalMcpToolCalls: $totalCalls,
      toolCallsByName: $counts
    }]
  ')"
done

# --- 5. Red flags -----------------------------------------------------------

flags="$(jq -n \
  --argjson rows "$report_rows" \
  --argjson mcp "$mcp_report" \
  --arg minCache "$CACHE_HIT_RED_FLAG_PCT" '
  ([$rows[] |
    select(.runs > 0 and .cacheHitPct < ($minCache | tonumber)) |
    { agentName: .name, kind: "low-cache-hit",
      detail: ("cache-hit \(.cacheHitPct)% < \($minCache)%") }]
   +
   [$rows[] | select(.mcpServersConfigured | length > 0) as $r |
    ($mcp | map(select(.agentId == $r.id)) | (.[0] // {})) as $m |
    select(($m.totalMcpToolCalls // 0) == 0 and ($m.runsSampled // 0) > 0) |
    { agentName: $r.name, kind: "mcp-configured-but-unused",
      detail: ("\($m.runsSampled) runs sampled, 0 mcp__ tool calls seen") }]
   +
   [$rows[] | select(.pricingKnown == false and .runs > 0) |
    { agentName: .name, kind: "unknown-pricing",
      detail: "no price entry for \(.adapterType):\(.model); add one to the script to see cost" }])
  | sort_by(.kind, .agentName)
')"

# --- 6. Persist raw JSON ----------------------------------------------------

jq -n \
  --arg ts "$TS" \
  --arg company "$PAPERCLIP_COMPANY_ID" \
  --arg windowDays "$WINDOW_DAYS" \
  --arg sinceIso "$SINCE_ISO" \
  --argjson totalRunsFetched "$total_runs" \
  --argjson windowRuns "$window_runs" \
  --argjson perAgent "$report_rows" \
  --argjson mcp "$mcp_report" \
  --argjson flags "$flags" '
  {
    timestamp: $ts,
    companyId: $company,
    windowDays: ($windowDays | tonumber),
    since: $sinceIso,
    totalRunsFetched: $totalRunsFetched,
    runsInWindow: $windowRuns,
    perAgent: $perAgent,
    mcp: $mcp,
    flags: $flags
  }' > "${OUT_JSON}"

# --- 7. Markdown report -----------------------------------------------------

cat <<MD
# Tsunami Automation — token + MCP usage — ${TS}

Company: \`${PAPERCLIP_COMPANY_ID}\`
Window: last ${WINDOW_DAYS} days (since \`${SINCE_ISO}\`)
Runs in window: ${window_runs} / ${total_runs} fetched
Sample depth for MCP log scan: ${SAMPLE_RUNS_PER_AGENT} runs/agent, ${LOG_LIMIT_BYTES} bytes/run

## Token efficiency per agent

| Agent | Adapter / model | Runs | Succ | Fail | Input | Cached | Output | Cache-hit % | Avg tok/run | Est cost (USD) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
MD
printf '%s' "$report_rows" | jq -r '
  sort_by(-.runs) | .[] |
  "| \(.name) | \(.adapterType) / \(.model) | \(.runs) | \(.succeededRuns) | \(.failedRuns) | "
  + "\(.inputTokens) | \(.cachedInputTokens) | \(.outputTokens) | "
  + "\(.cacheHitPct)% | \(.avgTokensPerRun) | "
  + (if .estCostUsd == null then "_unknown_"
     elif .estCostUsd < 0.01 then "$\(.estCostUsd * 10000 | round / 10000)"
     else "$\(.estCostUsd * 100 | round / 100)" end)
  + " |"'

cat <<MD

> Cache-hit % = cached-input ÷ (input + cached-input). Higher is better — it means prompt caching is reusing earlier tokens.
> Est cost uses public list prices (see price table at top of the script). Override with negotiated rates by editing the prices_tsv block.

## MCP usage (log sample)

MD
mcp_count=$(printf '%s' "$mcp_report" | jq 'length')
if [ "$mcp_count" = "0" ]; then
  echo "_No agents have \`adapterConfig.mcpServers\` configured in this window._"
else
  cat <<MD
| Agent | MCP servers configured | Runs sampled | Total mcp__ tool calls | Per-tool counts |
|---|---|---:|---:|---|
MD
  printf '%s' "$mcp_report" | jq -r '
    .[] | "| \(.agentName) | \(.mcpServersConfigured | join(", ")) | "
       + "\(.runsSampled) | \(.totalMcpToolCalls) | "
       + ((.toolCallsByName | to_entries | map("\(.key)=\(.value)") | join(", "))
          // "_none_")
       + " |"'
fi

cat <<MD

## Red flags

MD
flag_count=$(printf '%s' "$flags" | jq 'length')
if [ "$flag_count" = "0" ]; then
  echo "_none_"
else
  printf '%s' "$flags" | jq -r '.[] | "- **\(.kind)** on \(.agentName): \(.detail)"'
fi

cat <<MD

---

Raw JSON: \`${OUT_JSON}\`

## How to read this

1. **Cache-hit < 50%** on a Claude-backed agent usually means the prompt is changing on every run. Check that \`sessionHandoffMarkdown\` is enabled and the promptTemplate is stable.
2. **mcp-configured-but-unused** on an agent with MCP servers means the agent has not called any \`mcp__*\` tool in the sampled runs. Either the skill isn't prompting them to use it, the MCP server is down, or the server should be removed from their adapterConfig to save init overhead.
3. **unknown-pricing** means the script has no cost entry for that adapter/model combo — add a row to \`prices_tsv\` in the script to include it in cost totals.
MD
