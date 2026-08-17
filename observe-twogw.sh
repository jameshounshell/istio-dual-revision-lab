#!/usr/bin/env bash
# Route ownership across two Gateways owned by different revisions.
#
# generation vs observedGeneration is the load-bearing pair: a status entry can
# be Accepted=True while its observedGeneration lags the spec, meaning it
# describes an older version of the route than the one currently applied.
set -euo pipefail
CTX="${CTX:-colima-istio-lab}"
NS="${NS:-gwtest}"

kubectl --context "$CTX" -n "$NS" get httproute -o json | jq -r '
.items[] |
"  \(.metadata.name)  label=\(.metadata.labels["istio.io/rev"] // "<none>")  gen=\(.metadata.generation)" +
"  spec.parents=[\((.spec.parentRefs//[]) | map(.name) | join(","))]" +
"  status.parents=\((.status.parents//[])|length)",
((.status.parents//[])[] |
  "      -> parent=\(.parentRef.name)  " +
  ((.conditions//[]) | map("\(.type)=\(.status)") | join(" ")) +
  "  obsGen=\(((.conditions//[])[0].observedGeneration) // "-")" +
  "  since=\(((.conditions//[])[0].lastTransitionTime) // "-")")'
