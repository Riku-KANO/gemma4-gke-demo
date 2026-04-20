#!/usr/bin/env bash
# Deploy the ADK agent. We render the image ref and Gateway URL into the
# deployment manifest at apply time so the templates stay declarative while
# still reflecting real cluster state.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

log "Looking up Gateway address..."
gw_ip="$(kubectl get gateway inference-gw \
          -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
[[ -n "$gw_ip" ]] || die "Gateway IP not yet assigned. Run 06-deploy-gateway.sh and wait."

gateway_url="http://${gw_ip}/v1"
log "Using GATEWAY_URL=$gateway_url"
log "Using agent image=$AGENT_IMAGE"

tmp_deploy="$(mktemp)"
trap 'rm -f "$tmp_deploy"' EXIT

sed -e "s|__AGENT_IMAGE__|${AGENT_IMAGE}|g" \
    -e "s|__GATEWAY_URL__|${gateway_url}|g" \
    -e "s|google/gemma-4-4b-it|${MODEL_ID}|g" \
    "$ROOT_DIR/manifests/agent/deployment.yaml" > "$tmp_deploy"

kubectl apply -f "$tmp_deploy"
kubectl apply -f "$ROOT_DIR/manifests/agent/service.yaml"

log "Waiting for agent rollout..."
kubectl rollout status deployment/agent --timeout=300s

log "Waiting for LoadBalancer IP..."
for _ in $(seq 1 30); do
  lb_ip="$(kubectl get svc agent \
           -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$lb_ip" ]] && break
  sleep 10
done

if [[ -z "${lb_ip:-}" ]]; then
  warn "Agent LoadBalancer IP not yet ready. Check: kubectl get svc agent"
else
  log "Agent LoadBalancer IP: $lb_ip"
fi

log "Next: bash scripts/09-verify.sh"
