#!/usr/bin/env bash
# test-multiuser.sh <llmd|direct> [users] [rounds] [label] — UNTESTED
# Many "users", each with their own ~2.7k-token prefix (a chat history or document),
# sending interleaved requests. Size it so all prefixes together are MORE than one
# pod's KV cache but LESS than all pods' caches combined:
#   1gpu-small: ~37k tokens per pod, 2 pods -> 18-20 users x ~2.7k = ~50-55k tokens.
# Random routing: every pod sees every user, tries to cache all of it, evicts, misses.
# llm-d: keeps each user on one pod, ~25-27k per pod fits, hits stay high.
set -euo pipefail
TARGET=${1:?usage: test-multiuser.sh <llmd|direct> [users] [rounds] [label]}
USERS=${2:-20}
ROUNDS=${3:-6}
LABEL=${4:-run-$(date +%s)}
NS=${NAMESPACE:-llm-d-precise-prefix-cache-routing}
GUIDE=${GUIDE_NAME:-precise-prefix-cache-routing}
MODEL=${MODEL:-Qwen/Qwen3-0.6B}
case "$TARGET" in
  llmd)   URL="http://${GUIDE}-epp" ;;
  direct) URL="http://vllm-direct:8000" ;;
  *) echo "target must be llmd or direct"; exit 1 ;;
esac
echo "target=$TARGET users=$USERS rounds=$ROUNDS label=$LABEL"
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
kubectl run "multiuser-test-$TARGET" --rm -i --restart=Never --quiet \
  --image=cfmanteiga/alpine-bash-curl-jq:latest -n "$NS" \
  --env="URL=$URL" --env="MODEL=$MODEL" --env="LABEL=$LABEL" \
  --env="USERS=$USERS" --env="ROUNDS=$ROUNDS" \
  -- /bin/sh -c 'for r in $(seq 1 $ROUNDS); do
      for u in $(seq 1 $USERS); do
        P=$(for i in $(seq 1 100); do printf "[$LABEL user $u] This is the private document of user $u. "; done)
        curl -sS -o /dev/null -w "round $r user $u: HTTP %{http_code}  %{time_total}s\n" -X POST "${URL}/v1/completions" \
          -H "Content-Type: application/json" \
          -d "{\"model\": \"${MODEL}\", \"prompt\": \"${P} Turn ${r}: what next?\", \"max_tokens\": 16}"
        sleep 0.5
      done
    done'
