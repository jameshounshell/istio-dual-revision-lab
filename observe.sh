#!/usr/bin/env bash
# Dump HTTPRoute ownership state. Run before and after a change and diff the two
# outputs — status.parents is the field under test, and a populated one is not
# proof of current ownership, so lastTransitionTime is printed alongside it.
set -euo pipefail
CTX="${CTX:-colima-istio-lab}"
NS="${NS:-gwtest}"

echo "# tags"
istioctl --context "$CTX" tag list 2>/dev/null | sed 's/^/  /'

echo "# routes"
kubectl --context "$CTX" -n "$NS" get httproute -o json | jq -r '
.items[] |
"  \(.metadata.name)  label=\(.metadata.labels["istio.io/rev"] // "<none>")  parents=\((.status.parents//[])|length)",
((.status.parents//[])[] |
  "      controller=\(.controllerName)  " +
  ((.conditions//[]) | map("\(.type)=\(.status)") | join(" ")) +
  "  since=\(((.conditions//[])[0].lastTransitionTime) // "-")")'
