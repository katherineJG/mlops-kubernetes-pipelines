#!/usr/bin/env bash
# Delete the kind cluster. This also destroys the artifact PVC and everything on it.
set -euo pipefail
cd "$(dirname "$0")/.."
source versions.env

kind delete cluster --name "$CLUSTER_NAME"
