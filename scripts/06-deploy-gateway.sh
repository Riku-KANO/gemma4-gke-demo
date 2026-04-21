#!/usr/bin/env bash
# Deploy the full Inference Gateway stack:
#   - Gateway
#   - BBR (body-based router) + GCPRoutingExtension
#   - Two per-pool bundles: EPP + InferencePool + HTTPRoute + GCP policies
#   - Two InferenceObjectives (priority hints per pool)
#
# The per-pool bundles contain an HTTPRoute whose header match pins a
# concrete model ID. We patch __MODEL_ID_SMALL__ / __MODEL_ID_LARGE__ from
# .env at apply time so the manifests stay declarative.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

tmp_small="$(mktemp)"
tmp_large="$(mktemp)"
trap 'rm -f "$tmp_small" "$tmp_large"' EXIT

log "Rendering pool-small with X-Gateway-Base-Model-Name=$MODEL_ID_SMALL..."
sed "s|__MODEL_ID_SMALL__|${MODEL_ID_SMALL}|g" \
  "$ROOT_DIR/manifests/gateway/pool-small.yaml" > "$tmp_small"

log "Rendering pool-large with X-Gateway-Base-Model-Name=$MODEL_ID_LARGE..."
sed "s|__MODEL_ID_LARGE__|${MODEL_ID_LARGE}|g" \
  "$ROOT_DIR/manifests/gateway/pool-large.yaml" > "$tmp_large"

log "Applying Gateway..."
kubectl apply -f "$ROOT_DIR/manifests/gateway/gateway.yaml"

log "Applying BBR (body-based router) + GCPRoutingExtension..."
kubectl apply -f "$ROOT_DIR/manifests/gateway/bbr.yaml"

log "Applying per-pool bundles (EPP + InferencePool + HTTPRoute + policies)..."
kubectl apply -f "$tmp_small"
kubectl apply -f "$tmp_large"

log "Applying InferenceObjectives (priority hints)..."
kubectl apply -f "$ROOT_DIR/manifests/gateway/inferenceobjective-small.yaml"
kubectl apply -f "$ROOT_DIR/manifests/gateway/inferenceobjective-large.yaml"

log "Waiting for Gateway IP (up to 5 min)..."
for _ in $(seq 1 30); do
  ip="$(kubectl get gateway inference-gw \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  [[ -n "$ip" ]] && break
  sleep 10
done

if [[ -z "${ip:-}" ]]; then
  warn "Gateway IP not yet assigned. Check: kubectl describe gateway inference-gw"
  exit 0
fi

log "Gateway IP: $ip"
log "Quick probe (small) — sends model=$MODEL_ID_SMALL; BBR should inject the header:"
curl -fsS -m 30 -X POST "http://${ip}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg m "$MODEL_ID_SMALL" '{model:$m,messages:[{role:"user",content:"ok?"}],max_tokens:8}')" \
  | jq '.choices[0].message.content' 2>/dev/null \
  || warn "Small-model probe failed — pool may still be warming up (EPP readiness or model download)."

log "Next: bash scripts/07-build-agent.sh"
