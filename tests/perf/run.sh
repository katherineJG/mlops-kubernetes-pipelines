#!/usr/bin/env bash
# Measure stage resource use on larger synthetic datasets, in the stage image, locked down like the pods.
#   tests/perf/run.sh "5000 50000 500000"                       # unconstrained: report peaks
#   MEMORY=768m CPUS=2 tests/perf/run.sh "500000"               # same run under a pod-sized limit
# An out-of-memory kill shows up as exit 137. Needs the stage image built locally.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
source versions.env

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
limits=()
[ -n "${MEMORY:-}" ] && limits+=(--memory "$MEMORY" --memory-swap "$MEMORY")
[ -n "${CPUS:-}" ] && limits+=(--cpus "$CPUS")

docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges --network none \
  --tmpfs /tmp:size=256m,uid=65532 -v "$(cd "$work" && pwd -W 2>/dev/null || pwd):/work" -v "$(pwd -W 2>/dev/null || pwd)/tests/perf:/perf:ro" \
  --user 0:0 "${limits[@]}" --entrypoint python "$STAGE_IMAGE" /perf/measure.py ${1:-5000}
