# Architecture

Status: the stage CLIs, image and Argo DAG run end to end on the local kind cluster. Resource limits
are measured, security controls are verified, and the success, bad-data, failed-training, failed-gate
and timeout scenarios pass. The GitHub Actions workflow is written but has not yet run on GitHub.

## DAG

```mermaid
flowchart LR
    I[ingest] --> V[validate] --> T[train] --> E[evaluate] --> P[promote]
```

`ingest` is Project 01's own `churn_pipeline.ingest` CLI (seeded synthetic data, no network),
run unwrapped; it writes `raw.csv` and `provenance.json` into the run directory. Stage code lives
in `src/mlops_stages/` and is baked into one image by `containers/Dockerfile`.

Each arrow is an Argo `depends` on `.Succeeded`. A non-zero exit in any stage leaves every
downstream stage unscheduled, so evaluate cannot run after failed training and promote cannot run
after failed evaluation.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Cluster | kind, single node | Same path locally and in CI. |
| Artifact store | One PVC (`ReadWriteOnce`, kind default `standard` class) mounted at `/artifacts` | Simplest option that survives pod termination. Single node makes RWO safe for sequential pods. Less portable than S3 URIs; MinIO is a later swap. |
| Image | `FROM` Project 01's image (`BASE_IMAGE`), adding only stage wrappers | One lockfile, one build. Project 01 code is not copied. |
| Registry | None. Images are built locally and loaded with `kind load docker-image` | No external publishing. |
| Storage object | Standalone PVC `artifacts` (k8s/artifact-pvc.yaml), not a workflow volumeClaimTemplate | kind's `standard` class has reclaimPolicy Delete; a claim template would be deleted with the workflow. |
| Tracking | No MLflow in the cluster for v1 | Provenance goes in `provenance.json`. |

## Reusing Project 01 (checked against its source)

- `validate.py` has a CLI (`validate <csv>`, exit 1 on failure) and raises `DataValidationError`.
- `train.py` is **train + evaluate + gate in one step**: it fits baseline and candidate, computes
  metrics, checks gates and exits 1 (validation) or 2 (gate failed). It also logs to MLflow (sqlite).
- The spec wants train and evaluate as separate jobs, so the stage wrappers split it:
  - `train` stage: validate-free fit of both pipelines on the deterministic split (`split()`,
    seeded), writes `baseline.joblib`, `candidate.joblib`. No gating, no MLflow.
  - `evaluate` stage: loads both models, recomputes the same seeded split, calls
    `compute_metrics` and `check_gates`, writes `metrics.json` and `report.md`.
- Coupling risk: wrappers import `churn_pipeline.train.split`, `evaluate.*`, `config.*`.
  If Project 01 renames them, the stage image breaks. Pin Project 01 by image tag.
- Project 01 is **not modified** by this project.

## Stage contract

Common: config via CLI flags/env, structured logs to stderr, JSON result to stdout-file under the
run dir, no network access, runs as non-root, read-only root filesystem where possible.

| Stage | Inputs | Outputs (under `/artifacts/runs/<run-id>/`) | Resources (req/limit) | Timeout |
|---|---|---|---|---|
| validate | `--input` CSV + `provenance.json` | `validation.json` (rules checked, row count, dataset sha256) | 100m/500m CPU, 160Mi/384Mi | 2m |
| train | `--input`, `--model-config` | `models/baseline.joblib`, `models/candidate.joblib`, `train.json` | 500m/2 CPU, 384Mi/768Mi | 10m |
| evaluate | `models/`, `--input`, `--model-config` | `metrics.json`, `report.md`, `gate.json` | 250m/1 CPU, 384Mi/768Mi | 5m |
| promote | run dir | `registry/models/<run-id>/`, updated `registry/current.json` | 50m/200m CPU, 128Mi/256Mi | 1m |

Memory figures come from measured peaks on the 5,000-row fixture (ingest 126 MiB, validate 137, train 267, evaluate 263, promote 123), at roughly 2-3x headroom; a full run under them had no OOM kills. Larger datasets need re-measuring. The ingest stage is not in the table: 100m/1 CPU, 160Mi/384Mi, 2m. CPU limits are unmeasured guesses (train used about 2 cores for 2.5 s). The stages take
`--input-dir`/`--run-dir` rather than a single `--input` file. Each stage also checks its own
precondition (train needs a passed `validation.json`, evaluate needs `train.json`, promote needs a
passed `gate.json`), so a mis-wired DAG still cannot promote. The image sets `HOME=/tmp`; mount an
`emptyDir` at `/tmp` when running with a read-only root filesystem.

### Exit codes

