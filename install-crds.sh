#!/usr/bin/env bash
# Gateway API CRDs for the lab.
#
# Installs two bundles on purpose:
#
#   v1.5.0 experimental  — the current API. Ships ListenerSet as kind `ListenerSet`
#                          in group gateway.networking.k8s.io at v1.
#   v1.4.0 XListenerSet  — ONLY the xlistenersets CRD, kind `XListenerSet` in group
#                          gateway.networking.x-k8s.io at v1alpha1.
#
# Istio versions differ in which of those two kinds they watch, so installing both
# lets every revision under test see a ListenerSet kind it recognises. Installing
# the older CRD alongside the newer bundle is safe — they are distinct groups.
#
# --server-side is required: the HTTPRoute CRD exceeds the 262144-byte annotation
# limit that client-side apply's last-applied-configuration would impose.
set -euo pipefail
CTX="${CTX:-colima-istio-lab}"
CURRENT="${CURRENT:-v1.5.0}"
LEGACY_X="${LEGACY_X:-v1.4.0}"

echo "==> Gateway API $CURRENT (experimental channel)"
kubectl --context "$CTX" apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$CURRENT/experimental-install.yaml"

echo "==> XListenerSet CRD from $LEGACY_X"
tmp="$(mktemp -d)"
curl -sSL --max-time 120 \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/$LEGACY_X/experimental-install.yaml" \
  -o "$tmp/legacy.yaml"
python3 - "$tmp/legacy.yaml" "$tmp/xls.yaml" <<'PY'
import sys, pathlib
docs = pathlib.Path(sys.argv[1]).read_text().split("\n---\n")
hit = [d for d in docs if "name: xlistenersets.gateway.networking.x-k8s.io" in d]
if len(hit) != 1:
    raise SystemExit(f"expected exactly 1 xlistenersets CRD, found {len(hit)}")
pathlib.Path(sys.argv[2]).write_text(hit[0])
PY
kubectl --context "$CTX" apply --server-side -f "$tmp/xls.yaml"
rm -rf "$tmp"

echo
echo "==> ListenerSet kinds now available"
kubectl --context "$CTX" get crd -o custom-columns=NAME:.metadata.name,GROUP:.spec.group,KIND:.spec.names.kind \
  | grep -i listenerset || echo "  none"
