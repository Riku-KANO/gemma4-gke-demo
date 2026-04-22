#!/usr/bin/env bash
# Preflight sanity checks and a checklist of things the user must verify
# manually before running the rest of the scripts.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

log "Checking required CLIs..."
for bin in gcloud kubectl docker jq curl; do
  command -v "$bin" >/dev/null 2>&1 || die "Missing required CLI: $bin"
done

log "Checking gcloud auth..."
gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q '@' \
  || die "No active gcloud account. Run: gcloud auth login"

log "Checking gcloud project..."
current_project="$(gcloud config get-value project 2>/dev/null || true)"
if [[ "$current_project" != "$PROJECT_ID" ]]; then
  warn "gcloud config project is '$current_project' but .env PROJECT_ID is '$PROJECT_ID'."
  warn "Setting gcloud project to '$PROJECT_ID'."
  gcloud config set project "$PROJECT_ID"
fi

log "Checking HF_TOKEN..."
if [[ -z "${HF_TOKEN:-}" || "$HF_TOKEN" == "hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ]]; then
  die "HF_TOKEN is not set in .env (still the placeholder)."
fi

log "Checking L4 GPU quota in $REGION (need at least $GPU_NODE_COUNT)..."
quota_json="$(gcloud compute regions describe "$REGION" --format=json 2>/dev/null || echo '{}')"
l4_limit=$(echo "$quota_json" | jq '[.quotas[] | select(.metric=="NVIDIA_L4_GPUS")] | .[0].limit // 0')
if (( l4_limit < GPU_NODE_COUNT )); then
  warn "NVIDIA_L4_GPUS quota in $REGION is $l4_limit (need $GPU_NODE_COUNT)."
  warn "Request quota at https://console.cloud.google.com/iam-admin/quotas"
  warn "or reduce LARGE_REPLICAS in .env (minimum 2 to demo prefix-cache routing)"
  warn "or switch REGION to us-central1."
fi

cat <<EOF

==============================================================
 Manual verification checklist (scripts cannot check these)
==============================================================
 This demo runs two Gemma models side-by-side so GKE Inference
 Gateway can do what a plain Service cannot:
   - SMALL ($MODEL_ID_SMALL): orchestrator, 1 replica
   - LARGE ($MODEL_ID_LARGE): expert, $LARGE_REPLICAS replicas
                              (prefix-cache-aware routing across replicas)

 1. Exact Gemma 4 HF model IDs: browse https://huggingface.co/google
    and confirm BOTH MODEL_ID_SMALL and MODEL_ID_LARGE in .env are
    real repos. Placeholders follow the Gemma 2/3 naming pattern.

 2. HF license: visit BOTH model pages in a browser while signed in
    as the account that owns HF_TOKEN and click "Accept license".

 3. vLLM --tool-call-parser for Gemma 4: the manifests use "hermes"
    as a placeholder. Check vLLM docs for the Gemma-4-specific parser.

 4. GKE Inference Extension release: 03-install-gateway-crds.sh is the
    source of truth for the pinned version. Check against the upstream
    release list and bump together with the BBR/EPP image tags in
    manifests/gateway/{bbr,pool-*}.yaml.
      https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases

 5. GKE rapid channel must offer 1.32.3+:
      gcloud container get-server-config --region=$REGION

 6. Security posture: the Gateway is an external LB and the agent has no
    auth. The agent Service is ClusterIP — reach it via
    \`kubectl port-forward svc/agent 8080:80\`. Do NOT run this demo in
    a shared GCP project.
==============================================================

EOF

log "Preflight OK. Next: bash scripts/01-enable-apis.sh"
