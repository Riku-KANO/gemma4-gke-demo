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
log ""
log "Per-pod prefix-cache metrics (the concentration should be visible in"
log "vllm:prefix_cache_queries / vllm:prefix_cache_hits — one pod should have"
log "a noticeably higher hit ratio than the others):"

# Non-interactive exec, one pod at a time, so we can see per-replica counters.
while IFS= read -r pod; do
  [[ -n "$pod" ]] || continue
  log ""
  log "  --- $pod ---"
  kubectl exec "$pod" -c vllm -- \
    sh -c "curl -s localhost:8000/metrics | grep -E '^vllm:(prefix_cache|num_requests)' || true"
done < <(kubectl get pods -l app=gemma-large -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')

hr "Stage 3/3: ADK agent with tool calling + expert escalation"

# Agent Service is ClusterIP (no auth → not publicly exposed). Forward a
# local port for this stage, then tear it down on exit.
log "Starting kubectl port-forward svc/agent 18080:80 in the background..."
kubectl port-forward svc/agent 18080:80 >/dev/null 2>&1 &
pf_pid=$!
trap 'kill $pf_pid 2>/dev/null || true' EXIT

# Wait until the forwarder is accepting connections.
for _ in $(seq 1 20); do
  if curl -fsS -o /dev/null -m 1 "http://127.0.0.1:18080/list-apps"; then
    break
  fi
  sleep 1
done
agent_url="http://127.0.0.1:18080"
log "Agent: $agent_url (via port-forward)"

log "Creating session..."
curl -fsS -X POST "${agent_url}/apps/gemma_demo_agent/users/u1/sessions/s1" \
  -H "Content-Type: application/json" -d '{}' >/dev/null || true

log "Easy question → small model should answer directly via tools:"
curl -fsS -X POST "${agent_url}/run" \
  -H "Content-Type: application/json" \
  -d '{
    "app_name":"gemma_demo_agent","user_id":"u1","session_id":"s1",
    "new_message":{"role":"user","parts":[{"text":"What time is it, and what is 17*23?"}]}}' \
  | jq '[.[] | {author, tool: (.content.parts[]?.functionCall.name // empty)}] | unique'

log "Hard question → small model should call consult_expert (→ large model):"
curl -fsS -X POST "${agent_url}/run" \
  -H "Content-Type: application/json" \
  -d '{
    "app_name":"gemma_demo_agent","user_id":"u1","session_id":"s1",
    "new_message":{"role":"user","parts":[{"text":"Explain in 4 steps why merge sort is O(n log n)."}]}}' \
  | jq '[.[] | {author, tool: (.content.parts[]?.functionCall.name // empty)}] | unique'

log ""
log "Expected tools observed (in some order):"
log "  Stage 3a: get_current_time, calculator"
log "  Stage 3b: consult_expert"
