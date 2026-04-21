#!/usr/bin/env bash
# Deploy both Gemma models (small orchestrator + large expert). Model IDs
# and replica counts are patched into the manifests at apply time so the
# canonical source of truth is .env, not the YAML.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

tmp_small="$(mktemp)"
tmp_large="$(mktemp)"
trap 'rm -f "$tmp_small" "$tmp_large"' EXIT

log "Rendering small deployment (model=$MODEL_ID_SMALL)..."
sed "s|__MODEL_ID_SMALL__|${MODEL_ID_SMALL}|g" \
  "$ROOT_DIR/manifests/gemma/deployment-small.yaml" > "$tmp_small"

log "Rendering large deployment (model=$MODEL_ID_LARGE, replicas=$LARGE_REPLICAS)..."
sed -e "s|__MODEL_ID_LARGE__|${MODEL_ID_LARGE}|g" \
    -e "s|replicas: 2|replicas: ${LARGE_REPLICAS}|g" \
  "$ROOT_DIR/manifests/gemma/deployment-large.yaml" > "$tmp_large"

kubectl apply -f "$tmp_small"
kubectl apply -f "$tmp_large"
kubectl apply -f "$ROOT_DIR/manifests/gemma/service-small.yaml"
kubectl apply -f "$ROOT_DIR/manifests/gemma/service-large.yaml"

log "Deployments applied. First-time model downloads can take 10-20 min each."
log "Follow progress:"
log "  kubectl logs -l app=gemma-small -f      # small / orchestrator"
log "  kubectl logs -l app=gemma-large -f      # large / expert (2+ pods)"
log ""
log "When both Deployments report Available, proceed:"
log "  bash scripts/06-deploy-gateway.sh"
