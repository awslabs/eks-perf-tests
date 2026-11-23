#!/bin/bash
# EndpointSlice controller test, Scale step (an Exec step of config.yaml): sets the label active=<true|false> on the
# "pc" pod of every test Service, 25 namespaces at a time, with kubectl label (a label-only patch, so the pod spec is
# never sent). First writes the half-wave's start time to <start file>, from which ep-wait.py times the half-wave.
# Every kubectl call has a 30 s request timeout on its API requests.
# Usage: ep-flip.sh <true|false> <namespace prefix> <start file>   env: KUBECONFIG
set -euo pipefail
V=${1:-}; PREFIX=${2:?namespace prefix}; START=${3:?start file}
case $V in
  true|false) ;;
  *) echo "usage: ep-flip.sh <true|false> <namespace prefix> <start file>" >&2; exit 2 ;;
esac
echo "$EPOCHREALTIME" > "$START"
kubectl get ns --request-timeout=30s --no-headers -o custom-columns=:metadata.name | grep -E "^$PREFIX-[0-9]+$" \
  | xargs -r -P 25 -I{} kubectl label pods --request-timeout=30s -n {} -l group=ep-test,role=pc active="$V" --overwrite -o name \
  | wc -l | xargs echo "pods labeled active=$V:"
