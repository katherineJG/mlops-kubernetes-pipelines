#!/usr/bin/env bash
# Submit real workflow runs for the success and failure scenarios and assert what happened.
# Needs the kind cluster, Argo, and the stage image loaded (see docs/OPERATIONS.md). Takes ~5 minutes.
set -uo pipefail
export MSYS_NO_PATHCONV=1  # Git Bash would otherwise rewrite /artifacts/... arguments
cd "$(dirname "$0")/../.."
source versions.env

CTX="kind-$CLUSTER_NAME"
NS="$WORKFLOW_NAMESPACE"
K="kubectl --context $CTX -n $NS"
WF=workflows/training-workflow.yaml
fails=0

check() { # check <description> <0 pass | non-zero fail>
  if [ "$2" -eq 0 ]; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi
}

# Run a shell snippet on the artifacts PVC (read-only use) and print its output.
pvc_sh() {
  $K delete pod scen-pvc --ignore-not-found --now >/dev/null 2>&1
  $K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: scen-pvc}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 65532, fsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: p
      image: busybox:1.37.0
      command: [sh, -c]
      args: ["$1"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: a, mountPath: /artifacts}]
  volumes: [{name: a, persistentVolumeClaim: {claimName: artifacts}}]
EOF
  $K wait --for=jsonpath='{.status.phase}'=Succeeded pod/scen-pvc --timeout=90s >/dev/null 2>&1
  $K logs scen-pvc 2>&1
  $K delete pod scen-pvc --now >/dev/null 2>&1
}

registry_state() { pvc_sh 'sha256sum /artifacts/registry/current.json 2>&1; ls /artifacts/registry/models 2>&1'; }

# Create the fixtures the failure scenarios need, using the stage image (has Project 01 code + PyYAML).
make_fixtures() {
  $K delete pod scen-fixtures --ignore-not-found --now >/dev/null 2>&1
  $K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: scen-fixtures}
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
          from churn_pipeline.ingest import generate_synthetic
          d = pathlib.Path('/artifacts/fixtures'); d.mkdir(parents=True, exist_ok=True)
          df = generate_synthetic(5000, 42); df.loc[:4, 'contract'] = 'weekly'
          df.to_csv(d / 'bad.csv', index=False, lineterminator='\n')
          c = yaml.safe_load(open('/app/configs/data.yaml'))
          c.update(source='csv', csv_path='/artifacts/fixtures/bad.csv')
          yaml.safe_dump(c, open(d / 'bad-data.yaml', 'w'))
          m = yaml.safe_load(open('/app/configs/model.yaml')); m['gates']['min_roc_auc'] = 0.999
          yaml.safe_dump(m, open(d / 'strict-model.yaml', 'w'))
          print('fixtures ok')
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: a, mountPath: /artifacts}, {name: t, mountPath: /tmp}]
  volumes: [{name: a, persistentVolumeClaim: {claimName: artifacts}}, {name: t, emptyDir: {}}]
EOF
  $K wait --for=jsonpath='{.status.phase}'=Succeeded pod/scen-fixtures --timeout=120s >/dev/null 2>&1
  out=$($K logs scen-fixtures 2>&1); $K delete pod scen-fixtures --now >/dev/null 2>&1
  [ "$out" = "fixtures ok" ]
}

# submit <args...>: run the workflow to completion and echo its name.
submit() {
  argo --context "$CTX" submit "$WF" -n "$NS" --wait -o name "$@" 2>/dev/null | tail -1
}

# Pod attempts for a stage, as "phase:exitcode" per attempt, e.g. "Failed:10" or "Failed:1 Failed:1 Failed:1".
attempts() { # attempts <workflow> <stage>
  $K get wf "$1" -o jsonpath='{range .status.nodes.*}{.type}{"|"}{.templateName}{"|"}{.phase}{":"}{.outputs.exitCode}{"\n"}{end}' \
    | awk -F'|' -v s="$2" '$1=="Pod" && $2==s {printf "%s ", $3}' | sed 's/ $//'
}
count() { # count <words>
  [ -z "$1" ] && echo 0 || echo "$1" | wc -w | tr -d ' '
}
no_promotion() { # no_promotion <workflow> <registry state before>
  [ "$(registry_state)" = "$2" ] && ! echo "$(registry_state)" | grep -q "$1"
}

