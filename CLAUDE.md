# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

End-to-end **learning / verification** demo wiring three technologies on GKE:

1. **Gemma** served by **vLLM** on an L4 GPU node
2. **GKE Inference Gateway** — `InferencePool` + `InferenceModel` + `Gateway` + `HTTPRoute` routing into the Gemma Service
3. An **ADK** (Google Agent Development Kit) Python agent with tool calling that talks to Gemma through the Inference Gateway's OpenAI-compatible endpoint via `LiteLlm`

Not production-hardened. Default IaC approach for this repo is **plain `gcloud` + `kubectl` scripts with raw YAML** — do not introduce Terraform, Helm, or Kustomize.

## Common commands

All workflow is driven by numbered scripts in `scripts/`. They source `scripts/_lib.sh`, which requires a populated `.env` (copy from `.env.example`). Each script prints the next command at the end.

```bash
bash scripts/00-prereqs.sh              # preflight + manual-verification checklist
bash scripts/01-enable-apis.sh          # APIs + Artifact Registry repo
bash scripts/02-create-cluster.sh       # GKE Standard + L4 node pool + proxy-only subnet (~8 min)
bash scripts/03-install-gateway-crds.sh # upstream Gateway API + Inference Extension CRDs
bash scripts/04-create-secrets.sh       # kube Secret for HF_TOKEN
bash scripts/05-deploy-gemma.sh         # vLLM Deployment/Service; first-start model pull is 10–20 min
bash scripts/06-deploy-gateway.sh       # InferencePool/Model + Gateway + HTTPRoute; waits for Gateway IP
bash scripts/07-build-agent.sh          # Cloud Build → Artifact Registry
bash scripts/08-deploy-agent.sh         # patches image + Gateway URL into manifest, applies, waits for LB
bash scripts/09-verify.sh               # Stage 1: Gemma via Gateway. Stage 2: agent tool calls.
bash scripts/99-teardown.sh             # deletes cluster, AR repo, proxy subnet
```

Observing the long-running pieces:

```bash
kubectl logs -l app=gemma-vllm -f                 # model download / vLLM startup
kubectl describe gateway inference-gw             # if Gateway IP never appears
kubectl get svc agent                             # agent LoadBalancer IP
```

There is no test suite, linter, or build outside those scripts.

## Architecture

Traffic path at runtime:

```
client ──HTTP──▶ agent Service (LoadBalancer, :8080)
                 └─ ADK FastAPI app (agent/main.py) hosts the gemma_demo_agent app
                    └─ LlmAgent uses LiteLlm(openai/$MODEL_ID, api_base=$GATEWAY_URL)
                       └─ Inference Gateway (gke-l7-regional-external-managed, :80)
                          └─ HTTPRoute /v1/* ──▶ InferencePool `gemma-pool`
                             └─ endpoint picker extension ──▶ Pods matching app=gemma-vllm
                                └─ vLLM OpenAI server :8000 serving $MODEL_ID
```

Key wiring points, because they span multiple files:

- **`MODEL_ID` must stay consistent in three places:** `.env`, `manifests/gemma/deployment.yaml`, `manifests/gateway/inferencemodel.yaml`. The `05-` and `06-` scripts patch the manifests via `sed` replacing the literal placeholder `google/gemma-4-4b-it` at apply time. If you edit the manifests by hand, update all three.
- **`__AGENT_IMAGE__` and `__GATEWAY_URL__`** placeholders in `manifests/agent/deployment.yaml` are filled in by `08-deploy-agent.sh` — the template itself is not directly appliable.
- **InferencePool → Pods** is label-based (`selector: app=gemma-vllm`); the `InferencePool` is a `backendRef` of the `HTTPRoute`, not a Service. The endpoint picker extension (`gke-managed-endpoint-picker`) handles load-balancing decisions.
- **Proxy-only subnet** (`proxy-only-${REGION}`, `10.129.0.0/23`) is required by the regional external managed Gateway class and is created by `02-create-cluster.sh`.
- **GPU scheduling:** node pool carries taint `nvidia.com/gpu=present:NoSchedule`; the Gemma Deployment tolerates it and selects `cloud.google.com/gke-accelerator=nvidia-l4`.
- **Agent ↔ Gateway coupling:** the agent reads `MODEL_ID` and `GATEWAY_URL` from env. `LiteLlm(model=f"openai/{MODEL_ID}", api_key="not-needed")` speaks OpenAI chat-completions against the Gateway; the Gateway's HTTPRoute matches `/v1/` and routes into vLLM, which serves that same model name.

Layout:

```
scripts/        numbered bash scripts; _lib.sh loads .env and defines log/warn/die
manifests/
  gemma/        vLLM Deployment + Service
  gateway/      InferencePool, InferenceModel, Gateway, HTTPRoute
  agent/        ADK agent Deployment (templated) + Service
agent/          ADK Python app: main.py (FastAPI), gemma_demo_agent/agent.py (LlmAgent + tools)
```

## Known unknowns to verify before running

These cannot be checked by the scripts; `00-prereqs.sh` prints them as a checklist:

1. Exact Gemma 4 HF model ID — `google/gemma-4-4b-it` is a placeholder.
2. Correct vLLM `--tool-call-parser` for Gemma 4 — currently `hermes` as a guess.
3. Gateway API Inference Extension release tag (`v0.3.0` pinned in `03-install-gateway-crds.sh`).
4. L4 GPU quota in the target region (fall back to `us-central1` if `asia-northeast1` is denied).
5. GKE rapid channel offers ≥ 1.32.3 in the region.

When you change one of these, propagate it consistently (see the three-places `MODEL_ID` note above).
