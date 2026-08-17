#!/usr/bin/env bash
# Two Gateways, one per revision, with each route initially attached to the
# Gateway of its own revision.
#
#   ./apply-twogw.sh 1-28 1-29
set -euo pipefail
CTX="${CTX:-colima-istio-lab}"
REV_OLD="${1:?old revision, e.g. 1-28}"
REV_NEW="${2:?new revision, e.g. 1-29}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

istioctl --context "$CTX" tag set ingressgw --revision "$REV_NEW" --overwrite -y >/dev/null
istioctl --context "$CTX" tag set stable    --revision "$REV_OLD" --overwrite -y >/dev/null

for f in "$HERE"/manifests-twogw/*.yaml; do
  sed -e "s/__REV_OLD__/$REV_OLD/g" -e "s/__REV_NEW__/$REV_NEW/g" "$f"
  echo "---"
done | kubectl --context "$CTX" apply -f -
