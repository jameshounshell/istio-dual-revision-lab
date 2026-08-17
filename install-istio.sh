#!/usr/bin/env bash
# Install two coexisting istiod revisions into the local colima/k3s lab.
#
#   ./install-istio.sh 1.28.3 1.29.5      # a pair whose versions disagree
#   ./install-istio.sh 1.29.5 1.30.3      # a pair whose versions agree
#
# base (CRDs) is installed at the NEWER version, mirroring how a real upgrade
# stages CRDs ahead of the new control plane.
set -euo pipefail

CTX="${CTX:-colima-istio-lab}"
OLD="${1:?old istio version, e.g. 1.28.3}"
NEW="${2:?new istio version, e.g. 1.29.5}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1.28.3 -> 1-28
rev() { echo "$1" | cut -d. -f1,2 | tr '.' '-'; }
REV_OLD="$(rev "$OLD")"
REV_NEW="$(rev "$NEW")"

echo "==> context=$CTX  old=$OLD (rev $REV_OLD)  new=$NEW (rev $REV_NEW)"

helm --kube-context "$CTX" upgrade --install istio-base istio/base \
  -n istio-system --create-namespace --version "$NEW" \
  --set defaultRevision="$REV_NEW" --wait

for pair in "$OLD:$REV_OLD" "$NEW:$REV_NEW"; do
  ver="${pair%%:*}"; r="${pair##*:}"
  echo "==> istiod-$r ($ver)"
  helm --kube-context "$CTX" upgrade --install "istiod-$r" istio/istiod \
    -n istio-system --version "$ver" \
    -f "$HERE/values/istiod-common.yaml" \
    -f "$HERE/values/istiod-alpha-gwapi.yaml" \
    --set revision="$r" --wait
done

kubectl --context "$CTX" -n istio-system get deploy
echo
echo "==> GatewayClasses (both revisions reconcile these)"
kubectl --context "$CTX" get gatewayclass
