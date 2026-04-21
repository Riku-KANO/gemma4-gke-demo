# gemma4-gke-demo

End-to-end demo of **three GKE Inference Gateway features** in a single
sample application:

- **Multi-model body-based routing** — one Gateway endpoint, two Gemma
  models (small + large) dispatched by the OpenAI `model` field
- **Prefix-cache-aware routing** — the large model runs with 2+ replicas
  and vLLM prefix caching; requests sharing a system prompt land on the
  same replica
- **Tool-calling ADK agent** — the small model acts as a fast orchestrator
  and escalates hard questions to the large model via a `consult_expert`
  tool that goes back through the same Gateway

Stack: **Gemma** on **vLLM**, **GKE Inference Gateway** (`InferencePool v1`,
`InferenceObjective v1alpha2`, `Gateway`, `HTTPRoute`, BBR extension),
**ADK (Agent Development Kit)** Python agent deployed alongside the models.

## Architecture

```
             ┌─────────────────────────────────────────────────────┐
  client ──▶ │  GKE Inference Gateway                              │
             │  ├─ BBR (reads body.model → X-Gateway-Base-Model-Name) │
             │  └─ two HTTPRoutes matching on that header          │
             └───────────┬──────────────────┬────────────────────────┘
                         │ header=SMALL     │ header=LARGE
                         ▼                  ▼
             ┌─────────────────┐   ┌──────────────────────┐
             │ InferencePool   │   │ InferencePool        │
             │ gemma-small     │   │ gemma-large (N ≥ 2)  │
             │ + own EPP       │   │ + own EPP (prefix-   │
             │ 1 vLLM replica  │   │   cache scorer)      │
             │ L4 × 1          │   │ N vLLM replicas · L4 │
             └────────┬────────┘   └──────────┬───────────┘
                      ▲                       ▲
                      │ primary (LiteLlm)     │ consult_expert tool
                      │                       │ (httpx → Gateway)
             ┌────────┴───────────────────────┴───────────┐
             │   ADK agent (orchestrator)                 │
             │   get_current_time / calculator            │
             │   consult_expert → back through Gateway    │
             └────────────────────────────────────────────┘
```

## Prerequisites

- A GCP project with billing enabled
- `gcloud`, `kubectl`, `docker`, `jq`, `uv` on PATH
- NVIDIA L4 GPU quota ≥ **3** in your target region (1 for small +
  2 for large; `LARGE_REPLICAS` is tunable in `.env`)
- Hugging Face account with:
  - An API token in `HF_TOKEN`
  - License accepted on BOTH Gemma model pages
    (small and large) under https://huggingface.co/google

## Quickstart

```bash
cp .env.example .env
# edit .env: PROJECT_ID, HF_TOKEN, MODEL_ID_SMALL, MODEL_ID_LARGE

bash scripts/00-prereqs.sh
bash scripts/01-enable-apis.sh
bash scripts/02-create-cluster.sh       # ~10 min (3 GPU nodes)
bash scripts/03-install-gateway-crds.sh
bash scripts/04-create-secrets.sh
bash scripts/05-deploy-gemma.sh         # first-time model DLs: ~15 min each
bash scripts/06-deploy-gateway.sh
bash scripts/07-build-agent.sh
bash scripts/08-deploy-agent.sh
bash scripts/09-verify.sh               # 3-stage verification
```

Teardown:

```bash
bash scripts/99-teardown.sh
```

## What to look for in `09-verify.sh`

1. **Stage 1** — curl with `model=SMALL` returns SMALL's reply; curl with
   `model=LARGE` returns LARGE's reply. One Gateway endpoint, two pools.
2. **Stage 2** — 4 requests with the same long system prompt: request 1
   is slow, requests 2–4 are noticeably faster, and `kubectl logs` for
   the large pods shows the hits concentrated on one pod.
3. **Stage 3** — "what time / what is 17*23?" → agent uses
   `get_current_time` + `calculator`. "explain merge sort" → agent calls
   `consult_expert` which round-trips through the Gateway to the large
   model.

## Cost

Single region, 3× L4 GPUs running: roughly **$3/hr** in Tokyo. Always run
the teardown script when done.

## Layout

```
scripts/    00 prereqs → 09 verify, 99 teardown (+ _lib.sh shared helpers)
manifests/
  gemma/    deployment-{small,large}, service-{small,large}
  gateway/  gateway.yaml, bbr.yaml (Body-Based Router),
            pool-{small,large}.yaml (EPP + InferencePool + HTTPRoute +
            GCPBackendPolicy + HealthCheckPolicy, one file per pool —
            rendered from the upstream inferencepool Helm chart),
            inferenceobjective-{small,large}.yaml (priority hints)
  agent/    Deployment + LoadBalancer Service
agent/      ADK app; Dockerfile uses uv + pyproject.toml + uv.lock
```

The `bbr.yaml` and `pool-*.yaml` bundles are the `helm template` output of
the upstream charts (with the Gateway name patched to `inference-gw`). Each
file contains a regenerate recipe at the top.

## Known unknowns to verify before running

`scripts/00-prereqs.sh` prints a full checklist. Key ones:

1. Both HF model IDs (`MODEL_ID_SMALL`, `MODEL_ID_LARGE`) must be real
   repos on huggingface.co/google — placeholders follow the Gemma 2/3
   naming pattern.
2. Correct vLLM `--tool-call-parser` for Gemma 4 (currently `hermes`).
3. Gateway API Inference Extension release tag
   (`03-install-gateway-crds.sh` pins `v1.5.0`; Helm chart version is `v0`
   staging — the BBR and EPP images are `:main` tags).
4. L4 GPU quota ≥ 3 in chosen region.
5. GKE rapid channel version ≥ 1.32.3 (and ideally 1.34.0-gke.1626000+
   so InferencePool v1 CRD is GKE-managed).

## References

- Serve Gemma with vLLM on GKE — https://cloud.google.com/kubernetes-engine/docs/tutorials/serve-gemma-gpu-vllm
- About GKE Inference Gateway — https://cloud.google.com/kubernetes-engine/docs/concepts/about-gke-inference-gateway
- ADK Docs — https://google.github.io/adk-docs
- Gateway API Inference Extension — https://github.com/kubernetes-sigs/gateway-api-inference-extension
