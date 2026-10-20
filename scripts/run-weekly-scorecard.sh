#!/usr/bin/env bash
# Weekly delivery scorecard, headless, with the cmis CLI (a pinned release of Clear Measure Intelligence Scorecard):
# register one GitHubDelivery connection per repository, harvest the window, score it by ISO week, and write the
# numbers (JSON, CSV, markdown) to $OUT_DIR/weekly/<ISO week>/.
# Env: CMIS (path to the cmis binary), OUT_DIR, HARVEST_TOKEN (GitHub read token), SINCE_DAYS (84), SYSTEM_NAME,
#      CONNECTIONS_FILE or SYSTEM_JSON (which repositories). No secret is printed.
set -euo pipefail
: "${CMIS:?}" "${OUT_DIR:?}" "${HARVEST_TOKEN:?}"
SINCE_DAYS="${SINCE_DAYS:-84}"; SYSTEM_NAME="${SYSTEM_NAME:-system}"
T="${RUNNER_TEMP:-/tmp}"
# Without connections.json, a kit system's system.json names them: the system repository and every deployable.
if [ -z "${CONNECTIONS_FILE:-}" ] || [ ! -f "$CONNECTIONS_FILE" ]; then
  : "${SYSTEM_JSON:?}"
  jq '{owner:.system.githubOrg, connections:([{id:"system", repo:.system.repository}]
       + [.deployables[] | {id:.name, repo:.repository}])}' "$SYSTEM_JSON" > "$T/connections.json"
  CONNECTIONS_FILE="$T/connections.json"
fi
W=(--workspace "$T/cmis-ws" --store "$T/cmis-store"); mkdir -p "$T/cmis-ws" "$T/cmis-store"
"$CMIS" --version | jq -r .data.version
OWNER="$(jq -r .owner "$CONNECTIONS_FILE")"; IDS=()
while read -r c; do
  id="$(jq -r .id <<<"$c")"; repo="$(jq -r .repo <<<"$c")"; IDS+=("$id")
  "$CMIS" connections add "${W[@]}" --json --id "$id" --name "$repo" --tracker GitHubDelivery \
    --coordinate "owner=$OWNER" --coordinate "repo=$repo" | jq -e .ok >/dev/null
  printf '%s' "$HARVEST_TOKEN" | "$CMIS" connect set-token "${W[@]}" --json --connection "$id" --stdin | jq -e .ok >/dev/null
done < <(jq -c '.connections[]' "$CONNECTIONS_FILE")
unset HARVEST_TOKEN
SINCE="$(date -u -d "-$SINCE_DAYS days" +%F)"; UNTIL="$(date -u +%F)"
"$CMIS" connections harvest "${W[@]}" --json --since "$SINCE" --until "$UNTIL" --on-failure strict > "$T/harvest.json" || true
jq -e .ok "$T/harvest.json" >/dev/null || { jq -c .error "$T/harvest.json"; exit 1; }

WEEK="$(date -u +%G-W%V)"; D="$OUT_DIR/weekly/$WEEK"; mkdir -p "$D"
CONN_ARGS=(); for id in "${IDS[@]}"; do CONN_ARGS+=(--connection "$id"); done
"$CMIS" connections score "${W[@]}" --json "${CONN_ARGS[@]}" --since "$SINCE" --until "$UNTIL" > "$D/cmis_score.json"
jq -e .ok "$D/cmis_score.json" >/dev/null || { jq -c .error "$D/cmis_score.json"; exit 1; }
"$CMIS" connections inventory "${W[@]}" --json > "$D/cmis_inventory.json"
cp "$T/harvest.json" "$D/cmis_harvest.json"
# The same shape the earlier Scorecard.Web harvest wrote, so the dashboard reads it unchanged.
# cmis reports mean time to delivery in weeks for a weekly period; hours = weeks x 168.
jq '{weeks:[.data.periods[] | {periodLabel:.label, weekStart:(.periodStart[0:10]), itemsDelivered, throughput, rework,
      netThroughput, itemsStarted, workInProcess, itemsStopped,
      meanTimeToDeliveryHours:(if .meanTimeToDelivery == null then null else (.meanTimeToDelivery*168*100|round/100) end),
      closedNotDelivered:null}]}' "$D/cmis_score.json" > "$D/weekly_scorecard.json"
jq --slurpfile h "$T/harvest.json" '{repositories:[.data.connections[] as $c | {id:$c.connectionId, repository:$c.name,
      workItems:$c.normalizedItems, issues:null, pullRequests:null, deployments:null,
      deliveredStage:($c.boardColumns|last)}]}' "$D/cmis_inventory.json" > "$D/delivery_repositories.json"
jq -r '["week","weekStart","itemsDelivered","throughput","rework","netThroughput","itemsStarted","workInProcess","meanTimeToDeliveryHours","closedNotDelivered"],
  (.weeks[] | [.periodLabel,.weekStart,.itemsDelivered,.throughput,.rework,.netThroughput,.itemsStarted,.workInProcess,.meanTimeToDeliveryHours,.closedNotDelivered]) | @csv' \
  "$D/weekly_scorecard.json" > "$D/weekly_scorecard.csv"
GEN="$(date -u +%FT%TZ)"; VER="$("$CMIS" --version | jq -r .data.version)"
jq --arg week "$WEEK" --arg gen "$GEN" --arg sys "$SYSTEM_NAME" --arg since "$SINCE" --arg ver "$VER" \
  --slurpfile r "$D/delivery_repositories.json" \
  '{system:$sys, isoWeek:$week, generatedUtc:$gen, harvestSince:$since, scorecardVersion:$ver,
    repositories:$r[0].repositories, latestWeek:(.weeks | last), weeks:.weeks}' "$D/weekly_scorecard.json" > "$D/summary.json"
{
  echo "# Delivery scorecard: $SYSTEM_NAME, $WEEK"
  echo; echo "Generated $GEN by the weekly scorecard workflow with cmis $VER. Harvest window: $SINCE to now."
  echo; echo "| Week | Delivered | Throughput | Rework | Net throughput | Started | WIP | Mean time to delivery (h) |"
  echo "|---|---|---|---|---|---|---|---|"
  jq -r '.weeks[] | "| \(.periodLabel) | \(.itemsDelivered) | \(.throughput) | \(.rework) | \(.netThroughput) | \(.itemsStarted) | \(.workInProcess) | \(.meanTimeToDeliveryHours // "-") |"' "$D/weekly_scorecard.json"
  echo; echo "Repositories:"; jq -r '.repositories[] | "- \(.repository): \(.workItems) work items, delivered stage \(.deliveredStage)"' "$D/delivery_repositories.json"
} > "$D/summary.md"
rm -rf "$OUT_DIR/latest"; cp -r "$D" "$OUT_DIR/latest"
H="$OUT_DIR/history.csv"; [ -f "$H" ] || echo 'isoWeek,week,weekStart,itemsDelivered,throughput,rework,netThroughput,itemsStarted,workInProcess,meanTimeToDeliveryHours,closedNotDelivered' > "$H"
grep -v "^\"\?$WEEK\"\?," "$H" > "$H.tmp" || true; mv "$H.tmp" "$H"
tail -n +2 "$D/weekly_scorecard.csv" | sed "s/^/\"$WEEK\",/" >> "$H"
echo "Wrote $D"
