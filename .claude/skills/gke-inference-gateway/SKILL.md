---
name: gke-inference-gateway
description: Expert knowledge of GKE Inference Gateway — InferencePool (inference.networking.k8s.io/v1), InferenceObjective (x-k8s.io/v1alpha2), Body-Based Router (BBR), per-pool Endpoint Picker (EPP), GCPRoutingExtension / GCPBackendPolicy / HealthCheckPolicy, and the migration away from the deprecated InferenceModel API. Use this skill proactively whenever the user is working with GKE Inference Gateway, Gateway API Inference Extension on GKE, multi-model LLM serving behind one Gateway, vLLM-on-GKE routing, prefix-cache-aware routing, or endpoint pickers. Also trigger on confusion between `inference.networking.gke.io` vs `inference.networking.k8s.io` API groups, mentions of "body-based routing", "InferencePool", "InferenceModel" (deprecated), "InferenceObjective", "EPP", "endpoint picker", "BBR", or when debugging why a request isn't reaching the expected model. Even if the user doesn't explicitly say "inference gateway", trigger when they're deploying vLLM/HF models on GKE behind a Gateway API and asking about dispatching between multiple models.
---

# GKE Inference Gateway

Reference knowledge captured from a real two-model Gemma + vLLM build. This
skill encodes the *current* mental model (as of Gateway API Inference
Extension **v1.5.0**, April 2026) because the space moved fast and several
resources that appear in older tutorials are now deprecated or renamed.

## When to trust this skill vs go look

