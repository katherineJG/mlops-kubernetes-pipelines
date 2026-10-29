# Operations

Status: verified locally on 2026-10-29: cluster creation, Argo install, image build and load, the workflow, the security checks and the failure scenarios. The GitHub Actions workflow also passes on GitHub, including the cluster job.

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
need roughly 2 CPUs and 4 GB; estimated, not measured.

## Create

```bash
source versions.env        # fill ARGO_CHART_VERSION first
./scripts/create-cluster.sh
./scripts/install-argo.sh
```

`create-cluster.sh` replaces kind's default network layer with Calico (`CALICO_VERSION` in `versions.env`; the manifest is fetched from GitHub and checked against `CALICO_MANIFEST_SHA256`), so it needs internet access and takes about a minute longer. Calico is what makes the default-deny `NetworkPolicy` apply.

## Build and load images

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

## Run the stage tests

```bash
uv sync
uv run pytest          # 7 tests: exit codes, gating, last-known-good safety
uv run ruff check src tests
```

The same stages were also run inside the built image with `--read-only --tmpfs /tmp --cap-drop ALL
--network none`: happy path (all exit 0), corrupt data (validate exit 10), failing gate (evaluate
exit 20, promote exit 30, registry unchanged).

## Run the workflow

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

## Security checks

```bash
export MSYS_NO_PATHCONV=1
tests/workflow/security-checks.sh                 # 28 checks, about 1 min, non-destructive
tests/workflow/security-checks.sh --restart-node  # adds a kind node restart and PVC survival check (~35 s)
```

Exits non-zero if any check fails. What each check proves is listed under Security in
`docs/ARCHITECTURE.md`. Memory limits in `workflows/training-workflow.yaml` come from measured peaks
(see the stage table there); re-measure if the dataset grows.

## Failure scenarios

```bash
tests/workflow/run-scenarios.sh      # about 4 minutes; needs cluster, Argo and the loaded image
```

Runs the success path and five failures (invalid data, failed training, failed gate, timeout, missing upstream artifact) and
asserts exit codes, retry counts, that downstream stages never start, and that the registry is
byte-identical after each failure. Results: `docs/EVIDENCE.md`. Problems: `docs/TROUBLESHOOTING.md`.

## CI

`.github/workflows/ci.yml` runs on pull requests and pushes: lint, unit tests, `argo lint`,
`helm template` against the pinned chart, shell syntax checks, manifest parsing, and the image
builds. The kind cluster tests (about 9 minutes) also run on every pull request, and from a manual "Run workflow" dispatch with `cluster` ticked. Project 01 is checked out at a pinned commit as a sibling directory, matching the local
path dependency. Update `PROJECT01_SHA` in the file when you deliberately adopt a newer Project 01.

## Resource and dataset-size tests

```bash
tests/perf/run.sh "5000 500000 2000000"                  # peak memory and CPU per stage, in the stage image
MEMORY=768m CPUS=2 tests/perf/run.sh "1000000"            # same run under a pod-sized limit (exit -9 = OOM kill)
tests/workflow/large-dataset.sh 2000000                  # whole workflow on the cluster, 2M rows (~2 min)
```

Results are in `docs/EVIDENCE.md`. Re-run them when the dataset or model changes, then adjust the
limits in `workflows/training-workflow.yaml`.
