# Findings

Each section answers one of the questions in [QUESTIONS.md](QUESTIONS.md). Setup is
Gateway API v1.5.0 on k3s v1.35.0, single node, istiod installed per revision via
Helm. Two pairs are used throughout:

- **1.28.3 + 1.29.5** — versions that behave differently from each other
- **1.29.5 + 1.30.3** — versions that behave the same

---

## Q1 — Is there a breakdown when the Gateway resolves through one tag and the route's namespace through another?

**Yes on 1.28/1.29. No on 1.29/1.30.** This is the central result.

Gateway labelled with an ingress tag, route unlabelled in a namespace carrying a
different tag, the two tags pointing at different revisions:

| Tags | Route status |
|---|---|
| gateway `ingressgw`→1-29, namespace `stable`→1-28 | **`parents=0`** |
| gateway `ingressgw`→1-30, namespace `stable`→1-29 | `parents=1` Accepted |

Identical manifests both times; only the revision pair changed.

**No mutation is required.** The route never receives status from the moment it is
created. Earlier sections of this lab framed the failure as write-triggered; that
framing was an artifact of pinning Gateways to literal revisions, which is not how
a real deployment is labelled.

This is the shape a staged rollout manufactures on purpose. Flipping the ingress
tag to the new revision while application namespaces still carry the old one leaves
every route in those namespaces orphaned for the entire window between the two
steps — days or weeks, not an instant.

Reproduce: `manifests-tagged-gw/`.

## Q2 — Do edits to an HTTPRoute take effect while two revisions run, including moving it to a different Gateway?

**Edits apply normally when the route's owner can claim its parent.** Hostname
changes and parentRef changes both advance `observedGeneration` in step with
`generation` on both pairs, whenever route and Gateway resolve to the same revision.

**Moving a route across the revision boundary is direction-dependent:**

| Move | 1.28.3 + 1.29.5 | 1.29.5 + 1.30.3 |
|---|---|---|
| old-revision route → newer revision's Gateway | **`parents=0`** — existing entry removed, none written | Accepted, `obsGen` current |
| new-revision route → older revision's Gateway | Accepted, `obsGen` current | Accepted, `obsGen` current |

It is reversible: moving the route back to a Gateway its own revision owns restores
`Accepted=True`.

**The two control planes never contend.** `watch-churn.sh` recorded zero status
rewrites over 40–60s windows in every configuration, including the broken ones. A
fight would appear as repeated rewrites; the actual failure is silence — both
control planes decline.

Reproduce: `apply-twogw.sh`, `cross-twogw.sh`.

## Q3 — Who writes status to an HTTPRoute?

**The route's owner. The Gateway's owner is irrelevant.**

Ownership of a route is resolved from its own `istio.io/rev` label, falling back to
its namespace's. Nothing consults the parent Gateway.

Proven by scaling each control plane to zero, with the route resolving to 1-29 and
the Gateway to 1-30:

| istiod-1-29 (route's owner) | istiod-1-30 (Gateway's owner) | Result |
|---|---|---|
| **scaled to 0** | running | `parents=0` |
| running | **scaled to 0** | `parents=1` Accepted |

In the second row a control plane stamped `Accepted=True ResolvedRefs=True` on a
route whose parent Gateway is managed by a control plane that was not running. The
status attests to programming the writer cannot perform and cannot verify.

**And the status is not merely unverifiable — it is false.** Checking the data plane
rather than stopping at the status field: for a route the non-owning revision had
marked `Accepted=True`, `istioctl proxy-config routes` against
the Gateway's actual proxy shows the route absent, and a live request returns a 404
blackhole. The route reports healthy and does not serve traffic.

**Tag resolution is asymmetric.** A tag in the route's *own* label does not resolve
— it is matched as a literal revision name, finds nothing, and the route is never
claimed (`parents=0` on every pair tested, not version-dependent). A tag inherited
from the *namespace* does resolve.

## Q4 — Does ListenerSet behave correctly where HTTPRoute does not?

**No.**

The original test compared a ListenerSet and an HTTPRoute across a 1.29/1.30 split
and found the ListenerSet `Pending` while the route was `Accepted`. That difference
was not about ownership.

**Why 1.29.5 never touched it.** Not for lack of support — istiod 1.29.5 has
`supportsListenerSet: true` on the istio GatewayClass and a complete
`ListenerSetCollection`: `supportsListenerSet: true` on the istio GatewayClass
(`pilot/pkg/config/kube/gateway/deploymentcontroller.go`) and a complete
`ListenerSetCollection`. What it watches is the **experimental** kind:

