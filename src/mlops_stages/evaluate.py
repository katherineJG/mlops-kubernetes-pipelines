"""Stage 3: score both models on the held-out split and apply the acceptance gates."""

import argparse
from collections.abc import Sequence
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from churn_pipeline.config import load_data_config, load_model_config
from churn_pipeline.evaluate import check_gates, compute_metrics, write_outputs
from churn_pipeline.features import FEATURES
from churn_pipeline.train import split

from mlops_stages.common import GateFailedError, log, read_json, run_stage, write_json


def _body(argv: Sequence[str]) -> None:
    p = argparse.ArgumentParser(description="Evaluate the candidate. Exit 20 if a gate fails.")
    p.add_argument("--input-dir", type=Path, required=True)
    p.add_argument("--run-dir", type=Path, required=True)
    p.add_argument("--data-config", type=Path, required=True)
    p.add_argument("--model-config", type=Path, required=True)
    a = p.parse_args(argv)
    read_json(a.run_dir / "train.json")  # exit 30 if training never finished
    data_cfg, model_cfg = load_data_config(a.data_config), load_model_config(a.model_config)
    target = data_cfg.target
    # Same seeded split as the train stage, so these rows were never seen in training.
    _, test = split(pd.read_csv(a.input_dir / "raw.csv"), target, model_cfg)
    metrics = {}
    for name in ("baseline", "candidate"):
        pipe = joblib.load(a.run_dir / "models" / f"{name}.joblib")
        proba = np.asarray(pipe.predict_proba(test[FEATURES])[:, 1])
        metrics[name] = compute_metrics(
            test[target].to_numpy(), proba, model_cfg.decision_threshold
        )
    failures = check_gates(metrics["candidate"], metrics["baseline"], model_cfg.gates)
    write_outputs(
        a.run_dir,
        metrics["baseline"],
        metrics["candidate"],
        failures,
        model_cfg.decision_threshold,
        read_json(a.input_dir / "provenance.json"),
    )
    write_json(a.run_dir / "gate.json", {"passed": not failures, "failures": failures})
    if failures:
        raise GateFailedError("; ".join(failures))
    log.info("candidate eligible")


def main(argv: Sequence[str] | None = None) -> int:
    return run_stage(_body, argv)


if __name__ == "__main__":
    raise SystemExit(main())
