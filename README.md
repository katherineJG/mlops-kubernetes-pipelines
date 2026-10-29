# mlops-kubernetes-pipelines

Containerized ML workflow (validate → train → evaluate → promote) run as an Argo Workflows DAG on a
local kind cluster. Reuses Project 01's churn pipeline image.

**Status: working locally.** The DAG runs end to end on kind; success and five failure scenarios pass with security controls verified. The GitHub Actions workflow also passes on GitHub, including the cluster job.

**Local requirements:** Docker Desktop, kind, helm, kubectl and the argo CLI (pinned in `versions.env`).
The kind node plus Argo and Calico should need about 2 CPUs and 4 GB RAM (estimated, not measured), and the stage
image is about 2.4 GB. The full set of failure scenarios takes about 5 minutes. If something breaks, start
with [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Quick start

This repo builds on [Project 01](https://github.com/katherineJG/mlops-reproducible-training), which must
sit next to it in a folder named `Reproducible ML Training Pipeline` (pinned commit: see `PROJECT01_SHA`
in `.github/workflows/ci.yml`). Run from Git Bash or WSL with Docker running; `uv`, `kind`, `helm`,
`kubectl` and `argo` at the versions in `versions.env`.

```bash
git clone https://github.com/katherineJG/mlops-reproducible-training "Reproducible ML Training Pipeline"
git -C "Reproducible ML Training Pipeline" checkout 485f76ebf90cf00f1f4481df1817f67e678b4d78
git clone https://github.com/katherineJG/mlops-kubernetes-pipelines && cd mlops-kubernetes-pipelines

source versions.env
docker build -t "$BASE_IMAGE" "../Reproducible ML Training Pipeline"
docker build -f containers/Dockerfile --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$STAGE_IMAGE" .
./scripts/create-cluster.sh && kind load docker-image "$STAGE_IMAGE" --name "$CLUSTER_NAME"
./scripts/install-argo.sh
export MSYS_NO_PATHCONV=1        # Git Bash only
argo --context "kind-$CLUSTER_NAME" submit workflows/training-workflow.yaml -n ml-workflows --wait
./scripts/cleanup.sh             # deletes the cluster and the artifacts
```

More detail, tests and failure scenarios: [docs/OPERATIONS.md](docs/OPERATIONS.md).

## Documentation

- Design and decisions: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Setup, cleanup, prerequisites: [docs/OPERATIONS.md](docs/OPERATIONS.md)
- Problems and fixes: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- Run evidence: [docs/EVIDENCE.md](docs/EVIDENCE.md)

## License

[MIT](LICENSE)
