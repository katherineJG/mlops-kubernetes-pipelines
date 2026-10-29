# mlops-kubernetes-pipelines

Containerized ML workflow (validate → train → evaluate → promote) run as an Argo Workflows DAG on a
local kind cluster. Reuses Project 01's churn pipeline image.

**Status: M0-M2 done locally.** The DAG runs end to end on kind; failure-path tests, timeouts and CI (M3-M4) are still to do.

- Design and decisions: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Setup, cleanup, prerequisites: [docs/OPERATIONS.md](docs/OPERATIONS.md)
