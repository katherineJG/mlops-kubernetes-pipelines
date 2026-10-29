# mlops-kubernetes-pipelines

Containerized ML workflow (validate → train → evaluate → promote) run as an Argo Workflows DAG on a
local kind cluster. Reuses Project 01's churn pipeline image.

**Status: working locally.** The DAG runs end to end on kind; success and four failure scenarios pass with security controls verified. The GitHub Actions workflow also passes on GitHub, including the opt-in cluster job.

**Local requirements:** Docker Desktop, kind, helm, kubectl and the argo CLI (pinned in `versions.env`).
The kind node plus Argo should need about 2 CPUs and 4 GB RAM (estimated, not measured), and the stage
image is about 2.4 GB. The full set of failure scenarios takes about 5 minutes. If something breaks, start
with [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

- Design and decisions: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Setup, cleanup, prerequisites: [docs/OPERATIONS.md](docs/OPERATIONS.md)
- Problems and fixes: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- Run evidence: [docs/EVIDENCE.md](docs/EVIDENCE.md)
