# Troubleshooting

Every entry below was hit during development unless marked otherwise.

## Reading a failed run

```bash
export MSYS_NO_PATHCONV=1                       # Git Bash only, see below
argo --context kind-mlops-k8s get -n ml-workflows @latest     # step tree with exit codes
argo --context kind-mlops-k8s logs -n ml-workflows @latest    # logs of all stages
kubectl --context kind-mlops-k8s -n ml-workflows logs <pod> -c main   # one attempt
```

What the exit code means (details in `docs/ARCHITECTURE.md`):

| Exit | Meaning | What to do |
|---|---|---|
| 10 | Input data breaks the contract | Read the `validate` log: it lists each failed rule. Fix the data; retrying cannot help. |
| 20 | Candidate failed an evaluation gate | Read `runs/<run>/gate.json` and `report.md`. The registry was not touched. |
| 30 | A stage started without the upstream artifact it needs | Wiring bug. Check the DAG `depends` and the run directory. |
| 1 | Unexpected error | Read the stack trace. Retried twice automatically; if all three attempts fail the cause is probably not transient (for example a missing config file). |
| none, "longer than the specified deadline" | Stage hit its timeout | Not retried. Raise `train-timeout` or the stage's `activeDeadlineSeconds` if the data really grew. |

## Setup problems

**`kind`, `helm` or `argo` not found in Git Bash.** winget and the argo install changed PATH after
the shell started. Open a new terminal. If still missing, the binaries are under
`%LOCALAPPDATA%\Microsoft\WinGet\Packages\...` and `%LOCALAPPDATA%\Programs\argo`.

**`Docker daemon is not running`** (from `create-cluster.sh`). Start Docker Desktop and wait until
`docker info` succeeds.

**`ARGO_CHART_VERSION unset`.** `install-argo.sh` refuses to run until a chart version is pinned in
`versions.env`. Find one with `helm search repo argo/argo-workflows --versions`.

**Arguments like `/artifacts/...` arrive as `C:/Program Files/Git/artifacts/...`.** Git Bash rewrites
anything that looks like a Unix path. `export MSYS_NO_PATHCONV=1` first. The scenario script sets it
itself.

## Workflow problems

**Pod is rejected: `violates PodSecurity "restricted:latest"`, naming the `init` and `wait`
containers.** The namespace enforces `restricted`, and Argo's own containers must be told to comply.
Check that `helm/values.yaml` still sets `executor.securityContext` and `executor.image.nonroot`,
then re-run `scripts/install-argo.sh`.

**`workflowtaskresults.argoproj.io is forbidden`.** The workflow ran under the default service
account. Use `serviceAccountName: ml-workflow` (already set in the workflow files) and make sure
`k8s/service-account.yaml` is applied.

**`ErrImagePull` / `ImagePullBackOff` for `mlops-stages`.** The image only exists locally. After every
rebuild run `kind load docker-image "$STAGE_IMAGE" --name "$CLUSTER_NAME"` (about a minute).

**`argo lint` says `found nothing to lint in the specified paths`.** The file uses YAML anchors or
merge keys (`&x`, `*x`, `<<:`), which the linter silently skips. Write the YAML flat.

**A container fails with an exec/entrypoint error.** The workflow sets `command: [python, -m]` on
purpose: Argo cannot look up the entrypoint of an image that is not in a registry.

**The PVC shows `Pending`.** Normal until the first pod mounts it: kind's `standard` storage class
binds on first use.

**A run fails immediately with `train` exit 1 and `FileNotFoundError` for a config.** The
`-p model-config=` or `-p data-config=` path does not exist inside the container. Paths are resolved
in the pod, so use `/app/configs/...` (baked in) or `/artifacts/...` (on the PVC).

## Data and cleanup

**Where is my model?** `/artifacts/registry/current.json` on the PVC points at the last promoted
run. Failed runs never write there. To look inside, run a throwaway pod that mounts the `artifacts`
claim (see `tests/workflow/run-scenarios.sh`, function `pvc_sh`).

**`scripts/cleanup.sh` deleted my artifacts.** It deletes the cluster, and kind's default storage
class deletes volumes with it. Copy out `/artifacts/registry` first if you need the model.

**The cluster is slow or Docker is starved.** The whole stack needs roughly 2 CPUs and 4 GB. Check
Docker Desktop's resource settings.

## Not yet encountered (expected, unverified)

- Running on a multi-node cluster: the artifacts PVC is `ReadWriteOnce`, so pods on different nodes
  could not mount it together. The design assumes a single-node kind cluster.
