# gemma4-gke-demo

End-to-end minimal demo of three technologies working together on GKE:

1. **Gemma** served by **vLLM** on an L4 GPU node
2. **GKE Inference Gateway** (`InferencePool` + `InferenceModel` + `Gateway` + `HTTPRoute`)
   routing traffic to the Gemma service
3. An **ADK (Agent Development Kit)** Python agent with tool calling
   (`get_current_time`, `calculator`) that talks to Gemma through the Inference
   Gateway via an OpenAI-compatible endpoint (`LiteLlm`)

This is a learning / verification project. It is not hardened for production.

## Prerequisites

- A GCP project with billing enabled
- `gcloud`, `kubectl`, `docker`, `jq` on PATH
- NVIDIA L4 GPU quota ≥ 1 in your target region
  (`asia-northeast1` by default; fall back to `us-central1` if denied)
- A Hugging Face account with:
  - An API token in `HF_TOKEN`
  - License accepted on the Gemma model page at https://huggingface.co/google

## Quickstart

```bash
cp .env.example .env
# edit .env: PROJECT_ID, HF_TOKEN, and verify MODEL_ID matches a real HF repo

bash scripts/00-prereqs.sh            # sanity checks + checklist of unknowns
bash scripts/01-enable-apis.sh
bash scripts/02-create-cluster.sh     # ~8 min
bash scripts/03-install-gateway-crds.sh
bash scripts/04-create-secrets.sh
bash scripts/05-deploy-gemma.sh       # first pod start is slow (model download)
bash scripts/06-deploy-gateway.sh
bash scripts/07-build-agent.sh
bash scripts/08-deploy-agent.sh
bash scripts/09-verify.sh             # 2-stage verification
```

When finished:

```bash
bash scripts/99-teardown.sh
```

## Cost

Single L4 node, Tokyo region: roughly **$1.10/hr**. Always run the teardown
script when you're done.

## Layout

```
scripts/    ordered bash scripts (00 prereqs → 09 verify, 99 teardown)
manifests/
  gemma/    vLLM Deployment + Service
  gateway/  InferencePool, InferenceModel, Gateway, HTTPRoute
  agent/    ADK agent Deployment + Service
agent/      ADK Python app (agent.py, main.py, Dockerfile)
```

## Known unknowns to verify before running

See `scripts/00-prereqs.sh` — it prints a checklist that includes:

1. Exact Gemma 4 HF model ID (the placeholder `google/gemma-4-4b-it` must match a real repo)
2. Correct vLLM `--tool-call-parser` for Gemma 4
3. Correct release URL for GKE Inference Extension CRDs
4. L4 GPU quota in the chosen region
5. GKE rapid channel version ≥ 1.32.3

## References

- Serve Gemma with vLLM on GKE — https://cloud.google.com/kubernetes-engine/docs/tutorials/serve-gemma-gpu-vllm
- About GKE Inference Gateway — https://cloud.google.com/kubernetes-engine/docs/concepts/about-gke-inference-gateway
- ADK Docs — https://google.github.io/adk-docs
- Gateway API Inference Extension — https://github.com/kubernetes-sigs/gateway-api-inference-extension
