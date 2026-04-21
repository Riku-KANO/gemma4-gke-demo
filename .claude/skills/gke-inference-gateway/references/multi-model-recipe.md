# Multi-model GKE Inference Gateway recipe

Concrete end-to-end example for serving **2+ LLMs behind a single GKE
Gateway endpoint** using body-based dispatch. Based on a real 2-model
Gemma + vLLM build that worked in practice on Gateway API Inference
Extension v1.5.0.

The pattern scales: for N models, duplicate the "per-pool" block N times.

## What you'll end up with

```
             ┌─────────────────────────────────────────────────────┐
  client ──▶ │  Gateway (gke-l7-regional-external-managed)         │
             │  ├─ BBR (reads body.model → X-Gateway-Base-Model-Name)  │
             │  └─ two HTTPRoutes matching on that header              │
             └───────────┬──────────────────┬────────────────────────┘
                         │ header=MODEL_A   │ header=MODEL_B
                         ▼                  ▼
             ┌─────────────────┐   ┌──────────────────────┐
             │ InferencePool   │   │ InferencePool        │
             │ + own EPP       │   │ + own EPP            │
             │ N model pods    │   │ M model pods         │
             └─────────────────┘   └──────────────────────┘
```

Request flow:

1. Client POSTs `/v1/chat/completions` with `{"model": "model-a-id", …}`
2. Gateway accepts the connection
3. BBR (attached as ext-proc via `GCPRoutingExtension`) reads the body,
   extracts `model`, sets header `X-Gateway-Base-Model-Name: model-a-id`
4. HTTPRoute for pool A matches the header and forwards to
   `InferencePool model-a`
5. The pool's EPP picks the best pod (queue depth, KV-cache, prefix cache)
6. The pod (vLLM) handles the request

## Prerequisites

- GKE Standard cluster, rapid channel, version ≥ 1.32.3 (ideally
  ≥ 1.34.0-gke.1626000 so InferencePool v1 CRD is GKE-managed).
- `--gateway-api=standard` and a proxy-only subnet in the cluster's region:

  ```bash
  gcloud compute networks subnets create "proxy-only-${REGION}" \
    --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE \
    --region="$REGION" --network=default --range=10.129.0.0/23
  ```

- Model-serving pods already running and reachable in-cluster. The rest
  of this recipe assumes you have Deployments labeled `app: model-a` and
  `app: model-b`, each exposing the OpenAI chat API on port 8000.

## Step 1 — Install CRDs

```bash
GATEWAY_API_VERSION=v1.3.0
INFERENCE_EXT_VERSION=v1.5.0   # always check latest at
                               # github.com/kubernetes-sigs/gateway-api-inference-extension/releases

kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${INFERENCE_EXT_VERSION}/manifests.yaml"

kubectl wait --for=condition=Established --timeout=120s \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io \
  crd/inferencepools.inference.networking.k8s.io \
  crd/inferenceobjectives.inference.networking.x-k8s.io
```

## Step 2 — The Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: inference-gw
spec:
  gatewayClassName: gke-l7-regional-external-managed
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
```

The upstream Helm charts default to `name: inference-gateway`. Either
rename your Gateway to match, or sed the rendered chart output to match
your Gateway's name.

## Step 3 — BBR + GCPRoutingExtension

Render the upstream chart:

```bash
helm template body-based-router \
  oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/body-based-routing \
  --version v0 --set provider.name=gke
```

(Pipe to a file, patch `inference-gateway` → your Gateway's name, commit.)

This produces:

- `ServiceAccount body-based-router-body-based-router` + RBAC Role/Binding for reading ConfigMaps
- `Service body-based-router` on port 9004 (gRPC ext-proc endpoint)
- `Deployment body-based-router` (image: `.../bbr:main` from staging registry)
  - Args include the key plugin config:
    ```
    --plugin body-field-to-header:model-extractor:{"fieldName":"model","headerName":"X-Gateway-Model-Name"}
    --plugin base-model-to-header:base-model-mapper
    --streaming
    ```
- `GCPRoutingExtension body-based-router` — the glue that hooks BBR into
  the Gateway as an ext-proc:
  ```yaml
  apiVersion: networking.gke.io/v1
  kind: GCPRoutingExtension
  spec:
    targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: inference-gw          # <-- patched from inference-gateway
    extensionChains:
    - name: chain1
      extensions:
      - name: ext1
        authority: myext.com
        timeout: 1s
        supportedEvents: [RequestHeaders, RequestBody, RequestTrailers]
        requestBodySendMode: FullDuplexStreamed
        backendRef:
          kind: Service
          name: body-based-router
          port: 9004
  ```
- `HealthCheckPolicy bbr-healthcheck` (gRPC on port 9005 of the BBR service)

Apply. BBR sits idle until requests come in.

## Step 4 — Per-model pool bundles

For each model, render:

```bash
helm template model-a \
  oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/inferencepool \
  --version v0 \
  --set provider.name=gke \
  --set inferencePool.modelServers.matchLabels.app=model-a \
  --set experimentalHttpRoute.enabled=true \
  --set experimentalHttpRoute.baseModel=<model-id-clients-use>