```go
gatewayx "sigs.k8s.io/gateway-api/apisx/v1alpha1"   // XListenerSet, gateway.networking.x-k8s.io
```

Gateway API v1.5.0 ships the graduated `ListenerSet` in
`gateway.networking.k8s.io/v1` and does not install the `x-k8s.io` kind at all — a
v1.5.0 cluster has only `xbackendtrafficpolicies` and `xmeshes` in that group. So
1.29.5 was watching a kind absent from the cluster and never observed the object.
1.30.3 reconciles the graduated kind.

This is an Istio-vs-Gateway-API version skew, not missing functionality — **verified,
not inferred.** Installing the `xlistenersets.gateway.networking.x-k8s.io` CRD from
the Gateway API v1.4.0 experimental bundle alongside v1.5.0, with
`PILOT_ENABLE_ALPHA_GATEWAY_API=true` and an istiod restart so the informer picks up
a CRD that did not exist at startup:

| | |
|---|---|
| `XListenerSet` on stock istio 1.29.5 | `Accepted=True` `Programmed=True` |
| parent Gateway | `AttachedListenerSets=True` |

**So ListenerSet works on 1.29.5 and on 1.30.3 — they just speak different kinds.**
1.29.5 handles the experimental `XListenerSet`
(`gateway.networking.x-k8s.io/v1alpha1`), which the flag gates:

```go
if features.EnableAlphaGatewayAPI {
    inputs.ListenerSets = buildClient[*gatewayx.XListenerSet](c, kc, gvr.XListenerSet, ...)
} else {
    inputs.ListenerSets = krt.NewStaticCollection[*gatewayx.XListenerSet](nil, ...)  // always empty
}
```

1.30.3 handles the graduated `ListenerSet` (`gateway.networking.k8s.io/v1`) with the
flag unset. The env var and the CRD are a pair: neither alone is sufficient on 1.29.5
against a v1.5.0 bundle, because the flag builds an informer for a kind v1.5.0 does
not install.

Re-run with **two revisions of the same version (both 1.30.3)**, so capability is
constant and only ownership differs — Gateway resolving to one revision, namespace
to the other:

| Resource | Status |
|---|---|
| HTTPRoute | `Accepted=True` |
| ListenerSet | `Accepted=True` `Programmed=True` |

Identical behaviour. The source agrees: `gateway_collection.go` carries an explicit
comment that `tagWatcher.IsMine()` is *not* filtered at the collection layer for
ListenerSets either, and both resources are filtered by `IsMine` on their own
`ObjectMeta` in `RegisterStatus`.

### Which version supports which ListenerSet kind

Two distinct kinds exist and versions differ in which they watch:

| Revision | graduated `ListenerSet` (`gateway.networking.k8s.io/v1`) | experimental `XListenerSet` (`gateway.networking.x-k8s.io/v1alpha1`) |
|---|---|---|
| 1.28.3 | no informer built; stays `Pending` | **works** |
| 1.29.5 | no informer built; stays `Pending` | **works** |
| 1.30.3 | **works** — `Accepted=True reason=Accepted` | **works** |

`XListenerSet` requires `PILOT_ENABLE_ALPHA_GATEWAY_API=true` *and* the
`xlistenersets.gateway.networking.x-k8s.io` CRD, which the Gateway API v1.5.0 bundle
does not install — take it from the v1.4.0 or v1.3.0 experimental bundle (v1.2.1 does
not have it). The flag literally constructs the informer; without it the collection is
built empty. istiod must be **restarted** after installing a CRD that did not exist at
startup. `install-crds.sh` installs both kinds so every revision under test can see one
it recognises.

⚠️ On a single-node cluster a ListenerSet frequently reports `Programmed=False /
AddressNotAssigned`. That is the load-balancer artifact inherited from its parent
Gateway — the Gateway carries the identical condition — not a reconciliation failure.
`Accepted` is the condition that answers whether a controller acted on the object.

Ownership of an `XListenerSet` follows the resource's own resolved revision and does
**not** reproduce the 1.28-specific fail-closed behaviour seen for HTTPRoute in Q1.

ListenerSet has the same flaw. There is no in-tree model of parent-derived
ownership to copy — see Q6.

## Q5 — Can writes be attributed to a specific control plane?

**Yes — `PILOT_GATEWAY_API_CONTROLLER_NAME` per revision does it, at a cost.**

By default every revision publishes under `controllerName:
istio.io/gateway-controller`, so a status entry does not identify its author, and the
Q3 attribution had to come from scaling control planes to zero.

