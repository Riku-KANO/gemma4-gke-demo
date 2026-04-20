#!/usr/bin/env bash
# Install Gateway API CRDs and the GKE Inference Extension (InferencePool,
# InferenceModel, endpoint picker) required by GKE Inference Gateway.
#
# NOTE: GKE 1.34.0-gke.1626000+ manages InferencePool v1 automatically. Earlier
# versions require manual install. We apply both to be safe — apply is
# idempotent and GKE-managed CRDs will reconcile.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

GATEWAY_API_VERSION="v1.2.0"
INFERENCE_EXT_VERSION="v0.3.0"

log "Installing upstream Gateway API $GATEWAY_API_VERSION..."
kubectl apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

log "Installing Gateway API Inference Extension $INFERENCE_EXT_VERSION CRDs..."
log "(verify the tag at https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases)"
kubectl apply -f \
  "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${INFERENCE_EXT_VERSION}/manifests.yaml" \
  || warn "Inference extension manifest apply failed. GKE may already manage these CRDs — check: kubectl get crd inferencepools.inference.networking.gke.io"

log "Waiting for core CRDs to be Established..."
kubectl wait --for=condition=Established --timeout=120s \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io

log "CRD summary:"
kubectl get crd | grep -E "gateway.networking|inference.networking" || true

log "Done. Next: bash scripts/04-create-secrets.sh"
