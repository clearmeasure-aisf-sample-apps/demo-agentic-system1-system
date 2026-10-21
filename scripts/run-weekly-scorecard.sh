#!/usr/bin/env bash
# Weekly delivery scorecard, headless: start Scorecard.Web on loopback, harvest, read the numbers over its
# read-only MCP endpoint, and write them (JSON, CSV, markdown) to $OUT_DIR/<ISO week>/.
# Env: SCORECARD_DLL, OUT_DIR, HARVEST_TOKEN (GitHub read token), SINCE_DAYS (84), SYSTEM_NAME,
#      and the Scorecard__* settings that name the connections. No secret is printed.
set -euo pipefail
: "${SCORECARD_DLL:?}" "${OUT_DIR:?}" "${HARVEST_TOKEN:?}"
SINCE_DAYS="${SINCE_DAYS:-84}"; PORT="${PORT:-8089}"; SYSTEM_NAME="${SYSTEM_NAME:-system}"
# Without connections.json, a kit system's system.json names them: the system repository and every deployable,
# paired with the Octopus project <slug>-<deployable>.
if [ -n "${CONNECTIONS_FILE:-}" ] && [ ! -f "$CONNECTIONS_FILE" ] && [ -f "${SYSTEM_JSON:-}" ]; then
  jq '.system.slug as $slug | {owner:.system.githubOrg, octopusServer:.octopus.url, octopusSpace:.octopus.spaceId,
       connections:([{id:"system", repo:.system.repository, octopusProject:($slug+"-system")}]
         + [.deployables[] | {id:.name, repo:.repository, octopusProject:(.octopusProject // ($slug+"-"+.name))}])}' "$SYSTEM_JSON" \
    > "${RUNNER_TEMP:-/tmp}/connections.json"
  CONNECTIONS_FILE="${RUNNER_TEMP:-/tmp}/connections.json"
fi
# Connections: a JSON file {"owner":..,"octopusServer":..,"octopusSpace":..,"connections":[{"id","repo","octopusProject"?,"environments"?}]}
if [ -n "${CONNECTIONS_FILE:-}" ]; then
  export Scorecard__Defaults__Owner="$(jq -r .owner "$CONNECTIONS_FILE")"
  [ "$(jq -r '.octopusServer // ""' "$CONNECTIONS_FILE")" = "" ] || export Scorecard__Defaults__OctopusServer="$(jq -r .octopusServer "$CONNECTIONS_FILE")"
  [ "$(jq -r '.octopusSpace // ""' "$CONNECTIONS_FILE")" = "" ] || export Scorecard__Defaults__OctopusSpace="$(jq -r .octopusSpace "$CONNECTIONS_FILE")"
  n="$(jq '.connections|length' "$CONNECTIONS_FILE")"
  for i in $(seq 0 $((n-1))); do
    c="$(jq -c ".connections[$i]" "$CONNECTIONS_FILE")"
    export "Scorecard__Connections__${i}__Id=$(jq -r .id <<<"$c")" "Scorecard__Connections__${i}__Name=$(jq -r '.name // .repo' <<<"$c")"
    export "Scorecard__Connections__${i}__Repo=$(jq -r .repo <<<"$c")" "Scorecard__Connections__${i}__OctopusProject=$( [ -n "${OCTOPUS_KEY:-}" ] && jq -r '.octopusProject // ""' <<<"$c" )"
    export "Scorecard__Connections__${i}__Enabled=true"
    [ "$(jq -r '.environments // ""' <<<"$c")" = "" ] || export "Scorecard__Connections__${i}__Environments=$(jq -r .environments <<<"$c")"
  done
  # the source's appsettings carries up to 16 default entries; switch off the rest
  for i in $(seq "$n" 15); do export "Scorecard__Connections__${i}__Enabled=false"; done
fi
[ -z "${OCTOPUS_KEY:-}" ] || export Scorecard__OctopusKey="$OCTOPUS_KEY"; unset OCTOPUS_KEY
KEY="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
export Scorecard__GitHubToken="$HARVEST_TOKEN" Scorecard__HarvestKey="$KEY" Scorecard__RefreshMinutes=0
export Scorecard__DataDirectory="${RUNNER_TEMP:-/tmp}/scorecard-work" ASPNETCORE_URLS="http://127.0.0.1:$PORT"
unset HARVEST_TOKEN
LOG="${RUNNER_TEMP:-/tmp}/scorecard-web.log"
dotnet "$SCORECARD_DLL" >"$LOG" 2>&1 &
PID=$!; trap 'kill $PID 2>/dev/null || true' EXIT
for _ in $(seq 1 90); do curl -fsS "http://127.0.0.1:$PORT/alive" >/dev/null 2>&1 && break; sleep 1; done
mcp() { curl -fsS -X POST "http://127.0.0.1:$PORT/mcp" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":{}}}" \
  | sed -n 's/^data: //p' | jq -r '.result.content[0].text'; }
SINCE="$(date -u -d "-$SINCE_DAYS days" +%F)"
curl -fsS -o /dev/null -X POST "http://127.0.0.1:$PORT/?handler=harvest" --data-urlencode "Since=$SINCE" --data-urlencode "Key=$KEY"
for _ in $(seq 1 360); do [ "$(mcp delivery_repositories | jq -r .harvested)" = true ] && break; sleep 5; done
[ "$(mcp delivery_repositories | jq -r .harvested)" = true ] || { echo "harvest did not finish"; tail -40 "$LOG"; exit 1; }

WEEK="$(date -u +%G-W%V)"; D="$OUT_DIR/weekly/$WEEK"; mkdir -p "$D"
for t in delivery_repositories weekly_scorecard dora_metrics delivery_stage_flow weekly_stage_times weekly_waste weekly_deployments; do
  mcp "$t" | jq . > "$D/$t.json" 2>/dev/null || rm -f "$D/$t.json"
done
jq -r '["week","weekStart","itemsDelivered","throughput","rework","netThroughput","itemsStarted","workInProcess","meanTimeToDeliveryHours","closedNotDelivered"],
  (.weeks[] | [.periodLabel,.weekStart,.itemsDelivered,.throughput,.rework,.netThroughput,.itemsStarted,.workInProcess,.meanTimeToDeliveryHours,.closedNotDelivered]) | @csv' \
  "$D/weekly_scorecard.json" > "$D/weekly_scorecard.csv"
GEN="$(date -u +%FT%TZ)"
jq --arg week "$WEEK" --arg gen "$GEN" --arg sys "$SYSTEM_NAME" --arg since "$SINCE" \
  --slurpfile r "$D/delivery_repositories.json" \
  '{system:$sys, isoWeek:$week, generatedUtc:$gen, harvestSince:$since,
    repositories:[$r[0].repositories[] | {id, repository, workItems, issues, pullRequests, deployments, deliveredStage}],
    latestWeek:(.weeks | last), weeks:.weeks}' "$D/weekly_scorecard.json" > "$D/summary.json"
{
  echo "# Delivery scorecard: $SYSTEM_NAME, $WEEK"
  echo; echo "Generated $GEN by the weekly scorecard workflow. Harvest window: $SINCE to now."
  echo; echo "| Week | Delivered | Throughput | Rework | Net throughput | Started | WIP | Mean time to delivery (h) |"
  echo "|---|---|---|---|---|---|---|---|"
  jq -r '.weeks[] | "| \(.periodLabel) | \(.itemsDelivered) | \(.throughput) | \(.rework) | \(.netThroughput) | \(.itemsStarted) | \(.workInProcess) | \(.meanTimeToDeliveryHours // "-") |"' "$D/weekly_scorecard.json"
  echo; echo "Repositories:"; jq -r '.repositories[] | "- \(.repository): \(.workItems) work items, delivered stage \(.deliveredStage)"' "$D/delivery_repositories.json"
} > "$D/summary.md"
rm -rf "$OUT_DIR/latest"; cp -r "$D" "$OUT_DIR/latest"
# history.csv: one row per (run week, scorecard week), newest data wins for a repeated pair
H="$OUT_DIR/history.csv"; [ -f "$H" ] || echo 'isoWeek,week,weekStart,itemsDelivered,throughput,rework,netThroughput,itemsStarted,workInProcess,meanTimeToDeliveryHours,closedNotDelivered' > "$H"
grep -v "^\"\?$WEEK\"\?," "$H" > "$H.tmp" || true; mv "$H.tmp" "$H"
tail -n +2 "$D/weekly_scorecard.csv" | sed "s/^/\"$WEEK\",/" >> "$H"
echo "Wrote $D"