Giving each istiod a distinct `PILOT_GATEWAY_API_CONTROLLER_NAME` makes
`status.parents[].controllerName` name the author literally. Three side effects, all
confirmed:

- it requires a **dedicated GatewayClass per revision** matching that controller name;
- any Gateway left on the shared `istio` GatewayClass is then **silently orphaned** —
  no controller claims it;
- it does **not** bypass the revision-label ownership gate, which still applies on top.

⚠️ A Gateway left on the shared `istio` GatewayClass after this change reports
`Accepted=Unknown` and looks like the mechanism failing. It is the orphaning side
effect above; move the Gateway to the per-revision class.

Scale-to-zero remains the lower-blast-radius method for a one-off question, since it
changes no ownership model.

---

## Q6 — Does deriving ownership from the parent Gateway fix it?

**Yes.** Implemented and proven: `patch/`.

The change makes the control plane that owns a route's **parent Gateway** author the
route's status, instead of whichever revision the route's own or inherited
`istio.io/rev` resolves to. Applies to HTTPRoute, GRPCRoute, TCPRoute and TLSRoute.
Mesh parents keep the existing rule. Only the status write is gated; config emission
is untouched, because dropping config from a non-owning revision caused
istio/istio#59959.

Same manifests, same tags, stock 1.28.3 owning the route's namespace in both runs —
only the Gateway's control plane differs:

| Gateway's control plane | Route status |
|---|---|
| stock istio 1.29.5 | `status.parents=0` |
| patched istio 1.29.5 | `status.parents=1` `Accepted=True` `ResolvedRefs=True` |

Ownership now comes from exactly one place. Three cases, patched build owning the
Gateway or not:

| Route's label | Namespace resolves to | Gateway owned by | Result |
|---|---|---|---|
| none | 1.28.3 | patched | `Accepted=True` — namespace ignored |
| none | patched | 1.28.3 (stock) | `parents=0` — declines, does not own the parent |

The second row matters: the gate is genuine, not an unconditional write. A mesh
parent has no Gateway to derive ownership from and keeps the previous rule.

### Scope boundary — the patch cannot help a literally-labelled route

A route carrying a literal `istio.io/rev` label for a *different* revision is not
helped by the patch, via a mechanism upstream of anything the patch touches. All
Gateway API child resources except Gateway itself are filtered by revision at the raw
informer level (`controller.go` → `config.LabelsInRevision`, `pkg/config/model.go`):

```go
func LabelsInRevision(lbls map[string]string, rev string) bool {
	configEnv, f := lbls[label.IoIstioRev.Name]
	if !f { return true }          // unlabelled -> visible to every revision
	if rev == "" { return true }
	return configEnv == rev        // LITERAL compare only, never resolves tags
}
```

So a route labelled with a literal revision other than a given pilot's is **invisible to
that pilot entirely** — no config, no status — before the patch's logic can run. Verified:
such a route attached to the patched revision's Gateway stays `{"parents": []}`.

**The patch therefore closes the subset of the failure reachable by informer-visible
routes** — unlabelled/namespace-inherited ones, which is what real upgrades use — and
provides nothing for routes carrying a literal label for another revision. Closing that
case too would require touching the informer filter, which is deliberately out of the
patch's scope.

Not upstreamed and not run against istio's test suite — a demonstration that the
ownership model is the cause, not a production patch.

## Implication

Route ownership is computed on the wrong object. A route is meaningful only in
relation to the Gateway it attaches to, but ownership is derived from the route's
own labels, so the two can disagree — and when they do, either nobody writes
(1.28-era) or the wrong control plane writes (1.29+), including for a Gateway whose
control plane is absent.

Deriving ownership from the parent Gateway makes both tag paths irrelevant and
removes the disagreement by construction. No resource in the tree does this today —
ListenerSet has the same flaw (Q4) — so it has to be written rather than copied.
Q6 does exactly that and shows the failure disappears.

## Caveats

Single node, no traffic, no long-duration soak. Differences between pairs are **not
attributed to a specific upstream change** — both 1.29 and 1.30 carry backports 1.28
does not, and this setup cannot isolate which. A `1.28.3 + 1.30.3` pair would
discriminate.

A second Gateway in one namespace may report `Programmed=False /
AddressNotAssigned` where the load balancer cannot assign two services the same node
port (k3s/klipper contends on status port 15021). Pods are healthy and route
attachment is unaffected; `Accepted` is the condition that matters above.