| Code | Meaning | Retried? |
|---|---|---|
| 0 | Success | n/a |
| 10 | Data/schema invalid (deterministic) | No |
| 20 | Evaluation gate failed (deterministic) | No |
| 30 | Precondition not met: an upstream artifact is missing or says stop (deterministic) | No |
| 1 | Unexpected error (may be transient) | Yes, max 2, exponential backoff |

Project 01 uses 1 for validation failure and 2 for gate failure. The wrappers translate those to
10 and 20 so that code 1 can mean only "unexpected".

Retry rule, as written in `workflows/training-workflow.yaml` (limit 2, backoff 5s ×2):
`retryPolicy: Always` plus `expression: lastRetry.status == "Error" || (lastRetry.status == "Failed" && asInt(lastRetry.exitCode) == 1)`.
Observed on the cluster (Argo v4.1.6, see `docs/EVIDENCE.md`): exit 10 and exit 20 each ran once and
were not retried; exit 1 (a missing config file) ran three times; a timeout ran once and was not
retried (the pod has no exit code, so the expression evaluates to false). Exit 30 is covered by unit
tests only. The train timeout is the `train-timeout` workflow parameter (default 600 s) so this path
can be tested with a tiny value.

Workflow notes: `command: [python, -m]` is set explicitly because the emissary executor cannot read
the entrypoint of an image that only exists locally. YAML anchors are avoided because `argo lint`
silently skips files that contain them.

## Artifact layout

```text
/artifacts
├── runs/<run-id>/            # one directory per workflow run; written by stages
│   ├── validation.json
│   ├── models/{baseline,candidate}.joblib
│   ├── train.json
│   ├── metrics.json  gate.json  report.md
│   └── provenance.json       # run id, git sha, dataset sha256, image digests, eval result
└── registry/                 # written ONLY by promote
    ├── models/<run-id>/
    └── current.json          # pointer to the last-known-good run
```

Promote copies `runs/<run-id>/models` to `registry/models/<run-id>/`, writes
`current.json.tmp`, then `os.replace` onto `current.json` (atomic on one filesystem). Failed runs
never touch `registry/`, so the last known-good model is preserved. Promote refuses to run unless
`gate.json` says passed.

`<run-id>` is the Argo workflow name.

## Provenance record

`provenance.json` holds: model URI (`registry/models/<run-id>`), workflow/run id, source revision
(git SHA passed as a parameter, since the image has no `.git`), dataset sha256, image tags, metrics,
gate result, timestamp.

## Security

Verified on the live cluster by `tests/workflow/security-checks.sh` (21 checks by default, 22 with `--restart-node`; all passing on 2026-10-29):

- Dedicated namespace `ml-workflows` enforcing the `restricted` pod-security level. A privileged pod, a
  root pod and an escalating pod are each rejected; a compliant pod is admitted.
- ServiceAccount `ml-workflow` can only create and patch `workflowtaskresults` in its own namespace. It
  cannot read secrets or configmaps, list or create pods, create workflows, delete PVCs, act in another
  namespace or touch cluster-wide resources.
- Containers run as uid 65532 with no Linux capabilities, a read-only root filesystem, `/tmp` as an
  `emptyDir` and the artifacts PVC as the only writable paths, plus `allowPrivilegeEscalation: false` and
  the `RuntimeDefault` seccomp profile.
- Artifacts on the PVC survive pod and workflow deletion and a restart of the kind node.
- No tracked file contains a private key, AWS-style key or Kubernetes Secret manifest.

### Credentials

v1 uses no credentials: the artifact store is a local PVC and images are loaded into kind, not pulled
from a registry. If an external store or registry is added later: create the Kubernetes Secret out of
band with `kubectl create secret`, reference it by name from the workflow, never commit the manifest
(`.gitignore` already excludes `*.key`, `*.pem`, `.env`, `kubeconfig*`), and give the workflow
ServiceAccount `get` on that one secret by name only.

### Known limits

- No NetworkPolicy: pods can reach the network and each other. The stage code makes no network calls
  (tested with `--network none`), but the cluster does not enforce it.
- The workflow ServiceAccount token is mounted because the Argo executor needs it.
- `reclaimPolicy: Delete` on kind's default storage class means deleting the PVC or cluster deletes the
  artifacts. Back up `/artifacts/registry` before cleanup if the model matters.
- Images are tagged, not digest-pinned; they exist only in the local Docker daemon and the kind node.

## Retention and cleanup

Run directories are kept until deleted by hand. `scripts/cleanup.sh` deletes the cluster and with it
the PVC. A prune script for old runs is out of scope for v1.

## Open items (not decided or not verified)

- Whether Project 01's `ingest` needs network access; the cluster run should use a fixed fixture
  instead. Not yet checked.
- Exact Argo chart version and values keys (see `versions.env`, `helm/values.yaml`).
- Resource numbers and the Argo retry expression.
