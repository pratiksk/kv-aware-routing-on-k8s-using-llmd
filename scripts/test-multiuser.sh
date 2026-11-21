#!/usr/bin/env bash
# test-multiuser.sh <llmd|direct> [users] [rounds] [label]
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
# Start and end time of the run (IST), e.g. for finding it in Grafana.
echo "start: $(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S IST')"
trap 'echo "end:   $(TZ=Asia/Kolkata date "+%Y-%m-%d %H:%M:%S IST")"' EXIT
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
