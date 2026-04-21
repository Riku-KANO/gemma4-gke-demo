# Pitfalls and how to diagnose them

Each entry below lists a mistake, the symptom you'll see, and the fix.
Check this file when something isn't working before going deep into the
upstream docs — most failures trace back to one of these.

## 1. Using `inference.networking.gke.io` instead of `inference.networking.k8s.io`

**Symptom:** Depending on GKE version, either the CRD doesn't exist
(`unable to recognize ... no matches for kind "InferencePool"`), or the
resource is created but the new endpoint picker / BBR stack can't find
it because they look for `inference.networking.k8s.io` resources via
RBAC.

**Fix:** Use the upstream group everywhere:

```yaml
apiVersion: inference.networking.k8s.io/v1   # NOT inference.networking.gke.io/v1
kind: InferencePool
```

And in `backendRefs`:

```yaml
backendRefs:
- group: inference.networking.k8s.io         # NOT inference.networking.gke.io
  kind: InferencePool
```

**Why this trap exists:** GKE used to ship its own CRD set under
`inference.networking.gke.io` before the upstream graduated. Tutorials
from 2024–early 2025 use the GKE-specific group. The upstream group is
now the right answer even on GKE.

## 2. Trying to replace `InferenceModel` with `InferenceObjective` as a drop-in

**Symptom:** After the swap, requests to the Gateway return 404 with no
matching HTTPRoute, or all requests land on the same pool regardless of
the body's `model` field.

**Root cause:** `InferenceObjective` has no `modelName` field. It does
not perform body-dispatch. The old `InferenceModel.modelName` was
dispatched by the GKE-managed endpoint picker; that pattern is gone.

**Fix:** Replace the dispatch function with BBR:

1. Deploy BBR (`helm template` the `body-based-routing` chart for GKE)
2. Make sure `GCPRoutingExtension` targets your Gateway
3. Rewrite HTTPRoute(s) with `matches.headers` on `X-Gateway-Base-Model-Name`
4. Optionally keep `InferenceObjective` for priority signaling

See `multi-model-recipe.md` for the full worked example.

## 3. Old field names on `InferencePool` (`targetPortNumber`, `extensionRef`)

**Symptom:** `kubectl apply` fails with `unknown field
"spec.targetPortNumber"` (or the field is silently ignored — varies by
validator).

**Fix:** Use the v1 field names:

```yaml
# Correct for inference.networking.k8s.io/v1:
spec:
  targetPorts:
    - number: 8000
  endpointPickerRef:
    name: <epp-service>
    port:
      number: 9002
    failureMode: FailOpen
```

## 4. Assuming there's one shared endpoint picker

**Symptom:** `InferencePool` has `endpointPickerRef: {name: gke-managed-endpoint-picker}`,
but no Service by that name exists. The pool's `ResolvedRefs` condition
is False.

**Fix:** Each InferencePool owns its own EPP Deployment + Service. The
`gke-managed-endpoint-picker` pattern is gone. The upstream Helm chart
`inferencepool` renders a complete per-pool EPP stack (Deployment,
Service, ConfigMap, RBAC). Render it once per model.

**Why this trap exists:** Early GKE Inference Gateway had a
cluster-global managed EPP. The move to per-pool EPPs reflects that
different pools want different scoring strategies (e.g., prefix-cache
scorer only helps when `--enable-prefix-caching` is on).

## 5. Gateway name mismatch with the rendered Helm chart

**Symptom:** HTTPRoute shows `Accepted=Unknown` or `ResolvedRefs=False`;
the `parentRef` name doesn't match any Gateway.

**Root cause:** The upstream charts default to `name: inference-gateway`.
If your Gateway is named differently (e.g., `inference-gw`), the
rendered `parentRefs` and `GCPRoutingExtension.spec.targetRefs` still
point to the old name.

**Fix:** After `helm template`, sed through the output:

```bash
sed -i 's/name: inference-gateway$/name: inference-gw/' rendered.yaml
```

Or rename your Gateway to `inference-gateway`.

## 6. Wrong header name on HTTPRoute

**Symptom:** BBR is running (`kubectl logs -l app=body-based-router`
shows it extracted the model name correctly), but requests still don't
route.

**Common wrong values seen in tutorials:**
- `X-Gateway-Model-Name` — this header IS set by BBR's
  `model-extractor` plugin, but it's the RAW model string. Use the
  `-Base-` variant.
- `X-Base-Model-Name` — missing the `X-Gateway-` prefix.

**Correct header:** `X-Gateway-Base-Model-Name` (set by BBR's
`base-model-to-header:base-model-mapper` plugin).

**Fix:** HTTPRoute `matches.headers[0].name` must be exactly
`X-Gateway-Base-Model-Name`. `type: Exact` is required for model
matching; `RegularExpression` works but is slower.

## 7. `requestBodySendMode` not set to streaming

**Symptom:** BBR logs show it's receiving requests but never manages to
extract the model — body is truncated or empty.

