#!/usr/bin/env bash
# Swap every route onto the OTHER revision's Gateway, so route ownership and
# Gateway ownership disagree as the result of an edit rather than at creation.
set -euo pipefail
CTX="${CTX:-colima-istio-lab}"
NS="${NS:-gwtest}"

patch() {
  kubectl --context "$CTX" -n "$NS" patch httproute "$1" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/parentRefs/0/name\",\"value\":\"$2\"}]" >/dev/null
  echo "  $1 -> $2"
}

patch r-old  gtw-new
patch r-new  gtw-old
patch r-none gtw-new
