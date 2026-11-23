#!/usr/bin/env python3
"""EndpointSlice controller test, Reconcile step (an Exec step of config.yaml).

Waits until each test Service has exactly <ready per Service> ready endpoints, that is its pods with active=true,
summed over its EndpointSlices (they carry the Service's name in the kubernetes.io/service-name label, and the
controller copies the Service label group=ep-test to them). One list, then one watch from the list's
resourceVersion (kubectl get --raw), not repeated lists. Done once <services> Services have slices and
every one has the count. A watch that ends early (an error, a closed watch) is started again with a new list.

Times from <start file> (the half-wave's start, written by ep-flip.sh), or from its own start without one. Exits 1 if
that takes more than <limit> seconds, but only once done or after <timeout> seconds, so the next half-wave starts
reconciled; exits 0 when done within <limit>. The list has a 60 s request timeout; the watch ends at <timeout>.
Usage: ep-wait.py <services> <ready per Service> <limit seconds> <timeout seconds> [start file]   env: KUBECONFIG
"""
import json
import subprocess
import sys
import threading
import time
import urllib.parse

services, per = int(sys.argv[1]), int(sys.argv[2])
limit, timeout = float(sys.argv[3]), float(sys.argv[4])
start = time.time()
if len(sys.argv) > 5:
    try:
        start = float(open(sys.argv[5]).read())
    except (OSError, ValueError):
        pass
URL = "/apis/discovery.k8s.io/v1/endpointslices?labelSelector=" + urllib.parse.quote(
    "group=ep-test,endpointslice.kubernetes.io/managed-by=endpointslice-controller.k8s.io", safe="")
slices = {}  # slice namespace/name -> (Service namespace/name, ready endpoints)


def ready(o):
    return sum(1 for e in o.get("endpoints") or [] if (e.get("conditions") or {}).get("ready") is True)


def key(o):
    m = o.get("metadata") or {}
    return f"{m.get('namespace')}/{m.get('name')}"


def entry(o):
    m = o.get("metadata") or {}
    return f"{m.get('namespace')}/{(m.get('labels') or {}).get('kubernetes.io/service-name')}", ready(o)


def per_service():
    total = {}
    for svc, n in slices.values():
        total[svc] = total.get(svc, 0) + n
    return total


def done():
    total = per_service()
    return len(total) == services and all(n == per for n in total.values())


def finish(reached):
    e = time.time() - start
    good = sum(1 for n in per_service().values() if n == per)
    state = f"{good} of {services} Services with {per} ready endpoints ({len(slices)} slices) after {e:.1f}s"
    if reached and e <= limit:
        print(f"done: {state} (limit {limit:g}s)", flush=True)
        sys.exit(0)
    print(f"{'slow' if reached else 'timeout'}: {state}, limit {limit:g}s", flush=True)
    sys.exit(1)


while True:
    left = timeout - (time.time() - start)
    if left <= 0:
        finish(False)
    try:
        out = subprocess.run(["kubectl", "get", "--raw", URL, "--request-timeout=60s"], capture_output=True,
                             text=True, check=True, timeout=max(left, 1)).stdout
        lst = json.loads(out)
    except (subprocess.SubprocessError, ValueError) as err:
        print(f"list failed: {str(err)[:200]}", flush=True)
        time.sleep(1)
        continue
    slices = {key(o): entry(o) for o in lst.get("items") or []}
    if done():
        finish(True)
    rv = (lst.get("metadata") or {}).get("resourceVersion", "")
    left = timeout - (time.time() - start)
    # busybox timeout ends the watch at the deadline even if this script is killed first
    proc = subprocess.Popen(["timeout", str(int(max(left, 1)) + 1), "kubectl", "get", "--raw",
                             f"{URL}&watch=1&resourceVersion={rv}", "--request-timeout=0"],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    timer = threading.Timer(max(left, 0.1), proc.kill)
    timer.start()
    try:
        for line in proc.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                print(f"watch: {line.strip()[:200]}", flush=True)
                continue
            kind, o = ev.get("type"), ev.get("object") or {}
            if kind in ("ADDED", "MODIFIED"):
                slices[key(o)] = entry(o)
            elif kind == "DELETED":
                slices.pop(key(o), None)
            elif kind == "ERROR":
                print(f"watch error: {json.dumps(o)[:200]}", flush=True)
                break
            else:
                continue
            if done():
                finish(True)
    finally:
        timer.cancel()
        proc.kill()
        proc.wait()
    print(f"watch ended after {time.time() - start:.1f}s; listing again", flush=True)
    time.sleep(1)
