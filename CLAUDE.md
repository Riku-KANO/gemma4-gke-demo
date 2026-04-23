# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

End-to-end **learning / verification** demo of three GKE Inference Gateway
features, wired through a single two-model Gemma stack:

1. **Multi-model body-based routing** — one Gateway endpoint, two Gemma
   models (small + large), dispatched by the OpenAI `model` field in the
   request body.
2. **Prefix-cache-aware routing** — the large pool runs 2+ replicas; the
   EPP's prefix-cache scorer pins requests sharing a system prompt to the
   same replica so vLLM's `--enable-prefix-caching` actually hits.
3. **Tool-calling ADK agent** — the small model is a fast orchestrator;
   hard questions are forwarded to the large model via a `consult_expert`
   tool that round-trips back through the Gateway.

Not production-hardened. Default IaC approach for this repo is **plain
`gcloud` + `kubectl` scripts with raw YAML** — do not introduce Terraform,
Helm, or Kustomize in the runtime path. (Some gateway YAMLs are `helm
template` output checked in as plain manifests — regenerate recipes are at
the top of each file.)

## Common commands

All workflow is driven by numbered scripts in `scripts/`. They source
`scripts/_lib.sh`, which requires a populated `.env` (copy from
`.env.example`). Each script prints the next command at the end.

```bash
bash scripts/00-prereqs.sh              # preflight + manual-verification checklist
bash scripts/01-enable-apis.sh          # APIs + Artifact Registry repo
bash scripts/02-create-cluster.sh       # GKE Standard + L4 node pool + proxy-only subnet (~10 min)
bash scripts/03-install-gateway-crds.sh # upstream Gateway API + Inference Extension v1.5.0 CRDs
bash scripts/04-create-secrets.sh       # kube Secret for HF_TOKEN
bash scripts/05-deploy-gemma.sh         # two vLLM Deployments (small + large); first-start pull is 10–20 min each
bash scripts/06-deploy-gateway.sh       # Gateway + BBR + 2 pools (EPP/HTTPRoute/policies) + InferenceObjectives
bash scripts/07-build-agent.sh          # Cloud Build → Artifact Registry
bash scripts/08-deploy-agent.sh         # patches image + Gateway URL into manifest, applies, waits for LB
bash scripts/09-verify.sh               # 3 stages: multi-model, prefix cache, agent orchestration
bash scripts/99-teardown.sh             # deletes cluster, AR repo, proxy subnet
```

Observing the long-running pieces:

```bash
kubectl logs -l app=gemma-small -f                # small-model vLLM startup
kubectl logs -l app=gemma-large -f                # large-model vLLM startup
kubectl logs -l app=body-based-router -f          # BBR header-injection decisions
kubectl logs deploy/gemma-small-epp -f            # small-pool endpoint picker
kubectl logs deploy/gemma-large-epp -f            # large-pool endpoint picker
kubectl describe gateway inference-gw             # if Gateway IP never appears
kubectl get svc agent                             # agent LoadBalancer IP
```

There is no test suite, linter, or build outside those scripts.

## Architecture

Traffic path at runtime:

```
client ─HTTP─▶ agent Service (LoadBalancer, :8080)
               └─ ADK FastAPI app (agent/main.py) hosts gemma_demo_agent
                  ├─ orchestrator:  LiteLlm(openai/$MODEL_ID_SMALL, api_base=$GATEWAY_URL)
                  └─ consult_expert: httpx.post($GATEWAY_URL/chat/completions, model=$MODEL_ID_LARGE)
                     ▼
                  Inference Gateway (gke-l7-regional-external-managed, :80)
                     ▼
                  BBR extension (GCPRoutingExtension, ext-proc on Service body-based-router:9004)
                     │ reads body.model, sets header X-Gateway-Model-Name
                     ▼
                  two HTTPRoutes (one per pool) match that header (Exact)
                     ├─ header=$MODEL_ID_SMALL ──▶ InferencePool gemma-small
                     │                              └─ EPP gemma-small-epp (grpc ext-proc :9002)
                     │                                 └─ Pods with label app=gemma-small
                     └─ header=$MODEL_ID_LARGE ──▶ InferencePool gemma-large
                                                    └─ EPP gemma-large-epp (prefix-cache scorer)
                                                       └─ Pods with label app=gemma-large
```

Key wiring points, because they span multiple files:

- **`MODEL_ID_SMALL` / `MODEL_ID_LARGE`** appear in these places:
  - `.env` (source of truth)
  - `manifests/gemma/deployment-{small,large}.yaml` (vLLM `--model` flag
    and `MODEL_ID` env)
  - `manifests/gateway/pool-{small,large}.yaml` (HTTPRoute's
    `X-Gateway-Model-Name` header match — carries the placeholder
    `__MODEL_ID_SMALL__` / `__MODEL_ID_LARGE__`)
  - `manifests/agent/deployment.yaml` (env passed into the ADK container)

  The numbered scripts patch placeholders via `sed` at apply time so the
  YAML stays declarative. Edit the source-of-truth `.env`, not the
  rendered values.

