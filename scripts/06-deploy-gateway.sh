#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

tmp_model="$(mktemp)"
trap 'rm -f "$tmp_model"' EXIT

log "Rendering InferenceModel with MODEL_ID=$MODEL_ID..."
sed "s|google/gemma-4-4b-it|${MODEL_ID}|g" \
  "$ROOT_DIR/manifests/gateway/inferencemodel.yaml" > "$tmp_model"

log "Applying Inference Gateway resources..."
kubectl apply -f "$ROOT_DIR/manifests/gateway/inferencepool.yaml"
kubectl apply -f "$tmp_model"
kubectl apply -f "$ROOT_DIR/manifests/gateway/gateway.yaml"
kubectl apply -f "$ROOT_DIR/manifests/gateway/httproute.yaml"

log "Waiting for Gateway IP (up to 5 min)..."
for _ in $(seq 1 30); do
  ip="$(kubectl get gateway inference-gw \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  if [[ -n "$ip" ]]; then
    break
  fi
  sleep 10
done

if [[ -z "${ip:-}" ]]; then
  warn "Gateway IP not yet assigned. Check: kubectl describe gateway inference-gw"
  exit 0
fi

log "Gateway IP: $ip"
log "Next: bash scripts/07-build-agent.sh"
