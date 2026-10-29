"""Stage 4: publish the candidate to the registry, only if evaluation passed.

The registry is touched only here. Models are copied into place first and `current.json` is
swapped last with an atomic rename, so a crash or failed run never replaces the last known-good.
"""

import argparse
import os
import shutil
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path

from mlops_stages.common import PreconditionError, log, read_json, run_stage, write_json


def _body(argv: Sequence[str]) -> None:
    p = argparse.ArgumentParser(description="Promote a passing candidate to the registry.")
    p.add_argument("--run-dir", type=Path, required=True)
    p.add_argument("--registry-dir", type=Path, required=True)
    p.add_argument("--source-revision", default="unknown")
    p.add_argument("--image", default="unknown")
    a = p.parse_args(argv)
    if not read_json(a.run_dir / "gate.json").get("passed"):
        raise PreconditionError("evaluation gate did not pass; refusing to promote")
    run_id = a.run_dir.name
    target = a.registry_dir / "models" / run_id
    if not target.exists():  # a retry after a late failure finds it already copied
        tmp = a.registry_dir / "models" / f".{run_id}.tmp"
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.copytree(a.run_dir / "models", tmp)
        os.replace(tmp, target)
    record = {
        "model_uri": f"registry/models/{run_id}",
        "run_id": run_id,
        "source_revision": a.source_revision,
        "image": a.image,
        "dataset_sha256": read_json(a.run_dir / "validation.json")["dataset_sha256"],
        "metrics": read_json(a.run_dir / "metrics.json"),
        "promoted_at": datetime.now(UTC).isoformat(),
    }
    write_json(a.run_dir / "provenance.json", record)
    pointer_tmp = a.registry_dir / "current.json.tmp"
    write_json(pointer_tmp, record)
    os.replace(pointer_tmp, a.registry_dir / "current.json")
    log.info("promoted %s", run_id)


def main(argv: Sequence[str] | None = None) -> int:
    return run_stage(_body, argv)


if __name__ == "__main__":
    raise SystemExit(main())
