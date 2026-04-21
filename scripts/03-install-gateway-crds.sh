#!/usr/bin/env bash
# Install Gateway API + Inference Extension CRDs (InferencePool v1,
# InferenceObjective v1alpha2).
#
# NOTE: GKE 1.34.0-gke.1626000+ manages InferencePool v1 automatically. We
# still apply the upstream manifests so InferenceObjective (alpha, not yet
# GKE-managed) is available and we stay idempotent on earlier GKE versions.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

GATEWAY_API_VERSION="v1.3.0"
INFERENCE_EXT_VERSION="v1.5.0"

log "Installing upstream Gateway API $GATEWAY_API_VERSION..."
kubectl apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

log "Installing Gateway API Inference Extension $INFERENCE_EXT_VERSION CRDs..."
log "(verify tag at https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases)"
# manifests.yaml ships InferencePool v1 + the x-k8s.io alpha resources
# (InferenceObjective, InferenceModelRewrite, InferencePoolImport).
kubectl apply -f \
  "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${INFERENCE_EXT_VERSION}/manifests.yaml"

log "Waiting for core CRDs to be Established..."
kubectl wait --for=condition=Established --timeout=120s \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io \
  crd/inferencepools.inference.networking.k8s.io \
  crd/inferenceobjectives.inference.networking.x-k8s.io

log "CRD summary:"
kubectl get crd | grep -E "gateway.networking|inference.networking" || true

log "Done. Next: bash scripts/04-create-secrets.sh"
