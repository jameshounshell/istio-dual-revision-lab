# Questions this lab exists to answer

These are the north star. Anything not serving one of them is out of scope, and
anything added later should be attached to a question here or to a new one.

Answers and evidence: [FINDINGS.md](FINDINGS.md). Reproduction: [README.md](README.md).

---

### Q1 — Is there a breakdown when the Gateway resolves through one revision tag and the HTTPRoute's namespace resolves through a different one?

The central question. This is how a real deployment is labelled — the Gateway
carries an ingress tag, application namespaces carry their own — and a staged
upgrade flips those tags at different times, so they point at different revisions
for the duration of the rollout.

**Answered: yes on 1.28/1.29, no on 1.29/1.30, and no route mutation is required.**

### Q2 — While two revisions run, do edits to an HTTPRoute take effect, including changing which Gateway it attaches to?

Covers both ordinary spec edits and reparenting across the revision boundary, and
whether two control planes fight over a route whose parent changed.

**Answered: edits apply when route and Gateway agree; reparenting across the
boundary is direction-dependent on 1.28/1.29; the control planes never contend.**

### Q3 — Which control plane writes status to an HTTPRoute?

**Answered: the route's owner, resolved from the route's label or its namespace.
The Gateway's owner is irrelevant — it will write even for a Gateway whose control
plane is not running. That status is not merely unverifiable but FALSE: the route is
absent from the Gateway's proxy and requests to it 404.**

### Q4 — Does ListenerSet behave correctly where HTTPRoute does not?

**Answered: no.** With
capability held constant (two revisions of the same version), ListenerSet behaves
exactly like HTTPRoute. The earlier contrary result came from istiod 1.29.5 watching
the experimental `XListenerSet` kind (`gateway.networking.x-k8s.io`) while Gateway
API v1.5.0 ships the graduated `ListenerSet` (`gateway.networking.k8s.io/v1`) — a
version skew, not the absence of support, and nothing to do with ownership.
Confirmed by installing the `XListenerSet` CRD from the v1.4.0 experimental bundle:
1.29.5 then reconciles it `Accepted=True` `Programmed=True`.

### Q5 — Can a status write be attributed to a specific control plane?

**Answered: yes — a distinct `PILOT_GATEWAY_API_CONTROLLER_NAME` per revision makes
`controllerName` name the author.** It needs a dedicated GatewayClass per revision,
silently orphans any Gateway left on the shared one, and does not bypass the
revision-label ownership gate.

---

### Q6 — Does deriving ownership from the parent Gateway fix it?

**Answered: yes.** Implemented against istio 1.29.5 and proven in `patch/` — the
control plane owning the parent Gateway authors the route's status. In the topology
that produces `status.parents=0` on stock, the patched build produces
`Accepted=True`, and it still declines routes whose parent it does not own.
**Scope limit:** routes carrying a literal `istio.io/rev` label for another revision
are filtered out at the informer level before the patch's logic runs, so it cannot
help those — only informer-visible (unlabelled / namespace-inherited) routes, which
is what real upgrades use.

---

## Open

### Q7 — Does a `1.28.3 + 1.30.3` pair isolate which upstream change fixed this?

Both 1.29 and 1.30 carry backports 1.28 does not, so the pairs used so far cannot
tell which change is responsible. A pair where only one side carries a given fix
would discriminate. Relevant if the attribution matters to an upstream discussion.

### Q8 — Does an istiod restart or informer resync re-evaluate existing routes?

Whether status can collapse with nothing writing to the route — a tag flip followed
by a control-plane restart, no route touched. Determines whether "only writes
trigger re-evaluation" is a safe assumption to design around.

### Q9 — What happens when a route-status controller is paired with a DNS controller that deletes records?

The failure only becomes user-visible when something consumes route status and acts
on its absence. Not modelled here at all; the lab observes status only.
