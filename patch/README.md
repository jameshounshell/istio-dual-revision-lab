# Parent-derived route status ownership

`parent-derived-route-ownership.patch` changes which control plane authors an
HTTPRoute's status: **the one that owns the route's parent Gateway**, instead of
whichever revision the route's own `istio.io/rev` label — or the label it inherits
from its namespace — happens to resolve to.

Applies to `HTTPRoute`, `GRPCRoute`, `TCPRoute` and `TLSRoute`.

## Why

Route ownership is currently computed on the wrong object. A route only means
anything in relation to the Gateway it attaches to, but ownership is read off the
route's own labels, so the two can disagree — and a staged revision-tag upgrade
makes them disagree on purpose, for its whole duration, because the ingress tag and
the application-namespace tags are flipped in separate steps.

While they disagree there are two failure modes, both observed in this lab:

- no control plane writes status at all (`status.parents=0` from creation, no edit
  to the route involved), or
- a control plane writes status for a Gateway it does not manage — including while
  that Gateway's own control plane is scaled to zero, so the status attests to
  programming that cannot have happened.

## What it does

Two changes:

1. `RouteContextInputs` gains the `Gateways` collection and the `TagWatcher`, plus
   `ownsRouteStatus`, which resolves each parent Gateway and asks whether this
   control plane owns it. A **mesh** parent has no Gateway to derive ownership
   from, so it keeps the existing rule and is claimed by the route's own revision.
2. The four route `RegisterStatus` call sites stop applying the per-object revision
   filter. `RegisterStatus` only sees the object's own `ObjectMeta`, which cannot
   express parent-derived ownership; the decision moves into the collection, which
   has the parents in scope. A non-owning revision returns a nil status there and
   never reaches the filter with anything to write.

**Config emission is deliberately untouched.** Only the status write is gated.
Dropping config from a non-owning revision removes xDS from pods still running on
that revision and caused an outage — see istio/istio#59959 and the comment at
`gateway_collection.go` explaining why filtering was removed from that layer.

## Result

Same manifests, same tags, stock 1.28.3 owning the route's namespace both times.
Only the Gateway's control plane differs:

| Gateway's control plane | Route status |
|---|---|
| stock istio 1.29.5 | `status.parents=0` |
| patched istio 1.29.5 | `status.parents=1` `Accepted=True` `ResolvedRefs=True` |

And the gate is real rather than an unconditional write — with the Gateway owned by
1.28.3 and the route's namespace resolving to the patched revision, the patched
control plane **declines** (`status.parents=0`), because it does not own the parent.

## Building it

```bash
git clone https://github.com/istio/istio && cd istio && git checkout 1.29.5
git apply /path/to/parent-derived-route-ownership.patch
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o pilot-discovery ./pilot/cmd/pilot-discovery
printf 'FROM docker.io/istio/pilot:1.29.5\nCOPY pilot-discovery /usr/local/bin/pilot-discovery\n' > Dockerfile
docker build -t istio-lab/pilot:1.29.5-parentowned .
```

Then install that revision with `--set pilot.hub=istio-lab --set
pilot.tag=1.29.5-parentowned --set global.imagePullPolicy=Never`.

## Caveat on the base

The patch was generated against a working tree carrying one extra local commit on
top of `1.29.5` (an unrelated `PILOT_GATEWAY_API_ROUTE_REVISION` experiment). The
only consequence is at the four `RegisterStatus` call sites: this patch replaces
`c.routeTagWatcher()`, whereas stock `1.29.5` reads
`c.tagWatcher.AccessUnprotected()` at those lines. Adjust those four hunks when
applying to a clean checkout — the substance of the change is unaffected.

Not upstreamed, not run against istio's own test suite. It is a demonstration that
parent-derived ownership removes the failure, not a production patch.
