# Stage image: Project 01's image plus the stage CLIs. Build context is the repo root.
#   docker build -f containers/Dockerfile --build-arg BASE_IMAGE=churn-pipeline:p01-local -t mlops-stages:m1-local .
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
WORKDIR /app
COPY src/mlops_stages ./mlops_stages
# Non-root; HOME and library caches go to /tmp so the root filesystem can be read-only.
ENV HOME=/tmp PYTHONDONTWRITEBYTECODE=1
USER 65532:65532
ENTRYPOINT ["python", "-m"]
