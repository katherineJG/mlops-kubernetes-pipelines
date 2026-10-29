"""Stage 1: check the input CSV against the Project 01 data contract."""

import argparse
from collections.abc import Sequence
from pathlib import Path

import pandas as pd
from churn_pipeline.validate import validate

from mlops_stages.common import log, read_json, run_stage, sha256_file, write_json


def _body(argv: Sequence[str]) -> None:
    p = argparse.ArgumentParser(
        description="Validate input data. Exit 10 if it breaks the contract."
    )
    p.add_argument(
        "--input-dir", type=Path, required=True, help="holds raw.csv and provenance.json"
    )
    p.add_argument("--run-dir", type=Path, required=True)
    a = p.parse_args(argv)
    raw = a.input_dir / "raw.csv"
    df = validate(pd.read_csv(raw))
    write_json(
        a.run_dir / "validation.json",
        {
            "passed": True,
            "rows": len(df),
            "dataset_sha256": sha256_file(raw),
            "input_provenance": read_json(a.input_dir / "provenance.json"),
        },
    )
    log.info("validation passed: %d rows", len(df))


def main(argv: Sequence[str] | None = None) -> int:
    return run_stage(_body, argv)


if __name__ == "__main__":
    raise SystemExit(main())