- **`__AGENT_IMAGE__` and `__GATEWAY_URL__`** placeholders in
  `manifests/agent/deployment.yaml` are filled by `08-deploy-agent.sh`.

- **BBR is the new model-to-pool dispatcher.** Without BBR the header
  never gets set, HTTPRoute header matches fail, and requests are
  rejected. BBR is wired to the Gateway via a `GCPRoutingExtension`
  (`networking.gke.io/v1`) — a GKE-specific CRD.

- **Each InferencePool has its OWN endpoint picker (EPP) Deployment.**
  This replaces the older `gke-managed-endpoint-picker` pattern. The
  per-pool EPP (`inference.networking.k8s.io/v1` → `endpointPickerRef`)
  runs the queue/kv-cache/prefix-cache scorers; prefix-cache-aware
  routing lives in the EPP, not in the Gateway.

- **`InferenceObjective` (`v1alpha2`)** only carries request priority. It
  is NOT a replacement for the deprecated `InferenceModel.modelName` —
  body-based dispatch is BBR's job. The objectives are a nice-to-have;
  the demo works without them.

- **Proxy-only subnet** (`proxy-only-${REGION}`, `10.129.0.0/23`) is
  required by the regional external managed Gateway class and is
  created by `02-create-cluster.sh`.

- **GPU scheduling:** node pool carries taint
  `nvidia.com/gpu=present:NoSchedule`; the Gemma Deployments tolerate
  it and select `cloud.google.com/gke-accelerator=nvidia-l4`.

Layout:

```
scripts/        numbered bash scripts; _lib.sh loads .env and defines log/warn/die
manifests/
  gemma/        deployment-{small,large} + service-{small,large}
  gateway/      gateway.yaml
                bbr.yaml                         (BBR Deployment/Service/RBAC + GCPRoutingExtension)
                pool-{small,large}.yaml         (EPP + InferencePool + HTTPRoute + GCP policies;
                                                 each is helm-rendered — regen recipe at top of file)
                inferenceobjective-{small,large}.yaml  (priority hints)
  agent/        ADK agent Deployment (templated) + Service
agent/          ADK Python app: main.py (FastAPI), gemma_demo_agent/agent.py (LlmAgent + tools)
                pyproject.toml + uv.lock managed with uv; no requirements.txt
```

## Python / agent dev

Dependency management uses **uv** (not pip). The Dockerfile installs the uv
binary and runs `uv sync --frozen`. To work on the agent locally:

```bash
cd agent
uv sync                         # create .venv from uv.lock
uv run python main.py           # needs MODEL_ID_SMALL, MODEL_ID_LARGE, GATEWAY_URL env
uv add <package>                # adds a dep — updates pyproject.toml and uv.lock
uv lock --upgrade               # bump all deps to latest compatible
```

Prefer latest versions; don't pin floors unless there's a concrete reason.

## Regenerating gateway YAML from the upstream Helm charts

`manifests/gateway/bbr.yaml` and `manifests/gateway/pool-{small,large}.yaml`
are `helm template` output of the upstream charts, with the Gateway name
patched from `inference-gateway` to `inference-gw`. Each file contains the
exact command in a header comment. Regenerate when bumping the extension
version (`v0` Helm chart today → tracks `INFERENCE_EXT_VERSION` in
`scripts/03-install-gateway-crds.sh`).

## Known unknowns to verify before running

`scripts/00-prereqs.sh` prints a full checklist. Current placeholders:

1. `MODEL_ID_SMALL` and `MODEL_ID_LARGE` — Gemma 4 HF repo names are
   placeholders; verify on huggingface.co/google.
2. vLLM `--tool-call-parser=gemma4` + `--chat-template=examples/tool_chat_template_gemma4.jinja`
   (verified against vLLM main: `vllm/tool_parsers/gemma4_tool_parser.py`).
3. Gateway API Inference Extension version — `v1.5.0` CRDs and `v0`
   staging Helm chart (EPP/BBR images are `:main`).
4. L4 GPU quota ≥ 3 in chosen region (`asia-northeast1` default;
   `us-central1` fallback).
5. GKE rapid channel version: need ≥ 1.32.3; ideally ≥ 1.34.0-gke.1626000
   so InferencePool v1 CRD is GKE-managed.

When you change an entry that affects multiple files, propagate it
through all the places called out in the "Key wiring points" section.