echo "== setup"
make_fixtures; check "fixtures created on the PVC" $?

echo "== scenario 0: success"
w=$(submit -p source-revision=scenario-success)
phase=$($K get wf "$w" -o jsonpath='{.status.phase}')
[ "$phase" = "Succeeded" ]; check "workflow succeeds ($w)" $?
for s in ingest validate train evaluate promote; do
  [ "$(attempts "$w" $s)" = "Succeeded:0" ]; check "  $s ran once and exited 0" $?
done
pvc_sh "cat /artifacts/registry/current.json" | grep -q "\"run_id\": \"$w\""; check "registry points at this run" $?
good=$(registry_state)

echo "== scenario 1: invalid data (deterministic, exit 10)"
w=$(submit -p data-config=/artifacts/fixtures/bad-data.yaml)
[ "$($K get wf "$w" -o jsonpath='{.status.phase}')" = "Failed" ]; check "workflow fails ($w)" $?
[ "$(attempts "$w" validate)" = "Failed:10" ]; check "  validate exited 10 and was not retried" $?
for s in train evaluate promote; do [ "$(count "$(attempts "$w" $s)")" = 0 ]; check "  $s never started" $?; done
no_promotion "$w" "$good"; check "  registry unchanged, no promoted model" $?

echo "== scenario 2: failed training (unexpected error, exit 1, retried)"
w=$(submit -p model-config=/artifacts/fixtures/does-not-exist.yaml)
[ "$($K get wf "$w" -o jsonpath='{.status.phase}')" = "Failed" ]; check "workflow fails ($w)" $?
[ "$(attempts "$w" train)" = "Failed:1 Failed:1 Failed:1" ]; check "  train ran 3 times (1 + 2 retries), all exit 1" $?
for s in evaluate promote; do [ "$(count "$(attempts "$w" $s)")" = 0 ]; check "  $s never started" $?; done
no_promotion "$w" "$good"; check "  registry unchanged, no promoted model" $?

echo "== scenario 3: failed evaluation gate (deterministic, exit 20)"
w=$(submit -p model-config=/artifacts/fixtures/strict-model.yaml)
[ "$($K get wf "$w" -o jsonpath='{.status.phase}')" = "Failed" ]; check "workflow fails ($w)" $?
[ "$(attempts "$w" evaluate)" = "Failed:20" ]; check "  evaluate exited 20 and was not retried" $?
[ "$(count "$(attempts "$w" promote)")" = 0 ]; check "  promote never started" $?
pvc_sh "cat /artifacts/runs/$w/gate.json" | grep -q '"passed": false'; check "  gate.json records the failure" $?
no_promotion "$w" "$good"; check "  registry unchanged, no promoted model" $?

echo "== scenario 4: timeout (train limited to 1 s)"
w=$(submit -p train-timeout=1)
[ "$($K get wf "$w" -o jsonpath='{.status.phase}')" = "Failed" ]; check "workflow fails ($w)" $?
echo "  train attempts observed: [$(attempts "$w" train)]"
$K get wf "$w" -o jsonpath='{range .status.nodes.*}{.templateName}{": "}{.message}{"\n"}{end}' | grep -i -E 'deadline|train' | sed 's/^/  /' | head -3
t=$(attempts "$w" train)
[ -n "$t" ] && ! echo "$t" | grep -q Succeeded; check "  train never succeeded" $?
for s in evaluate promote; do [ "$(count "$(attempts "$w" $s)")" = 0 ]; check "  $s never started" $?; done
no_promotion "$w" "$good"; check "  registry unchanged, no promoted model" $?

echo "== scenario 5: missing upstream artifact (deterministic, exit 30)"
# evaluate on its own: the run directory is new, so train.json does not exist
w=$(submit --entrypoint evaluate)
[ "$($K get wf "$w" -o jsonpath='{.status.phase}')" = "Failed" ]; check "workflow fails ($w)" $?
[ "$(attempts "$w" evaluate)" = "Failed:30" ]; check "  evaluate exited 30 and was not retried" $?
no_promotion "$w" "$good"; check "  registry unchanged, no promoted model" $?

echo
[ "$fails" -eq 0 ] && echo "all scenarios passed" || echo "$fails check(s) FAILED"
[ "$fails" -eq 0 ]
