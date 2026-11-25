#!/bin/bash
# DaemonSet controller test: sets the group labels on the KWOK fake nodes (run by the Exec steps of config.yaml).
# Group k (k = 0..groups-1) runs on kwok-node-(k%N+1) and kwok-node-((k+1)%N+1) at base; an up wave adds
# kwok-node-((k+2)%N+1) and a down wave removes it again. With 100 groups on N = 100 nodes every node gets one
# label patch per wave. base first removes any group label (kcm-ds-g<number>) left by an earlier run; clear only
# removes them. Every kubectl call has a 30 s request timeout on its API requests.
# Usage: ds-nodes.sh <base|up|down|clear> [groups] [nodes]   env: KUBECONFIG
set -euo pipefail
OP=${1:-}; G=${2:-100}; N=${3:-100}
case $OP in
  base|up|down|clear) ;;
  *) echo "usage: ds-nodes.sh <base|up|down|clear> [groups] [nodes]" >&2; exit 2 ;;
esac
# Fewer than 3 nodes: the up node of a group would be one of its base nodes, and an up wave would add no pod.
[[ $G =~ ^[0-9]+$ && $N =~ ^[0-9]+$ && $G -ge 1 && $N -ge 3 ]] || { echo "need at least 1 group and 3 nodes" >&2; exit 2; }
# Reads "<node> <label args>" lines and runs one kubectl label per line, all at once (one process each, no cap, so
# a half-wave is a burst of node updates as it can be in a real cluster). Fails if any of them fails.
label() {
  local line p rc=0 pids=()
  while read -r line; do
    # shellcheck disable=SC2086 # the line is "<node> <label args>", one word each
    kubectl label node --request-timeout=30s --overwrite -o name $line &
    pids+=($!)
  done
  for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || rc=1; done
  return "$rc"
}
node() { echo "kwok-node-$(( $1 % N + 1 ))"; }
if [ "$OP" = clear ] || [ "$OP" = base ]; then
  kubectl get nodes --request-timeout=30s -l type=kwok -o json \
    | jq -r '.items[] | [.metadata.name] + [.metadata.labels | keys[] | select(test("^kcm-ds-g[0-9]+$")) | . + "-"]
             | select(length > 1) | join(" ")' \
    | label | wc -l | xargs echo "nodes cleared:"
fi
if [ "$OP" != clear ]; then
  for ((k = 0; k < G; k++)); do
    case $OP in
      base) echo "$(node "$k") kcm-ds-g$k=on"; echo "$(node $((k + 1))) kcm-ds-g$k=on" ;;
      up) echo "$(node $((k + 2))) kcm-ds-g$k=on" ;;
      down) echo "$(node $((k + 2))) kcm-ds-g$k-" ;;
    esac
  done | awk '{a[$1] = a[$1] " " $2} END {for (n in a) print n a[n]}' | label | wc -l | xargs echo "nodes labeled ($OP):"
fi
