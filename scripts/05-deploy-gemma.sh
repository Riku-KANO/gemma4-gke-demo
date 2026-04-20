#!/usr/bin/env bash
# Deploy the Gemma vLLM server. The MODEL_ID from .env is patched into the
# manifest at apply time so the repo default and your chosen model stay in sync.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

tmp_deploy="$(mktemp)"
trap 'rm -f "$tmp_deploy"' EXIT

log "Rendering gemma Deployment with MODEL_ID=$MODEL_ID..."
sed "s|google/gemma-4-4b-it|${MODEL_ID}|g" \
  "$ROOT_DIR/manifests/gemma/deployment.yaml" > "$tmp_deploy"

kubectl apply -f "$tmp_deploy"
kubectl apply -f "$ROOT_DIR/manifests/gemma/service.yaml"

log "Waiting for gemma-vllm pod to be scheduled..."
kubectl wait --for=condition=PodScheduled --timeout=120s \
  pod -l app=gemma-vllm || true

log "Deployment applied. First-time model download can take 10-20 minutes."
log "Follow progress with:"
log "  kubectl logs -l app=gemma-vllm -f"
log ""
log "When ready, proceed: bash scripts/06-deploy-gateway.sh"
