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
# Start and end time of the run (IST), e.g. for finding it in Grafana.
echo "start: $(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S IST')"
trap 'echo "end:   $(TZ=Asia/Kolkata date "+%Y-%m-%d %H:%M:%S IST")"' EXIT
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
