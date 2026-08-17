# istio-dual-revision-lab

How Istio assigns Gateway API route status when **two istiod revisions run side by
side**, as they do for the duration of a revision-tag upgrade.

**Start with [QUESTIONS.md](QUESTIONS.md)** — it states the questions this lab
exists to answer and which are still open. [FINDINGS.md](FINDINGS.md) answers them
with evidence. Everything below is how to reproduce it.

The headline: when the Gateway resolves through one revision tag and a route's
namespace resolves through another — the state a staged rollout creates on purpose —
routes can silently receive no status at all, with no edit to the route involved.
Whether that happens depends on which versions are in the split. Because
`status.parents` is what controllers such as external-dns consume, an empty entry
has consequences beyond cosmetics.

## Requirements

- `kubectl`, `helm`, `istioctl`
- A Kubernetes cluster you can install two istiod revisions into
- `helm repo add istio https://istio-release.storage.googleapis.com/charts`

Any cluster works. The scripts default to a kube context named
`colima-istio-lab`; override with `CTX=<your-context>`.

<details>
<summary>Creating a throwaway cluster with colima</summary>

```bash
colima start istio-lab --kubernetes --cpu 6 --memory 8 --disk 60 \
  --vm-type vz --arch aarch64
```

Gives context `colima-istio-lab` on k3s with traefik disabled. Use `--arch x86_64`
on an Intel host, or drop the arch/vm-type flags entirely and let colima pick.

Do not pass `--network-address` — reachable-IP assignment is unreliable on the
`vz` backend, and nothing here needs it. Route status is written by the control
plane and requires no data-plane reachability at all.

Teardown: `colima delete istio-lab`.

</details>

## Gateway API CRDs

```bash
./install-crds.sh
```

Installs two bundles deliberately. **Gateway API v1.5.0** for the current API, whose
ListenerSet is kind `ListenerSet` in group `gateway.networking.k8s.io` at `v1` (it
ships in the standard channel too). And the single `xlistenersets` CRD from **v1.4.0**,
kind `XListenerSet` in `gateway.networking.x-k8s.io/v1alpha1` — the older kind, which
some Istio versions are the only thing they watch. Distinct groups, so they coexist.

`--server-side` is used throughout: the HTTPRoute CRD exceeds the 262144-byte
annotation limit that client-side apply's `last-applied-configuration` would impose.

istiod must be **restarted** after a CRD is installed that did not exist when it
started — informers are built at startup.

## Running it

Install two revisions:

```bash
./install-istio.sh 1.28.3 1.29.5     # a pair whose versions disagree
./install-istio.sh 1.29.5 1.30.3     # a pair whose versions agree
```

`install-istio.sh` installs `istio/base` at the newer version and one `istiod` per
revision, with `PILOT_ENABLE_ALPHA_GATEWAY_API=true` on every revision so any version
that gates ListenerSet behind it can see one. `values/istiod-common.yaml` trims istiod's requests from the chart
default of 500m/2Gi so several revisions fit one node — lab sizing, not a
recommendation.

### Tagged Gateway vs differently-tagged namespace — Q1, start here

Both sides resolve through tags, which is how a real deployment is labelled. Point
the two tags at different revisions and the route is orphaned from creation, with
no edit to it at any point.

```bash
istioctl tag set ingressgw --revision 1-29 --overwrite -y   # Gateway's tag
istioctl tag set stable    --revision 1-28 --overwrite -y   # namespace's tag
kubectl apply -f manifests-tagged-gw/
./observe-twogw.sh          # -> status.parents=0
```

Repeat with the tags on `1-30` and `1-29` and the same route is Accepted. Only the
revision pair changed.

To confirm which control plane authors the status, scale each to zero in turn and
recreate the route — the route's owner is the one whose absence stops the write,
and the Gateway's owner can be absent entirely without affecting it.

### One Gateway

```bash
./apply-fixtures.sh 1-28 1-29   # revisions, not versions
./observe.sh
```

Four routes, identical but for their `istio.io/rev` label, all attached to one
Gateway owned by the newer revision:

| Route | Label |
|---|---|
| `route-lit-<old>` | literal old revision — differs from the Gateway's |
| `route-lit-<new>` | literal new revision — matches the Gateway's |
| `route-inherit` | none, so it inherits the namespace's label, which is a **tag** |
| `route-tag` | a **tag** rather than a literal revision |

Each is written once and never edited. Route ownership is re-evaluated only on a
route object event, so editing a route to change its label would conflate "which
revision owns it" with "did a write force re-evaluation".

To reproduce the staleness case, repoint a tag without touching any route, then
force an object event:

```bash
istioctl tag set ingressgw --revision 1-28 --overwrite -y
./observe.sh                                    # compare against the previous output
kubectl -n gwtest annotate httproute route-inherit poke="$(date +%s)" --overwrite
./observe.sh                                    # compare again
```

### Two Gateways

```bash
./apply-twogw.sh 1-28 1-29
./observe-twogw.sh          # aligned: each route on its own revision's Gateway
./cross-twogw.sh            # move every route to the other revision's Gateway
./observe-twogw.sh
```

`observe-twogw.sh` prints `gen` against `obsGen`, which is the load-bearing pair:
a status entry can read `Accepted=True` while its `observedGeneration` lags the
spec, meaning it describes an older version of the route than the one applied.

`watch-churn.sh <route> [seconds]` samples `resourceVersion` to detect two control
planes rewriting one route's status. Both istiods use controllerName
`istio.io/gateway-controller` and pruning is per-controller-name, so neither can
distinguish the other's entries from its own.

### ListenerSet

```bash
kubectl apply -f manifests-listenerset/
```

The parent Gateway must opt in via `spec.allowedListeners` before a ListenerSet
may attach.

## Layout

| Path | |
|---|---|
| `QUESTIONS.md` | the questions this lab answers, and the open ones |
| `install-istio.sh` | two istiod revisions via Helm |
| `manifests-tagged-gw/` | **Q1** — tagged Gateway vs differently-tagged namespace |
| `apply-fixtures.sh` / `manifests/` | one-Gateway route matrix |
| `apply-twogw.sh` / `cross-twogw.sh` / `manifests-twogw/` | two-Gateway matrix |
| `observe.sh` / `observe-twogw.sh` | route ownership dumps |
| `watch-churn.sh` | status-rewrite detector |
| `manifests-listenerset/` | ListenerSet case |
| `install-crds.sh` | both Gateway API ListenerSet kinds |
| `patch/` | **Q6** — parent-derived ownership fix, and proof it works |
