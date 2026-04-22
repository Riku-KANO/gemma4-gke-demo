#!/usr/bin/env bash
# Deploy the ADK agent. The image ref, Gateway URL, and both model IDs are
# rendered into the manifest at apply time.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

log "Looking up Gateway address..."
gw_ip="$(kubectl get gateway inference-gw \
          -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
[[ -n "$gw_ip" ]] || die "Gateway IP not yet assigned. Run 06-deploy-gateway.sh and wait."

gateway_url="http://${gw_ip}/v1"
log "Using GATEWAY_URL=$gateway_url"
log "Using MODEL_ID_SMALL=$MODEL_ID_SMALL"
log "Using MODEL_ID_LARGE=$MODEL_ID_LARGE"
log "Using agent image=$AGENT_IMAGE"

tmp_deploy="$(mktemp)"
trap 'rm -f "$tmp_deploy"' EXIT

sed -e "s|__AGENT_IMAGE__|${AGENT_IMAGE}|g" \
    -e "s|__GATEWAY_URL__|${gateway_url}|g" \
    -e "s|__MODEL_ID_SMALL__|${MODEL_ID_SMALL}|g" \
    -e "s|__MODEL_ID_LARGE__|${MODEL_ID_LARGE}|g" \
    "$ROOT_DIR/manifests/agent/deployment.yaml" > "$tmp_deploy"

kubectl apply -f "$tmp_deploy"
kubectl apply -f "$ROOT_DIR/manifests/agent/service.yaml"

log "Waiting for agent rollout..."
kubectl rollout status deployment/agent --timeout=300s

log "Agent is exposed as ClusterIP (on purpose — no auth)."
log "To reach it from your workstation:"
log "  kubectl port-forward svc/agent 8080:80"
log "Next: bash scripts/09-verify.sh (starts a port-forward for you)"
