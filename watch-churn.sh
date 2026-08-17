#!/usr/bin/env bash
# Detect two control planes fighting over one route's status.
#
# Both istiods use controllerName istio.io/gateway-controller, and pruning is
# per-controller-name — so neither can tell the other's entries from its own.
# If they disagree about a route, the symptom is the status object being
# rewritten repeatedly. Samples resourceVersion, which changes on every write.
set -euo pipefail
CTX="${CTX:-colima-istio-lab}"
NS="${NS:-gwtest}"
ROUTE="${1:?route name}"
SECS="${2:-60}"

prev=""; writes=0
end=$((SECONDS + SECS))
while [ $SECONDS -lt $end ]; do
  cur=$(kubectl --context "$CTX" -n "$NS" get httproute "$ROUTE" \
        -o jsonpath='{.metadata.resourceVersion}|{range .status.parents[*]}{.parentRef.name}:{range .conditions[*]}{.type}={.status},{end};{end}' 2>/dev/null || true)
  if [ "$cur" != "$prev" ]; then
    [ -n "$prev" ] && writes=$((writes + 1))
    printf '%3ds  %s\n' "$SECONDS" "$cur"
    prev="$cur"
  fi
  sleep 2
done
echo "observed $writes change(s) over ${SECS}s"
