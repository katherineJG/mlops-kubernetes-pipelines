# mlops-kubernetes-pipelines

Containerized ML workflow (validate → train → evaluate → promote) run as an Argo Workflows DAG on a
local kind cluster. Reuses Project 01's churn pipeline image.

**Status: working locally.** The DAG runs end to end on kind; success and four failure scenarios pass with security controls verified. The GitHub Actions workflow has not yet run on GitHub.

- Design and decisions: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Setup, cleanup, prerequisites: [docs/OPERATIONS.md](docs/OPERATIONS.md)
- Problems and fixes: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- Run evidence: [docs/EVIDENCE.md](docs/EVIDENCE.md)
