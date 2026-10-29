#!/usr/bin/env bash
# Probe the live cluster for the security properties the design relies on. Exit 1 if any check fails.
#   tests/workflow/security-checks.sh                 # RBAC, pod security, runtime hardening
#   tests/workflow/security-checks.sh --restart-node  # also restart the kind node and check the PVC data survives
# Git Bash users: export MSYS_NO_PATHCONV=1 first.
set -uo pipefail
cd "$(dirname "$0")/../.."
source versions.env

K="kubectl --context kind-$CLUSTER_NAME"
NS="$WORKFLOW_NAMESPACE"
SA="system:serviceaccount:$NS:ml-workflow"
PROBE_IMAGE=busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
fails=0

check() { # check <description> <0|1 for pass|fail>
  if [ "$2" -eq 0 ]; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi
}
can() { $K auth can-i "$@" --as="$SA" >/dev/null 2>&1; }

# --- RBAC: the workflow service account may only report task results in its own namespace.
can create workflowtaskresults.argoproj.io -n "$NS"; check "SA can create workflowtaskresults" $?
can patch workflowtaskresults.argoproj.io -n "$NS"; check "SA can patch workflowtaskresults" $?
for what in "get secrets" "list secrets" "create pods" "list pods" "get configmaps" "create workflows.argoproj.io" "delete persistentvolumeclaims"; do
  can $what -n "$NS" && r=1 || r=0; check "SA cannot: $what" $r
done
can create workflowtaskresults.argoproj.io -n default && r=1 || r=0; check "SA cannot act in another namespace" $r
can list nodes && r=1 || r=0; check "SA has no cluster-wide access" $r

# --- Pod security: the restricted level must reject root and privileged pods.
reject() { # reject <description> <securityContext json for the container> <pod-level securityContext json>
  printf '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"psa-probe","namespace":"%s"},"spec":{"securityContext":%s,"containers":[{"name":"p","image":"%s","command":["true"],"securityContext":%s}]}}' \
    "$NS" "$3" "$PROBE_IMAGE" "$2" | $K create --dry-run=server -f - >/dev/null 2>&1 && r=1 || r=0
  check "$1" $r
}
GOOD_POD='{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}'
GOOD_CTR='{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}'
printf '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"psa-ok","namespace":"%s"},"spec":{"securityContext":%s,"containers":[{"name":"p","image":"%s","command":["true"],"securityContext":%s}]}}' \
  "$NS" "$GOOD_POD" "$PROBE_IMAGE" "$GOOD_CTR" | $K create --dry-run=server -f - >/dev/null 2>&1; check "control: compliant pod is admitted" $?
reject "privileged pod is rejected" '{"privileged":true}' "$GOOD_POD"
reject "root pod is rejected" "$GOOD_CTR" '{"runAsUser":0,"seccompProfile":{"type":"RuntimeDefault"}}'
reject "privilege escalation is rejected" '{"allowPrivilegeEscalation":true,"capabilities":{"drop":["ALL"]}}' "$GOOD_POD"

# --- Runtime hardening, observed from inside a pod with the workflow's security settings.
$K -n "$NS" delete pod sec-probe --ignore-not-found --now >/dev/null 2>&1
$K -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: sec-probe}
spec:
  restartPolicy: Never
  serviceAccountName: ml-workflow
  securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: p
      image: $PROBE_IMAGE
      command: [sh, -c]
      args:
        - |
          echo "uid=\$(id -u)"
          echo "caps=\$(grep CapEff /proc/self/status | cut -f2)"
          touch /rootfs-test 2>/dev/null && echo "rootfs=writable" || echo "rootfs=readonly"
          touch /tmp/t 2>/dev/null && echo "tmp=writable" || echo "tmp=readonly"
          touch /artifacts/.probe 2>/dev/null && echo "artifacts=writable" || echo "artifacts=readonly"
          rm -f /artifacts/.probe
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: tmp, mountPath: /tmp}, {name: a, mountPath: /artifacts}]
  volumes: [{name: tmp, emptyDir: {}}, {name: a, persistentVolumeClaim: {claimName: artifacts}}]
