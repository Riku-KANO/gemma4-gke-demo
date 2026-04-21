#!/usr/bin/env bash
# Three-stage end-to-end verification:
#   1. Multi-model routing via the Inference Gateway — one endpoint,
#      two models dispatched by the body's "model" field.
#   2. Prefix-cache-aware routing across the two large-model replicas —
#      repeated requests sharing a long prefix land on the same pod.
#   3. ADK agent orchestration — small model picks tools, escalates hard
#      questions to the large model via consult_expert.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

gw_ip="$(kubectl get gateway inference-gw \
          -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
[[ -n "$gw_ip" ]] || die "Gateway IP not assigned."
log "Gateway: http://$gw_ip"

hr() { printf '\n\033[1;35m%s\033[0m\n' "==================== $* ===================="; }

hr "Stage 1/3: Multi-model routing (Inference Gateway feature B)"

log "Request to SMALL model ($MODEL_ID_SMALL):"
curl -fsS -X POST "http://${gw_ip}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg m "$MODEL_ID_SMALL" '{
        model:$m, max_tokens:32,
        messages:[{role:"user",content:"Reply with exactly: SMALL"}]}')" \
  | jq '{model, served_by: .choices[0].message.content}'

log "Request to LARGE model ($MODEL_ID_LARGE):"
curl -fsS -X POST "http://${gw_ip}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg m "$MODEL_ID_LARGE" '{
        model:$m, max_tokens:32,
        messages:[{role:"user",content:"Reply with exactly: LARGE"}]}')" \
  | jq '{model, served_by: .choices[0].message.content}'

log "Both responses should echo the model requested — one Gateway, two pools."

hr "Stage 2/3: Prefix-cache-aware routing (Inference Gateway feature A)"

log "Sending 4 LARGE-model requests sharing a long shared prefix."
log "Prefix-cache-aware routing should pin them to the same replica."
log "Watch vLLM prefix-cache hits: kubectl logs -l app=gemma-large --tail=-1 | grep -i cache"

SHARED_PREFIX=$(printf 'You are a helpful assistant. The following is a long shared system context intended to exercise prefix caching across replicas. %.0s' {1..30})

for i in 1 2 3 4; do
  log "  request #$i ..."
  curl -fsS -o /dev/null -w "    http=%{http_code}  total=%{time_total}s\n" \
    -X POST "http://${gw_ip}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$MODEL_ID_LARGE" --arg sys "$SHARED_PREFIX" --arg q "Question $i: what is 2+$i?" '{
          model:$m, max_tokens:32, temperature:0,
          messages:[{role:"system",content:$sys},{role:"user",content:$q}]}')"
done

log ""
log "Expected: requests 2-4 are faster than request 1 (prefix cache hits),"
log "and hits concentrate on one large-model pod, not both."
log "Inspect:"
log "  kubectl exec -it deploy/gemma-large -- curl -s localhost:8000/metrics \\"
log "    | grep -E 'prefix_cache|num_requests'"

hr "Stage 3/3: ADK agent with tool calling + expert escalation"

lb_ip="$(kubectl get svc agent \
         -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
[[ -n "$lb_ip" ]] || die "Agent LoadBalancer IP not assigned."
log "Agent: http://$lb_ip"

log "Creating session..."
curl -fsS -X POST "http://${lb_ip}/apps/gemma_demo_agent/users/u1/sessions/s1" \
  -H "Content-Type: application/json" -d '{}' >/dev/null || true

log "Easy question → small model should answer directly via tools:"
curl -fsS -X POST "http://${lb_ip}/run" \
  -H "Content-Type: application/json" \
  -d '{
    "app_name":"gemma_demo_agent","user_id":"u1","session_id":"s1",
    "new_message":{"role":"user","parts":[{"text":"What time is it, and what is 17*23?"}]}}' \
  | jq '[.[] | {author, tool: (.content.parts[]?.functionCall.name // empty)}] | unique'

log "Hard question → small model should call consult_expert (→ large model):"
curl -fsS -X POST "http://${lb_ip}/run" \
  -H "Content-Type: application/json" \
  -d '{
    "app_name":"gemma_demo_agent","user_id":"u1","session_id":"s1",
    "new_message":{"role":"user","parts":[{"text":"Explain in 4 steps why merge sort is O(n log n)."}]}}' \
  | jq '[.[] | {author, tool: (.content.parts[]?.functionCall.name // empty)}] | unique'

log ""
log "Expected tools observed (in some order):"
log "  Stage 3a: get_current_time, calculator"
log "  Stage 3b: consult_expert"
