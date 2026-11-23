#!/bin/bash
# Namespace controller test, delete step (the Exec step of config.yaml): deletes every test namespace <prefix>-<n> at
# once, <clients> kubectl processes in parallel (each with an equal share of the names), then waits until all are gone,
# listing them about once a second. Exits 1 if that takes more than <limit> seconds from the first delete, but only
# once all are gone or <timeout> seconds have passed; exits 0 when all are gone within <limit>. A failed delete call does
# not stop the wait (the namespaces it missed then count as left). Every kubectl call has a 30 s request timeout on
# its API requests.
# Usage: ns-delete.sh <prefix> <clients> <limit seconds> <timeout seconds>   env: KUBECONFIG
set -euo pipefail
PREFIX=${1:?namespace prefix}; CLIENTS=${2:?clients}; LIMIT=${3:?limit seconds}; TIMEOUT=${4:?timeout seconds}
[[ $PREFIX =~ ^[a-z0-9-]+$ && $CLIENTS =~ ^[1-9][0-9]*$ && $LIMIT =~ ^[0-9]+([.][0-9]+)?$ && $TIMEOUT =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || { echo "usage: ns-delete.sh <prefix> <clients >= 1> <limit seconds> <timeout seconds>" >&2; exit 2; }
names() { kubectl get ns --request-timeout=30s --no-headers -o custom-columns=:metadata.name | { grep -E "^$PREFIX-[0-9]+$" || true; }; }
elapsed() { awk -v s="$start" -v n="$EPOCHREALTIME" 'BEGIN {printf "%.1f", n - s}'; }
over() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a > b)}'; }
for try in 1 2 3 4 5; do
  all=$(names) && break
  [ "$try" -lt 5 ] || exit 1
  sleep 2
done
total=$(echo "$all" | grep -c . || true)
[ "$total" -gt 0 ] || { echo "no $PREFIX-<n> namespaces to delete"; exit 1; }
start=$EPOCHREALTIME
# <clients> kubectl processes, each deleting an equal share of the names (busybox xargs: -n and -P, no -L)
echo "$all" | xargs -r -n $(( (total + CLIENTS - 1) / CLIENTS )) -P "$CLIENTS" kubectl delete ns --request-timeout=30s --wait=false > /dev/null \
  || echo "warning: a delete call failed; waiting for the namespaces anyway"
echo "delete sent for $total namespaces after $(elapsed)s"
while true; do
  # A failed list (for example a timeout) is retried on the next poll.
  if left=$(names); then
    left=$(echo "$left" | grep -c . || true)
    e=$(elapsed)
    if [ "$left" -eq 0 ]; then
      rate=$(awk -v n="$total" -v e="$e" 'BEGIN {printf "%.2f", n / e}')
      if over "$e" "$LIMIT"; then
        echo "slow: $total namespaces gone after ${e}s ($rate per second), limit ${LIMIT}s"
        exit 1
      fi
      echo "done: $total namespaces gone after ${e}s ($rate per second, limit ${LIMIT}s)"
      exit 0
    fi
    if over "$e" "$TIMEOUT"; then
      echo "timeout: $left of $total namespaces left after ${e}s"
      exit 1
    fi
  fi
  sleep 1
done
