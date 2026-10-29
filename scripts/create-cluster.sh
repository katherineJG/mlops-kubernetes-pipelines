#!/usr/bin/env bash
# Create the local kind cluster. Run from Git Bash or WSL with Docker Desktop running.
set -euo pipefail
cd "$(dirname "$0")/.."
source versions.env

command -v kind >/dev/null || { echo "kind not found (want $KIND_VERSION)"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon is not running"; exit 1; }
[ -n "$KIND_NODE_IMAGE" ] || { echo "KIND_NODE_IMAGE unset in versions.env"; exit 1; }

if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "cluster $CLUSTER_NAME already exists"; exit 0
fi
kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" --config k8s/kind-config.yaml

# kind's default CNI ignores NetworkPolicy, so use Calico (pinned version, manifest checksum verified).
manifest=$(mktemp)
curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml" > "$manifest"
[ "$(sha256sum < "$manifest" | cut -d" " -f1)" = "$CALICO_MANIFEST_SHA256" ] || { echo "Calico manifest checksum mismatch"; exit 1; }
kubectl --context "kind-$CLUSTER_NAME" apply --server-side -f - < "$manifest" >/dev/null
kubectl --context "kind-$CLUSTER_NAME" wait --for=condition=Ready node --all --timeout=300s
kubectl --context "kind-$CLUSTER_NAME" apply -f k8s/namespace.yaml -f k8s/service-account.yaml -f k8s/artifact-pvc.yaml -f k8s/network-policy.yaml
