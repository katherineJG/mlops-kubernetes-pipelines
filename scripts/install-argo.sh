#!/usr/bin/env bash
# Install Argo Workflows into the kind cluster with Helm, using the pinned chart version.
set -euo pipefail
cd "$(dirname "$0")/.."
source versions.env

command -v helm >/dev/null || { echo "helm not found"; exit 1; }
[ -n "$ARGO_CHART_VERSION" ] || { echo "ARGO_CHART_VERSION unset in versions.env; pin it first"; exit 1; }

ctx="kind-$CLUSTER_NAME"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update argo >/dev/null
helm upgrade --install argo-workflows argo/argo-workflows \
  --kube-context "$ctx" --namespace "$ARGO_NAMESPACE" --create-namespace \
  --version "$ARGO_CHART_VERSION" \
  -f helm/values.yaml \
  --wait --timeout 5m