**Fix:** In `GCPRoutingExtension`, the extension must have
`requestBodySendMode: FullDuplexStreamed`. The `BufferedPartial` and
`Buffered` modes lose data for large bodies.

## 8. `GCPBackendPolicy.default.timeoutSec` left at the default 30s

**Symptom:** Requests returning large completions die at ~30s with a
504 from the Gateway. vLLM logs show the generation was still in progress.

**Fix:** Set `timeoutSec: 300` (or longer) in each pool's
`GCPBackendPolicy`. The upstream chart already does this — if you
wrote the policy by hand, don't omit it.

## 9. Prefix-cache-aware routing doesn't help

**Symptom:** Two replicas of the pool, repeated requests with a shared
system prompt, but latency doesn't improve and `vllm:prefix_cache_hits`
stays near zero.

**Checks:**

- Model server has prefix caching enabled. For vLLM:
  `--enable-prefix-caching` on the container args.
- Pool has ≥ 2 replicas (no routing benefit with 1).
- EPP ConfigMap includes `prefix-cache-scorer` in its plugins list and
  the scheduling profile gives it non-trivial weight. The chart
  default weight is 3 (vs 2 for queue/kv-cache).
- The shared prefix is long enough to matter. vLLM's prefix cache
  works at the block level (default 16 tokens); very short prefixes
  won't register as cache hits.
- The client actually reuses the same system prompt string byte-for-
  byte. Any difference breaks the cache.

## 10. Staging images / `:main` tag pinning

**Symptom:** Mysterious breakage after a pod restart or reschedule. The
BBR or EPP image was pulled with a newer `:main` from the staging
registry.

**Why:** The Helm chart at `v0` ships `image: ....../bbr:main` and
`image: ....../epp:main`. These are floating tags on a staging
registry. `imagePullPolicy: Always` compounds the risk.

**Mitigation for production:**
- Pin to a specific immutable tag. Check the release notes at
  `gateway-api-inference-extension/releases` — each release publishes
  versioned images.
- Change `imagePullPolicy: IfNotPresent` on the Deployments.
- For serious production, mirror the images into your own registry.

For demos this is usually acceptable; document it as a known unknown.

## 11. Extension version ≠ CRD version

**Symptom:** `kubectl apply` accepts a manifest, but the resource's
spec is stripped of fields (e.g., `endpointPickerRef.failureMode`
disappears). Or a newer resource kind isn't recognized.

**Root cause:** The CRDs from `manifests.yaml` and the EPP/BBR images
must be from the same release tag. Mixing v1.4 CRDs with v1.5 EPP image
will misbehave.

**Fix:** Pin both to the same release tag:

```bash
INFERENCE_EXT_VERSION=v1.5.0
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${INFERENCE_EXT_VERSION}/manifests.yaml"
# and use the matching Helm chart version for BBR/EPP
```

## 12. Client sends unexpected `model` string → 404

**Symptom:** HTTP 404 from the Gateway. BBR logs show it set a header,
but no HTTPRoute matched.

**Diagnosis:**

```bash
# What did BBR see and set?
kubectl logs -l app=body-based-router --tail=20

# What are the HTTPRoute header values?
kubectl get httproute -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.rules[0].matches[0].headers[?(@.name=="X-Gateway-Base-Model-Name")].value}{"\n"}{end}'
```

**Fix:** The client's `model` string must exactly match an HTTPRoute
header value. Common drift:

- Client uses a short alias (`gemma-4b`); HTTPRoute expects the full HF
  id (`google/gemma-4-4b-it`). Either teach the client or add a BBR
  ConfigMap that maps the alias to the canonical name.
- LoRA adapter name sent instead of base model. BBR's
  `base-model-to-header` plugin needs a ConfigMap of adapter → base.

The upstream BBR supports this via the `bbr-managed` ConfigMaps:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-model-adapters
  labels:
    inference.networking.k8s.io/bbr-managed: "true"
data:
  baseModel: google/gemma-4-4b-it
  adapters: |
    - fine-tune-v1
    - fine-tune-v2
```

Requests with `"model": "fine-tune-v1"` will then resolve to the
`google/gemma-4-4b-it` base and route to its pool.

## General diagnostic order

When something doesn't work, go through these in order:

1. `kubectl get gateway <name>` — IP assigned?
2. `kubectl get inferencepool` — `Accepted=True`, `ResolvedRefs=True`?
3. `kubectl get deploy,svc -l app=body-based-router` — BBR running?
4. `kubectl get gcproutingextension` — accepted?
5. `kubectl get httproute -o wide` — all routes Accepted, Resolved?
6. `kubectl logs -l app=body-based-router` — BBR sees requests, sets header?
7. `kubectl logs deploy/<pool>-epp` — EPP sees traffic on the right pool?
8. `kubectl logs -l app=<model-server>` — model server receiving requests?

Stopping at step N means the issue is between step N-1 and step N.
