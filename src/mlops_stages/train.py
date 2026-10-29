"""Stage 2: fit baseline and candidate on the seeded split. No gating here (see evaluate)."""

import argparse
from collections.abc import Sequence
from pathlib import Path

import joblib
import pandas as pd
import sklearn
from churn_pipeline.config import load_data_config, load_model_config
from churn_pipeline.features import FEATURES
from churn_pipeline.train import make_baseline, make_candidate, split

from mlops_stages.common import PreconditionError, log, read_json, run_stage, write_json


def _body(argv: Sequence[str]) -> None:
    p = argparse.ArgumentParser(description="Train baseline and candidate models.")
    p.add_argument("--input-dir", type=Path, required=True)
    p.add_argument("--run-dir", type=Path, required=True)
    p.add_argument("--data-config", type=Path, required=True)
    p.add_argument("--model-config", type=Path, required=True)
    a = p.parse_args(argv)
    if not read_json(a.run_dir / "validation.json").get("passed"):
        raise PreconditionError("validation did not pass")
    data_cfg, model_cfg = load_data_config(a.data_config), load_model_config(a.model_config)
    target = data_cfg.target
    train, test = split(pd.read_csv(a.input_dir / "raw.csv"), target, model_cfg)
    models = a.run_dir / "models"
    models.mkdir(parents=True, exist_ok=True)
    pipes = {"baseline": make_baseline(model_cfg), "candidate": make_candidate(model_cfg)}
    for name, pipe in pipes.items():
        pipe.fit(train[FEATURES], train[target])
        joblib.dump(pipe, models / f"{name}.joblib")
    write_json(
        a.run_dir / "train.json",
        {
            "seed": model_cfg.seed,
            "n_train": len(train),
            "n_test": len(test),
            "sklearn": sklearn.__version__,
        },
    )
    log.info("trained on %d rows (test %d)", len(train), len(test))


def main(argv: Sequence[str] | None = None) -> int:
    return run_stage(_body, argv)


if __name__ == "__main__":
    raise SystemExit(main())
