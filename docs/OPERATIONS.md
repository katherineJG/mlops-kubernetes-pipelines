# Operations (M0)

Status: cluster created and Argo installed 2026-10-29; `tests/workflow/smoke.yaml` passed (see below). Image build commands (M1) not run yet.

## Prerequisites (Windows 11)

| Tool | Version | Present at drafting? |
|---|---|---|
| Docker Desktop (WSL2 backend) | 29.9.2 | running, 16 CPUs, ~15.6 GB |
| kubectl | v1.36.1 client | yes |
| kind | v0.33.0 | installed (winget) |
| helm | v4.3.1 | installed (winget) |
| argo CLI | v4.1.6 (checksum verified) | installed to `%LOCALAPPDATA%/Programs/argo` |
| Git Bash or WSL | for `scripts/*.sh` | WSL has only the `docker-desktop` distro; use Git Bash |
| uv + Python 3.12 | for tests | uv via Project 01 `.venv`; system `python` is the Store stub |

Local resources: the host has 16 logical CPUs and about 32 GB RAM; Docker Desktop currently
gets 16 CPUs and about 15.6 GB. The kind node plus Argo should
need roughly 2 CPUs and 4 GB; measure and update in M2.

## Create

```bash
source versions.env        # fill ARGO_CHART_VERSION first
./scripts/create-cluster.sh
./scripts/install-argo.sh
```

## Build and load images (M1)

```bash
docker build -t "$BASE_IMAGE" "../Reproducible ML Training Pipeline"
docker build -f containers/Dockerfile --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$STAGE_IMAGE" .
kind load docker-image "$STAGE_IMAGE" --name "$CLUSTER_NAME"
```

## Clean up

```bash
./scripts/cleanup.sh       # deletes the cluster and the artifact PVC
```

## Version pins

All pins live in `versions.env`. Values marked there as unverified came from third-party release
mirrors and must be confirmed against the official release pages before first use.

## Verify the cluster

```bash
argo lint --offline tests/workflow/smoke.yaml
argo --context kind-mlops-k8s submit tests/workflow/smoke.yaml -n ml-workflows --wait
```

Two pods run under the restricted pod-security level; the second reads a file the first wrote to
the `artifacts` PVC. Observed on 2026-10-29: Succeeded, and the file was still readable from a new
pod after the workflow was deleted.

Notes learned during setup:
- The `ml-workflows` namespace enforces `restricted` pod security. Argo's init/wait containers
  only pass with `executor.securityContext` and the `-nonroot` image set in `helm/values.yaml`.
- In Git Bash, `kind`, `helm` and `argo` may not be on PATH until a new shell is opened.

## Run the stage tests (M1)

```bash
uv sync
uv run pytest          # 7 tests: exit codes, gating, last-known-good safety
uv run ruff check src tests
```

The same stages were also run inside the built image with `--read-only --tmpfs /tmp --cap-drop ALL
--network none`: happy path (all exit 0), corrupt data (validate exit 10), failing gate (evaluate
exit 20, promote exit 30, registry unchanged).

## Run the workflow (M2)

```bash
export MSYS_NO_PATHCONV=1        # Git Bash otherwise rewrites /artifacts/... arguments into C:/Program Files/Git/...
kind load docker-image "$STAGE_IMAGE" --name "$CLUSTER_NAME"      # about 1 minute, image is ~2.4 GB
argo lint --offline workflows/training-workflow.yaml
argo --context kind-mlops-k8s submit workflows/training-workflow.yaml -n ml-workflows \
  -p source-revision="$(git rev-parse --short HEAD)" --wait
```

Observed 2026-10-29: success run took about 50 s (each stage 4-6 s). Outputs are under
`/artifacts/runs/<workflow-name>/` and the promoted model under `/artifacts/registry/`; both
survive the pods. Re-running `load` is needed after every image rebuild, since the tag is fixed.

Forced gate failure: put a model config with an unreachable gate on the PVC (for example
`/artifacts/configs/strict.yaml` with `min_roc_auc: 0.999`) and pass
`-p model-config=/artifacts/configs/strict.yaml`. Result: `evaluate` exits 20 once, `promote` is
omitted, `registry/current.json` is byte-identical afterwards. That test config is left on the PVC.

## Security checks (M3)

```bash
export MSYS_NO_PATHCONV=1
tests/workflow/security-checks.sh                 # 21 checks, about 20 s, non-destructive
tests/workflow/security-checks.sh --restart-node  # adds a kind node restart and PVC survival check (~35 s)
```

Exits non-zero if any check fails. What each check proves is listed under Security in
`docs/ARCHITECTURE.md`. Memory limits in `workflows/training-workflow.yaml` come from measured peaks
(see the stage table there); re-measure if the dataset grows.
