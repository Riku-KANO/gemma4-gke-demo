#!/usr/bin/env bash
# Preflight sanity checks and a checklist of things the user must verify
# manually before running the rest of the scripts.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

log "Checking required CLIs..."
for bin in gcloud kubectl docker jq; do
  command -v "$bin" >/dev/null 2>&1 || die "Missing required CLI: $bin"
done

log "Checking gcloud auth..."
gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q '@' \
  || die "No active gcloud account. Run: gcloud auth login"

log "Checking gcloud project..."
current_project="$(gcloud config get-value project 2>/dev/null || true)"
if [[ "$current_project" != "$PROJECT_ID" ]]; then
  warn "gcloud config project is '$current_project' but .env PROJECT_ID is '$PROJECT_ID'."
  warn "Setting gcloud project to '$PROJECT_ID'."
  gcloud config set project "$PROJECT_ID"
fi

log "Checking HF_TOKEN..."
if [[ -z "${HF_TOKEN:-}" || "$HF_TOKEN" == "hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ]]; then
  die "HF_TOKEN is not set in .env (still the placeholder)."
fi

log "Checking L4 GPU quota in $REGION..."
quota_json="$(gcloud compute regions describe "$REGION" --format=json 2>/dev/null || echo '{}')"
l4_limit=$(echo "$quota_json" | jq '[.quotas[] | select(.metric=="NVIDIA_L4_GPUS")] | .[0].limit // 0')
if [[ "$l4_limit" == "0" ]]; then
  warn "NVIDIA_L4_GPUS quota in $REGION is 0."
  warn "Request quota at https://console.cloud.google.com/iam-admin/quotas"
  warn "or switch REGION in .env to us-central1 (usually has capacity)."
fi

cat <<'EOF'

==============================================================
 Manual verification checklist (the scripts cannot check these)
==============================================================
 1. Exact Gemma 4 HF model ID: browse https://huggingface.co/google
    and confirm MODEL_ID in .env (and manifests/gemma/deployment.yaml
    and manifests/gateway/inferencemodel.yaml) is a real repo.

 2. HF license: visit the model page in a browser while signed in
    as the account that owns HF_TOKEN and click "Accept license".

 3. vLLM --tool-call-parser name for Gemma 4: the manifest currently
    uses "hermes" as a placeholder. Check vLLM docs / release notes
    for the Gemma-4-specific parser or chat template.

 4. GKE Inference Extension CRD release: 03-install-gateway-crds.sh
    uses a pinned release URL. Update to the latest release from
    https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases
    if needed.

 5. GKE rapid channel must offer 1.32.3+ in your region:
      gcloud container get-server-config --region=$REGION
==============================================================

EOF

log "Preflight OK. Next: bash scripts/01-enable-apis.sh"