EOF
$K -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/sec-probe --timeout=90s >/dev/null 2>&1
out=$($K -n "$NS" logs sec-probe 2>&1)
$K -n "$NS" delete pod sec-probe --now >/dev/null 2>&1
has() { echo "$out" | grep -qx "$1"; }
has "uid=65532"; check "container runs as uid 65532" $?
has "caps=0000000000000000"; check "container has no Linux capabilities" $?
has "rootfs=readonly"; check "root filesystem is read-only" $?
has "tmp=writable"; check "/tmp (emptyDir) is writable" $?
has "artifacts=writable"; check "/artifacts (PVC) is writable by the non-root user" $?

# --- Secrets hygiene: nothing secret-shaped is tracked in git.
if git ls-files | xargs grep -I -l -E '(AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|kind: Secret)' 2>/dev/null | grep -v -e '^tests/workflow/security-checks.sh$' -e '^k8s/service-account.yaml$' | grep -q .; then r=1; else r=0; fi
check "no secrets or private keys in tracked files" $r
# The one allowed Secret manifest is the empty service-account-token request (the API server fills it in).
grep -qE "^(data|stringData):" k8s/service-account.yaml && r=1 || r=0; check "the token Secret manifest carries no data" $r

# --- Network: default-deny egress except the Kubernetes API (needs a CNI that enforces policy, see create-cluster.sh).
$K -n "$NS" delete pod net-probe --ignore-not-found --now >/dev/null 2>&1
$K -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: net-probe}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: p
      image: $PROBE_IMAGE
      command: [sh, -c, "nc -z -w3 1.1.1.1 443 && echo internet=open || echo internet=blocked; nc -z -w3 10.96.0.1 443 && echo api=open || echo api=blocked"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
$K -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/net-probe --timeout=90s >/dev/null 2>&1
net=$($K -n "$NS" logs net-probe 2>&1); $K -n "$NS" delete pod net-probe --now >/dev/null 2>&1
echo "$net" | grep -q internet=blocked; check "pods cannot reach the internet" $?
echo "$net" | grep -q api=open; check "pods can still reach the Kubernetes API (Argo needs it)" $?

# --- API token: only Argo's own containers get one, not the stage container.
w=$(argo --context "kind-$CLUSTER_NAME" submit tests/workflow/smoke.yaml -n "$NS" --wait -o name 2>/dev/null | tail -1)
pod=$($K -n "$NS" get pods -l "workflows.argoproj.io/workflow=$w" -o name | head -1)
[ "$($K -n "$NS" get wf "$w" -o jsonpath='{.status.phase}')" = Succeeded ]; check "workflow without a stage API token still runs to completion" $?
mounts() { $K -n "$NS" get "$pod" -o jsonpath="{.spec.containers[?(@.name==\"$1\")].volumeMounts[*].mountPath}"; }
mounts main | grep -q serviceaccount && r=1 || r=0; check "stage (main) container has no API token mounted" $r
mounts wait | grep -q serviceaccount; check "Argo wait container has the token it needs" $?

# --- Persistence across a node restart (disruptive, opt-in).
if [ "${1:-}" = "--restart-node" ]; then
  $K -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: persist-write}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 65532, fsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: p
      image: $PROBE_IMAGE
      command: [sh, -c, "mkdir -p /artifacts/persist && date +%s > /artifacts/persist/marker && cat /artifacts/persist/marker"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: a, mountPath: /artifacts}]
  volumes: [{name: a, persistentVolumeClaim: {claimName: artifacts}}]
EOF
  $K -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/persist-write --timeout=90s >/dev/null 2>&1
  before=$($K -n "$NS" logs persist-write 2>&1); $K -n "$NS" delete pod persist-write --now >/dev/null 2>&1
  docker restart "$CLUSTER_NAME-control-plane" >/dev/null
  for _ in $(seq 1 60); do $K get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 5; done
  $K -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: persist-read}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 65532, fsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: p
      image: $PROBE_IMAGE
      command: [sh, -c, "cat /artifacts/persist/marker; ls /artifacts/registry"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: a, mountPath: /artifacts}]
  volumes: [{name: a, persistentVolumeClaim: {claimName: artifacts}}]
EOF
  $K -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/persist-read --timeout=180s >/dev/null 2>&1
  after=$($K -n "$NS" logs persist-read 2>&1 | head -1); $K -n "$NS" delete pod persist-read --now >/dev/null 2>&1
  [ -n "$before" ] && [ "$before" = "$after" ]; check "PVC data survives a node restart" $?
fi

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) FAILED"
[ "$fails" -eq 0 ]
