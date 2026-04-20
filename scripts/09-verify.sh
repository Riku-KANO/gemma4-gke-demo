#!/usr/bin/env bash
# Two-stage end-to-end verification:
#   1. Call Gemma directly via the Inference Gateway (OpenAI-compatible API)
#   2. Call the ADK agent and confirm it issues tool calls

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

log "=== Stage 1: Gemma via Inference Gateway ==="
gw_ip="$(kubectl get gateway inference-gw \
          -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
[[ -n "$gw_ip" ]] || die "Gateway IP not assigned."
log "Gateway: http://$gw_ip"

curl -fsS -X POST "http://${gw_ip}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg m "$MODEL_ID" '{
        model: $m,
        messages: [{role:"user", content:"Say hi in 5 words"}],
        max_tokens: 32
      }')" \
  | jq '.choices[0].message.content'

log "=== Stage 2: ADK agent (tool calling) ==="
lb_ip="$(kubectl get svc agent \
         -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
[[ -n "$lb_ip" ]] || die "Agent LoadBalancer IP not assigned."
log "Agent: http://$lb_ip"

log "Creating session..."
curl -fsS -X POST "http://${lb_ip}/apps/gemma_demo_agent/users/u1/sessions/s1" \
  -H "Content-Type: application/json" \
  -d '{}' | jq . || true

log "Running agent prompt..."
curl -fsS -X POST "http://${lb_ip}/run" \
  -H "Content-Type: application/json" \
  -d '{
    "app_name": "gemma_demo_agent",
    "user_id": "u1",
    "session_id": "s1",
    "new_message": {
      "role": "user",
      "parts": [{"text": "What time is it right now, and what is 17*23?"}]
    }
  }' | jq .

log ""
log "Expected: events show functionCall for get_current_time and calculator,"
log "followed by a final text response combining both answers."