Trust this skill for: which API group to use, what each CRD is for, how
BBR relates to HTTPRoute, what the multi-model wiring looks like end-to-end,
and why certain "obvious" patterns (like "replace InferenceModel with
InferenceObjective") don't work.

Go verify upstream (https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases)
for: the latest release tag, EPP/BBR container image versions, and any
spec-level changes to alpha resources. Alpha resources (`InferenceObjective`,
`InferenceModelRewrite`, `InferencePoolImport`) can break between minors.

## Core mental model — the 5 facts that matter most

Most mistakes in this area come from missing one of these. Internalize all
five before writing any manifests.

### 1. There are two API groups, not one

| Group | What's in it | Status |
|---|---|---|
| `inference.networking.k8s.io/v1` | `InferencePool` (stable v1) | Current |
| `inference.networking.x-k8s.io/v1alpha2` | `InferenceObjective`, `InferenceModelRewrite`, `InferencePoolImport` | Alpha, ships in same release |
| `inference.networking.gke.io/v1{,alpha1}` | `InferencePool`, `InferenceModel` (older GKE-specific types) | **Obsolete** — do not use for new work |

If you see `inference.networking.gke.io` in a tutorial, the tutorial is
pre-v1.5 and its recommendations may not apply.

### 2. `InferenceModel` is deprecated — and `InferenceObjective` is NOT its replacement

This is the single most common trap.

- **`InferenceModel`** (deprecated) used to carry `spec.modelName` and did
  body-based dispatch: the GKE-managed endpoint picker read the request
  body's OpenAI `model` field and sent the request to the `InferencePool`
  whose `InferenceModel.modelName` matched. One CRD did two jobs:
  (a) declare priority/criticality, (b) body→pool dispatch.

- **`InferenceObjective`** (current, v1alpha2) carries ONLY
  `spec.priority` and `spec.poolRef`. It has no `modelName` field. It is
  *priority signaling*, not dispatch. You can run the stack without it.

- **Body→pool dispatch is now done by BBR** (Body-Based Router), which is
  a separate extension Deployment (see fact #3).

So "replace InferenceModel with InferenceObjective" is wrong as a
drop-in. It needs to be "replace InferenceModel with BBR + header-matching
HTTPRoutes, and *optionally* add InferenceObjective for priority."

### 3. BBR is the new body→pool dispatcher

BBR (Body-Based Router) is the mechanism that replaces `InferenceModel.modelName`.

```
Client POST /v1/chat/completions  {"model": "google/gemma-4-4b-it", ...}
      │
      ▼
Gateway (receives request)
      │
      ▼
BBR ext-proc (reads request body, finds `model` field,
              sets header X-Gateway-Base-Model-Name)
      │
      ▼
HTTPRoute rule matches on that header (Exact match)
      │
      ▼
InferencePool (selected by HTTPRoute backendRef)
```

On GKE, BBR is wired to the Gateway via a `GCPRoutingExtension`
(`networking.gke.io/v1`) — a GKE-specific CRD that sets up ext-proc for
the Gateway. The BBR itself is a Deployment + Service + RBAC.

**The HTTPRoute header name is `X-Gateway-Base-Model-Name`**, set by BBR's
`base-model-to-header:base-model-mapper` plugin. HTTPRoute matches this
header with `type: Exact`.

### 4. Every InferencePool owns its Endpoint Picker (EPP)

There is no shared endpoint picker in the current architecture. The old
`extensionRef: name: gke-managed-endpoint-picker` pattern is obsolete.

Each `InferencePool` must reference its own EPP via `endpointPickerRef`:

```yaml
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
spec:
  targetPorts:
    - number: 8000
  selector:
    matchLabels:
      app: gemma-small
  endpointPickerRef:
    name: gemma-small-epp     # Service name — the EPP is a separate Deployment
    port:
      number: 9002
    failureMode: FailOpen
```

The EPP Deployment runs scorers (queue depth, KV-cache utilization,
prefix-cache, etc.) and returns the best pod to the Gateway via gRPC
ext-proc. **Prefix-cache-aware routing lives in the EPP**, not in the
Gateway — if you need it, ensure the EPP's plugin list includes
`prefix-cache-scorer` and the model server has prefix caching enabled
(for vLLM: `--enable-prefix-caching`).

### 5. Install the CRDs + use Helm templates as a starting point

The clean install uses upstream Helm charts:

- `oci://.../charts/body-based-routing` — BBR + GCPRoutingExtension
- `oci://.../charts/inferencepool` — one instance per model, produces
  EPP Deployment/Service/ConfigMap/RBAC + InferencePool + HTTPRoute +
  GCPBackendPolicy + HealthCheckPolicy

If the user's project avoids Helm at runtime, `helm template` the charts
and commit the plain YAML — regen recipe at the top of each file. This
is a legitimate way to benefit from the chart's structure without making
Helm a deploy-time dep.

CRDs come from the release `manifests.yaml`:
`github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/<TAG>/manifests.yaml`

## Anatomy of a multi-model setup

For 2+ models behind a single Gateway endpoint, you need:

1. **Gateway** (one, usually `gatewayClassName: gke-l7-regional-external-managed`)
2. **BBR + GCPRoutingExtension** targeting that Gateway (one installation per Gateway)
3. **Per model**:
   - Model-serving Deployment + Service (vLLM, TGI, etc.)
   - EPP Deployment + Service + ConfigMap + RBAC
   - `InferencePool` referencing the EPP
   - `HTTPRoute` with `parentRef` → the Gateway and `matches.headers` → `X-Gateway-Base-Model-Name` → the model's name. `backendRefs` → the `InferencePool`.
   - (GKE optional) `GCPBackendPolicy` for timeout/logging, `HealthCheckPolicy` for the EPP
4. **Optional**: `InferenceObjective` per pool for priority signaling

For the full worked example with concrete YAML (the recipe that
corresponds to each of these components), see
`references/multi-model-recipe.md`.

## Common mistakes

Before writing a manifest or giving advice, check that you're not falling
into one of these:

- **Wrong API group** — `inference.networking.gke.io` instead of
  `inference.networking.k8s.io`. The GKE-specific group is obsolete.
- **Deprecated `InferenceModel`** — don't add new ones. If the user has
  them, migrate to BBR + HTTPRoute header match.
- **Old field names** on InferencePool — it's `targetPorts: [{number: X}]`
  and `endpointPickerRef`, not `targetPortNumber` and `extensionRef`.
- **Assuming InferenceObjective replaces InferenceModel** — it doesn't.
  Objective is priority only.
- **Single shared endpoint picker** — gone. Each pool has its own EPP.
- **Staging images locked forever** — the `v0` Helm chart ships EPP/BBR
  as `:main` tag from the staging registry. Flag this to users
  evaluating production readiness.
- **Gateway name mismatch** — upstream charts default to
  `inference-gateway`; if your Gateway is named differently, patch the
  rendered YAML.

For deeper explanations and how to diagnose each, see
`references/pitfalls.md`.

## When to read which reference

- **Building a new multi-model stack from scratch?** Start with
  `references/multi-model-recipe.md` — it's the complete end-to-end
  worked example including a vLLM deployment and the agent-side setup.
- **Writing individual CRDs and need exact field schemas?**
  `references/resource-reference.md` — YAML schemas for InferencePool,
  InferenceObjective, GCPRoutingExtension, GCPBackendPolicy,
  HealthCheckPolicy. Includes the deprecated `InferenceModel` schema so
  you can recognize and migrate it.
- **User has a setup that isn't working?** `references/pitfalls.md` —
  each common mistake, the symptom, and the fix.

## Diagnostic quick-reference

When something isn't working, check in this order:

1. **Gateway has an IP** — `kubectl describe gateway <name>`. No IP ⇒
   listener, class, or proxy-only subnet issue.
2. **InferencePool status Accepted** — `kubectl get inferencepool`. Not
   accepted ⇒ EPP not reachable, wrong selector, or CRD version mismatch.
3. **EPP pod ready** — `kubectl get deploy <pool>-epp`. Readiness probe
   uses gRPC on `:9003` (`service: inference-extension`).
4. **BBR pod ready + GCPRoutingExtension accepted** —
   `kubectl describe gcproutingextension body-based-router`. If it's not
   active, the header is never set and every request 404s from the HTTPRoute.
5. **HTTPRoute Accepted + ResolvedRefs** — `kubectl describe httproute`.
   If ResolvedRefs is False, the `backendRef` → InferencePool link is broken.
6. **Client request actually hits BBR** — send a request with a known
   model name, then `kubectl logs -l app=body-based-router` to confirm
   BBR saw it and set the header.
7. **EPP log for the right pool** — `kubectl logs deploy/<pool>-epp`. If
   BBR set the header but the wrong EPP got the request, the HTTPRoute
   header-match is pointing at the wrong pool.

## Terminology cheat-sheet

- **InferencePool**: a set of backend pods serving one model (or one
  model + its LoRA adapters). Stable v1 CRD. Referenced by HTTPRoute
  `backendRefs`.
- **EPP (Endpoint Picker)**: a Deployment + Service implementing gRPC
  ext-proc. The Gateway calls EPP to pick the best pod within the pool.
- **BBR (Body-Based Router)**: a Deployment + Service that reads the
  request body and sets routing headers (`X-Gateway-Base-Model-Name`).
  Attached to the Gateway as an ext-proc via `GCPRoutingExtension` on GKE.
- **InferenceObjective**: alpha CRD carrying request priority + poolRef.
  Optional. Not a dispatcher.
- **InferenceModel**: deprecated. If you see one, plan its removal.
- **GCPRoutingExtension**: GKE-specific CRD that installs an ext-proc
  callout on a Gateway. Used to wire BBR.
- **GCPBackendPolicy**: GKE-specific per-backend policy (timeout,
  logging) attached to an InferencePool.
- **HealthCheckPolicy**: GKE-specific health-check config for the
  backend behind the Gateway.
