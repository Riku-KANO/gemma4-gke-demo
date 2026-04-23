# Resource reference — YAML schemas

Exact YAML structure for every CRD involved in a GKE Inference Gateway
stack. Use this when writing or auditing manifests. For how resources
relate to each other, see `multi-model-recipe.md`. For common mistakes,
see `pitfalls.md`.

## Table of contents

- [InferencePool (v1 — current)](#inferencepool-v1--current)
- [InferenceObjective (v1alpha2 — current)](#inferenceobjective-v1alpha2--current)
- [HTTPRoute (inference pattern)](#httproute-inference-pattern)
- [Gateway](#gateway)
- [GCPRoutingExtension (GKE)](#gcproutingextension-gke)
- [GCPBackendPolicy (GKE)](#gcpbackendpolicy-gke)
- [HealthCheckPolicy (GKE)](#healthcheckpolicy-gke)
- [InferenceModel (deprecated) — recognize and migrate](#inferencemodel-deprecated--recognize-and-migrate)

---

## InferencePool (v1 — current)

```yaml
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: my-pool
spec:
  # Required. The port(s) on which backend pods serve the inference API.
  targetPorts:
    - number: 8000          # NOT `targetPortNumber` — old field, removed
  appProtocol: http         # Optional but recommended. "http" | "grpc"

  # Required. Label selector over Pods. The Gateway's endpoint picker
  # picks among Pods matching this selector.
  selector:
    matchLabels:
      app: my-model-server

  # Required. Reference to the EPP Service (same namespace) that
  # implements the picker's gRPC ext-proc protocol on `port`.
  endpointPickerRef:
    name: my-pool-epp       # NOT `extensionRef` — old field, renamed
    port:
      number: 9002
    failureMode: FailOpen   # FailOpen | FailClose
```

Key changes from older GKE-specific `inference.networking.gke.io/v1`:
- Group moved from `inference.networking.gke.io` to `inference.networking.k8s.io`.
- `targetPortNumber: 8000` → `targetPorts: [{number: 8000}]`.
- `extensionRef` → `endpointPickerRef` (and it's a sub-object with its own `port`).

Status conditions to watch:
- `Accepted=True` — the Gateway controller accepted the pool.
- `ResolvedRefs=True` — the referenced EPP Service exists and is reachable.

---

## InferenceObjective (v1alpha2 — current)

```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: my-pool-default
spec:
  # Optional. Higher = more important. Unset treated as 0.
  priority: 0

  # Required. Reference to the InferencePool this objective applies to.
  poolRef:
    group: inference.networking.k8s.io   # defaults to this; may be omitted
    kind: InferencePool                  # defaults to this; may be omitted
    name: my-pool
```

**Important:** `InferenceObjective` has NO `modelName` field. It is NOT
a replacement for the deprecated `InferenceModel.modelName`. It only
signals request priority to the EPP's scheduling logic. If you are
trying to do model→pool routing, use BBR + HTTPRoute header-match
instead (see `multi-model-recipe.md`).

Alpha resource — expect breaking changes across minor versions. Pin
your extension release tag and read the release notes.

---

## HTTPRoute (inference pattern)

The HTTPRoute that targets an `InferencePool` as a `backendRef`. The
typical inference pattern uses a header match populated by BBR.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-model
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: inference-gw
  rules:
  - backendRefs:
    # An InferencePool is a valid backendRef target — not a Service.
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: my-pool
    matches:
    - path:
        type: PathPrefix
        value: /
      headers:
      # BBR sets this header based on the request body's `model` field.
      - type: Exact
        name: X-Gateway-Model-Name
        value: my-model-id
```

For multi-model setups, create one HTTPRoute per pool, all with
`parentRef` pointing at the same Gateway, each matching a different
`X-Gateway-Model-Name` value.

---

## Gateway

Standard Kubernetes Gateway API resource. The GKE-specific bit is the
`gatewayClassName`.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: inference-gw
spec:
  # For regional external L7 behind a Google-managed proxy:
  gatewayClassName: gke-l7-regional-external-managed

  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
```

The `gke-l7-regional-external-managed` class requires a **proxy-only
subnet** in the region (`10.129.0.0/23` or similar), created with
`gcloud compute networks subnets create --purpose=REGIONAL_MANAGED_PROXY`.

---

## GCPRoutingExtension (GKE)

GKE-specific CRD that attaches an Envoy ext-proc extension (like BBR)
to a Gateway.

```yaml
apiVersion: networking.gke.io/v1
kind: GCPRoutingExtension
metadata:
  name: body-based-router
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: inference-gw

  extensionChains:
  - name: chain1
    extensions:
    - name: ext1
      authority: myext.com       # Virtual authority sent to the ext-proc
      timeout: 1s
      supportedEvents:
      - RequestHeaders
      - RequestBody           # Required for BBR to read the body
      - RequestTrailers
      # Full-duplex streaming lets BBR see the body as it arrives
      requestBodySendMode: FullDuplexStreamed
      backendRef:
        kind: Service
        name: body-based-router
        port: 9004             # BBR's gRPC ext-proc port
```

If BBR isn't running or this extension isn't accepted, clients will
not have `X-Gateway-Model-Name` set, so HTTPRoute header matches
will never match and requests will return 404.

---

## GCPBackendPolicy (GKE)

Per-backend policy attached to an `InferencePool`. Sets timeout and
request logging for traffic to that pool.

```yaml
apiVersion: networking.gke.io/v1
kind: GCPBackendPolicy
metadata:
  name: my-pool
spec:
  targetRef:
    group: inference.networking.k8s.io
    kind: InferencePool
    name: my-pool
  default:
    timeoutSec: 300       # LLM generations can be slow — keep this generous
    logging:
      enabled: true       # Request logs in Cloud Logging
```

Without an explicit `GCPBackendPolicy`, the GKE L7 defaults apply (30s
timeout), which will kill long generations. Always tune this for LLM
workloads.

---

## HealthCheckPolicy (GKE)

Per-backend health check config. Used for both the EPP (gRPC) and model
server (HTTP) in the upstream chart output.

```yaml
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
metadata:
  name: my-pool
spec:
  targetRef:
    group: inference.networking.k8s.io
    kind: InferencePool
    name: my-pool
  default:
    timeoutSec: 2
    checkIntervalSec: 2
    config:
      type: HTTP
      httpHealthCheck:
        requestPath: /health
        port: 8000
```

For BBR's own health-check:

```yaml
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
metadata:
  name: bbr-healthcheck
spec:
  targetRef:
    kind: Service
    name: body-based-router
  default:
    config:
      type: GRPC
      grpcHealthCheck:
        portSpecification: USE_FIXED_PORT
        port: 9005
```

---

## InferenceModel (deprecated — recognize and migrate)

Do not write new `InferenceModel` resources. If you see one in an
existing repo, plan its migration.

```yaml
# DEPRECATED — don't copy this pattern into new work
apiVersion: inference.networking.gke.io/v1alpha1
kind: InferenceModel
metadata:
  name: model-a
spec:
  modelName: google/gemma-4-1b-it      # Used for body-dispatch
  criticality: Standard                # Standard | Critical
  poolRef:
    name: model-a-pool
```

Migration recipe (summary — see `multi-model-recipe.md` for full
worked example):

| Old (InferenceModel) | New (equivalent) |
|---|---|
| `spec.modelName: "x"` | BBR plugin + HTTPRoute `headers: [{name: X-Gateway-Model-Name, value: "x"}]` |
| `spec.criticality: Critical` | `InferenceObjective.spec.priority: <high-number>` (optional) |
| `spec.poolRef.name: p` | HTTPRoute `backendRefs: [{group: inference.networking.k8s.io, kind: InferencePool, name: p}]` |

After migrating every InferenceModel, `kubectl delete` them. The CRD
itself can be left installed (or removed when you upgrade the
extension, the new `manifests.yaml` no longer ships it).

---

## Quick reference — field name changes from older APIs

If you encounter a tutorial or existing manifest, here are the renames
to be aware of when modernizing:

| Old | New |
|---|---|
| `apiVersion: inference.networking.gke.io/v1` | `apiVersion: inference.networking.k8s.io/v1` |
| `spec.targetPortNumber: 8000` | `spec.targetPorts: [{number: 8000}]` |
| `spec.extensionRef.name: gke-managed-endpoint-picker` | `spec.endpointPickerRef.name: <own-epp-service>` |
| `kind: InferenceModel` | (split into BBR + HTTPRoute header match; optionally + InferenceObjective) |
