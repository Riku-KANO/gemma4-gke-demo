#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

: "${HF_TOKEN:?HF_TOKEN is required in .env}"

log "Creating Kubernetes secret 'hf-secret' (overwriting if present)..."
kubectl create secret generic hf-secret \
  --from-literal=hf_api_token="$HF_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Done. Next: bash scripts/05-deploy-gemma.sh"