```

`<model-id-clients-use>` is the exact string clients will put in the
OpenAI `model` field. BBR reads it from the body and sets it as the
`X-Gateway-Base-Model-Name` header; the rendered HTTPRoute matches it
with `type: Exact`. If the value mismatches by even one character, the
request will not route.

A single render produces:

- **EPP stack**: ServiceAccount, two Roles + two RoleBindings, Service
  (gRPC :9002, metrics :9090), Deployment (image `.../epp:main`),
  ConfigMap with scorer plugin list:
  ```yaml
  plugins:
  - type: queue-scorer
  - type: kv-cache-utilization-scorer
  - type: prefix-cache-scorer
  - type: metrics-data-source
    parameters: {scheme: http, path: /metrics, insecureSkipVerify: true}
  - type: core-metrics-extractor
  schedulingProfiles:
  - name: default
    plugins:
    - {pluginRef: queue-scorer, weight: 2}
    - {pluginRef: kv-cache-utilization-scorer, weight: 2}
    - {pluginRef: prefix-cache-scorer, weight: 3}
  ```
- **InferencePool** (the key CR):
  ```yaml
  apiVersion: inference.networking.k8s.io/v1
  kind: InferencePool
  metadata:
    name: model-a
  spec:
    targetPorts:
      - number: 8000
    appProtocol: http
    selector:
      matchLabels:
        app: model-a
    endpointPickerRef:
      name: model-a-epp
      port:
        number: 9002
      failureMode: FailOpen
  ```
- **HTTPRoute** (the dispatch rule — one per pool):
  ```yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: model-a
  spec:
    parentRefs:
    - kind: Gateway
      name: inference-gw      # <-- patch from inference-gateway
    rules:
    - backendRefs:
      - group: inference.networking.k8s.io
        kind: InferencePool
        name: model-a
      matches:
      - path: {type: PathPrefix, value: /}
        headers:
        - type: Exact
          name: X-Gateway-Base-Model-Name
          value: <model-id-clients-use>
  ```
- **GCPBackendPolicy** (GKE): `timeoutSec: 300`, logging enabled, targets the pool
- **HealthCheckPolicy** (GKE): HTTP GET `/health` on port 8000

Apply. Repeat for model B, model C, etc.

## Step 5 — (Optional) InferenceObjective per pool

Priority hints the EPP can read. No routing effect — purely for
prioritizing requests when capacity is contended.

```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: model-a-default
spec:
  priority: 0
  poolRef:
    group: inference.networking.k8s.io
    name: model-a
---
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: model-b-default
spec:
  priority: 10              # higher = more important
  poolRef:
    group: inference.networking.k8s.io
    name: model-b
```

Skip this entirely if you have no priority preferences — the demo works
without it.

## Step 6 — Verify

```bash
# Get the external IP
GW_IP=$(kubectl get gateway inference-gw \
         -o jsonpath='{.status.addresses[0].value}')

# Route to model-a
curl -X POST "http://${GW_IP}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"<model-a-id>","messages":[{"role":"user","content":"hi"}]}'

# Route to model-b (same endpoint, different body)
curl -X POST "http://${GW_IP}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"<model-b-id>","messages":[{"role":"user","content":"hi"}]}'
```

Expected logs:

- `kubectl logs -l app=body-based-router` — one line per request showing
  model extraction.
- `kubectl logs deploy/model-a-epp` — sees only model-a traffic.
- `kubectl logs deploy/model-b-epp` — sees only model-b traffic.

If model-a traffic is landing on the model-b EPP (or vice versa), the
HTTPRoute header value doesn't match what BBR is emitting. Check:

```bash
kubectl get httproute model-a -o yaml | grep -A2 'X-Gateway-Base-Model-Name'
kubectl logs -l app=body-based-router | grep -i header
```

## Prefix-cache-aware routing (bonus)

Prefix-cache-aware routing is handled **inside the EPP**, not the
Gateway. To benefit:

1. Use a model server with prefix caching enabled. For vLLM:
   `--enable-prefix-caching` on the server args.
2. Run the pool with ≥ 2 replicas (otherwise there's nothing to route
   between).
3. The default EPP config includes `prefix-cache-scorer` with weight 3,
   so nothing else to enable.

Repeated requests sharing a long prefix should pin to the same replica.
Verify with:

```bash
kubectl exec deploy/model-a -- curl -s localhost:8000/metrics \
  | grep -E 'prefix_cache|num_requests'
```

Look for `vllm:prefix_cache_hits` growing faster than
`vllm:prefix_cache_misses` on follow-up requests.

## Pitfalls specific to the multi-model setup

- **Two HTTPRoutes, same Gateway, same path, different headers**: this
  is the canonical layout. Gateway API resolves them by the `matches`
  specificity.
- **Client sends wrong `model` string**: the request will not match any
  HTTPRoute header-match rule. You'll see a 404 from the Gateway, not a
  routing error. Check BBR logs to see what header value it set.
- **Regenerating the Helm charts later**: keep the sed patch for the
  Gateway name in a script. The chart output is stable across minor
  version bumps but not across major.
- **EPP resource sizing**: the chart defaults to `requests: {cpu: 4, memory: 8Gi}`
  and `limits: {memory: 16Gi}`. That's generous for a small demo; tune
  down if you're tight on node capacity.
