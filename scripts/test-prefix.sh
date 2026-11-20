#!/usr/bin/env bash
# test-prefix.sh <llmd|direct> [label] — 10 requests sharing a ~1.5k-token prefix, 3 s apart.
#   llmd   -> through the llm-d router (KV-cache aware)
#   direct -> through the plain 'vllm-direct' Service (random pod per connection)
# The label goes into the prefix, so each run starts cold. Use a new label per run.
# Same test as the upstream guide's "Verify precise prefix-cache aware routing".
set -euo pipefail
TARGET=${1:?usage: test-prefix.sh <llmd|direct> [label]}
LABEL=${2:-run-$(date +%s)}
NS=${NAMESPACE:-llm-d-precise-prefix-cache-routing}
GUIDE=${GUIDE_NAME:-precise-prefix-cache-routing}
MODEL=${MODEL:-Qwen/Qwen3-0.6B}
case "$TARGET" in
  llmd)   URL="http://${GUIDE}-epp" ;;
  direct) URL="http://vllm-direct:8000" ;;
  *) echo "target must be llmd or direct"; exit 1 ;;
esac
echo "target=$TARGET url=$URL label=$LABEL"
# Timestamps + ready-made Grafana links for this run, padded 30 s before / 60 s after
# (Prometheus scrapes every 30 s). Times are shown in IST; the links use epoch ms,
# so they open the right window in any browser timezone.
# GRAFANA_URL: where Grafana is reachable from your browser (port-forward + ssh tunnel).
GRAFANA_URL=${GRAFANA_URL:-http://localhost:3000}
START_S=$(date +%s)
echo "start: $(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S IST')"
trap 'END_S=$(date +%s); F=$((START_S-30))000; T=$((END_S+60))000;
  echo "end:   $(TZ=Asia/Kolkata date "+%Y-%m-%d %H:%M:%S IST")";
  echo "Grafana, this run:";
  echo "  Performance:  $GRAFANA_URL/d/llm-d-performance?orgId=1&from=$F&to=$T&var-namespace=$NS";
  echo "  Drill-Down:   $GRAFANA_URL/d/llm-d-diagnostic-drilldown?orgId=1&from=$F&to=$T&var-namespace=$NS"' EXIT
kubectl run "prefix-test-$TARGET" --rm -i --restart=Never --quiet \
  --image=cfmanteiga/alpine-bash-curl-jq:latest -n "$NS" \
  --env="URL=$URL" --env="MODEL=$MODEL" --env="LABEL=$LABEL" \
  -- /bin/sh -c 'P=$(for i in $(seq 1 100); do printf "[$LABEL] A shared document that every request in this test starts with. "; done)
    for i in $(seq 1 10); do
      curl -sS -o /dev/null -w "request ${i}: HTTP %{http_code}  %{time_total}s\n" -X POST "${URL}/v1/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"${MODEL}\", \"prompt\": \"${P} Question ${i}: summarise it.\", \"max_tokens\": 16}"
      sleep 3
    done'
