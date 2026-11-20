#!/usr/bin/env bash
# stats.sh — what the last test did, per vLLM pod: requests, prompt tokens looked up
# in the prefix cache, tokens found there, and hit rate.
# Each run shows the change since the previous run, then saves a new baseline.
#   ./scripts/stats.sh          before a test: sets the baseline (output can be ignored)
#                               after a test:  shows that test
#   ./scripts/stats.sh reset    set the baseline without printing
NS=${NAMESPACE:-llm-d-precise-prefix-cache-routing}
GUIDE=${GUIDE_NAME:-precise-prefix-cache-routing}
STATE=${STATE:-$HOME/.vllm-stats.prev}
touch "$STATE"
NEW=$(mktemp)

pct() { awk -v h="$1" -v q="$2" 'BEGIN { if (q > 0) printf "%.0f%%", 100*h/q; else printf "-" }'; }
line() { printf -- "--------+--------------------------------------\n"; }

if [ "$1" != "reset" ]; then
  SINCE=$(awk '$1=="#time" {print $2}' "$STATE")
  echo; echo "Since last run${SINCE:+ ($SINCE)}:"
  printf "%-7s | %8s %10s %10s %6s\n" "POD" "REQ" "QUERIED" "HIT" "HIT%"; line
fi

DR=0; DQ=0; DH=0
for pod in $(kubectl get pods -n "$NS" -l llm-d.ai/guide="$GUIDE" -o jsonpath='{.items[*].metadata.name}'); do
  m=$(kubectl get --raw "/api/v1/namespaces/$NS/pods/$pod:8000/proxy/metrics")
  r=$(awk '/^vllm:request_success_total/      {s+=$NF} END {print s+0}' <<<"$m")
  q=$(awk '/^vllm:prefix_cache_queries_total/ {s+=$NF} END {print s+0}' <<<"$m")
  h=$(awk '/^vllm:prefix_cache_hits_total/    {s+=$NF} END {print s+0}' <<<"$m")
  echo "$pod $r $q $h" >> "$NEW"
  read -r pr pq ph <<<"$(awk -v p="$pod" '$1==p {print $2, $3, $4}' "$STATE")"
  dr=$(( r - ${pr:-0} )); dq=$(( q - ${pq:-0} )); dh=$(( h - ${ph:-0} ))
  DR=$((DR+dr)); DQ=$((DQ+dq)); DH=$((DH+dh))
  [ "$1" != "reset" ] && printf "%-7s | %8d %10d %10d %6s\n" "${pod##*-}" "$dr" "$dq" "$dh" "$(pct "$dh" "$dq")"
done

if [ "$1" != "reset" ]; then
  line; printf "%-7s | %8d %10d %10d %6s\n" "TOTAL" "$DR" "$DQ" "$DH" "$(pct "$DH" "$DQ")"
  echo "(QUERIED / HIT = prompt tokens looked up in / found in the prefix cache)"
else
  echo "baseline saved"
fi
echo "#time $(date +%H:%M:%S)" >> "$NEW"
mv "$NEW" "$STATE"
