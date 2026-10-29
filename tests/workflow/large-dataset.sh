#!/usr/bin/env bash
# Run the full workflow on a larger synthetic dataset to prove the resource limits and timeouts hold.
#   tests/workflow/large-dataset.sh [rows]     # default 2000000; not part of run-scenarios.sh (slow, big)
# Needs the cluster, Argo and the loaded image. Prints stage durations and the PVC usage afterwards.
set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
source versions.env

ROWS=${1:-2000000}
CTX="kind-$CLUSTER_NAME"; NS="$WORKFLOW_NAMESPACE"; K="kubectl --context $CTX -n $NS"

$K delete pod large-cfg --ignore-not-found --now >/dev/null 2>&1
$K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: large-cfg}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 65532, fsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: p
      image: $STAGE_IMAGE
      imagePullPolicy: IfNotPresent
      command: [python, -c]
      args:
        - |
          import pathlib, yaml
          d = pathlib.Path('/artifacts/fixtures'); d.mkdir(parents=True, exist_ok=True)
          c = yaml.safe_load(open('/app/configs/data.yaml')); c['n_rows'] = $ROWS
          yaml.safe_dump(c, open(d / 'large-data.yaml', 'w'))
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: a, mountPath: /artifacts}, {name: t, mountPath: /tmp}]
  volumes: [{name: a, persistentVolumeClaim: {claimName: artifacts}}, {name: t, emptyDir: {}}]
EOF
$K wait --for=jsonpath='{.status.phase}'=Succeeded pod/large-cfg --timeout=120s >/dev/null 2>&1 || { echo "FAIL  could not write the config"; exit 1; }
$K delete pod large-cfg --now >/dev/null 2>&1

w=$(argo --context "$CTX" submit workflows/training-workflow.yaml -n "$NS" --wait -o name \
  -p data-config=/artifacts/fixtures/large-data.yaml -p source-revision="large-$ROWS" 2>/dev/null | tail -1)
phase=$($K get wf "$w" -o jsonpath='{.status.phase}')
echo "$w: $phase ($ROWS rows)"
$K get wf "$w" -o jsonpath='{range .status.nodes.*}{.type}|{.templateName}|{.phase}|{.outputs.exitCode}|{.startedAt}|{.finishedAt}{"\n"}{end}' \
  | awk -F'|' '$1=="Pod" {print "  " $2 ": " $3 " exit " $4 " (" $5 " -> " $6 ")"}'
$K get wf "$w" -o jsonpath='{range .status.nodes.*}{.message}{"\n"}{end}' | grep -i oom
[ "$phase" = "Succeeded" ] && echo "PASS  $ROWS rows within the configured limits" || { echo "FAIL"; exit 1; }
