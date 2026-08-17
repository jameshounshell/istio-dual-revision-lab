#!/usr/bin/env bash
# Render and apply the route fixtures for a given revision pair.
#
#   ./apply-fixtures.sh 1-29 1-30
#
# The namespace tag and the Gateway are pinned to the NEW revision, so the
# starting state is "new control plane owns everything" — the state a rollout
# lands in just before the tag is repointed.
set -euo pipefail
CTX="${CTX:-colima-istio-lab}"
REV_OLD="${1:?old revision, e.g. 1-29}"
REV_NEW="${2:?new revision, e.g. 1-30}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

istioctl --context "$CTX" tag set ingressgw --revision "$REV_NEW" --overwrite -y >/dev/null
istioctl --context "$CTX" tag set stable    --revision "$REV_OLD" --overwrite -y >/dev/null

for f in "$HERE"/manifests/*.yaml; do
  sed -e "s/__REV_OLD__/$REV_OLD/g" -e "s/__REV_NEW__/$REV_NEW/g" "$f"
  echo "---"
done | kubectl --context "$CTX" apply -f -

kubectl --context "$CTX" -n gwtest wait --for=condition=Programmed gateway/gtw-lab --timeout=180s
