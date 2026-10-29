"""Stage CLIs on a small deterministic fixture: exit codes, gating and last-known-good safety."""

import json
from pathlib import Path

import pytest
import yaml
from churn_pipeline.config import load_data_config
from churn_pipeline.ingest import build_provenance, generate_synthetic

from mlops_stages import common, evaluate, promote, train, validate

DATA_CFG = {
    "source": "synthetic",
    "csv_path": None,
    "seed": 42,
    "n_rows": 3000,
    "schema_version": "1",
    "target": "churn",
    "id_column": "customer_id",
}
MODEL_CFG = {
    "seed": 42,
    "test_size": 0.2,
    "decision_threshold": 0.5,
    "baseline": {"type": "dummy_prior"},
    "candidate": {
        "type": "logistic_regression",
        "params": {"C": 1.0, "max_iter": 1000, "class_weight": "balanced"},
    },
    "gates": {
        "min_roc_auc": 0.70,
        "min_pr_auc": 0.40,
        "min_recall": 0.50,
        "min_roc_auc_lift_over_baseline": 0.05,
    },
}


@pytest.fixture
def env(tmp_path: Path) -> dict[str, Path]:
    inp, run, reg = tmp_path / "input", tmp_path / "runs" / "run-1", tmp_path / "registry"
    inp.mkdir()
    df = generate_synthetic(DATA_CFG["n_rows"], DATA_CFG["seed"])
    df.to_csv(inp / "raw.csv", index=False, lineterminator="\n")
    data_path, model_path = tmp_path / "data.yaml", tmp_path / "model.yaml"
    data_path.write_text(yaml.safe_dump(DATA_CFG))
    model_path.write_text(yaml.safe_dump(MODEL_CFG))
    (inp / "provenance.json").write_text(
        json.dumps(build_provenance(df, load_data_config(data_path)))
    )
    return {"input": inp, "run": run, "registry": reg, "data": data_path, "model": model_path}


def args(e: dict[str, Path], *keys: str) -> list[str]:
    flag = {
        "input": "--input-dir",
        "run": "--run-dir",
        "data": "--data-config",
        "model": "--model-config",
    }
    return [x for k in keys for x in (flag[k], str(e[k]))]


def run_all(e: dict[str, Path]) -> list[int]:
    common_args = args(e, "input", "run", "data", "model")
    return [
        validate.main(args(e, "input", "run")),
        train.main(common_args),
        evaluate.main(common_args),
        promote.main(["--run-dir", str(e["run"]), "--registry-dir", str(e["registry"])]),
    ]


def test_happy_path_promotes_and_records_provenance(env):
    assert run_all(env) == [0, 0, 0, 0]
    current = json.loads((env["registry"] / "current.json").read_text())
    assert current["run_id"] == "run-1"
    assert current["model_uri"] == "registry/models/run-1"
    assert len(current["dataset_sha256"]) == 64
    assert (env["registry"] / "models" / "run-1" / "candidate.joblib").is_file()


def test_invalid_data_exits_10_and_blocks_train(env):
    raw = env["input"] / "raw.csv"
    raw.write_text(raw.read_text().replace("month-to-month", "weekly", 5))
    assert validate.main(args(env, "input", "run")) == common.DATA_INVALID
    assert train.main(args(env, "input", "run", "data", "model")) == common.PRECONDITION


def test_evaluate_without_training_exits_30(env):
    assert evaluate.main(args(env, "input", "run", "data", "model")) == common.PRECONDITION


def test_failed_gate_exits_20_and_promote_refuses(env):
    cfg = {**MODEL_CFG, "gates": {**MODEL_CFG["gates"], "min_roc_auc": 0.999}}
    env["model"].write_text(yaml.safe_dump(cfg))
    codes = run_all(env)
    assert codes == [0, 0, common.GATE_FAILED, common.PRECONDITION]
    assert json.loads((env["run"] / "gate.json").read_text())["passed"] is False
    assert not (env["registry"] / "current.json").exists()


def test_failed_run_does_not_overwrite_last_known_good(env):
    assert run_all(env) == [0, 0, 0, 0]
    good = (env["registry"] / "current.json").read_text()
    # second run, same registry, fails its gate
    bad = env["run"].parent / "run-2"
    cfg = {**MODEL_CFG, "gates": {**MODEL_CFG["gates"], "min_roc_auc": 0.999}}
    env["model"].write_text(yaml.safe_dump(cfg))
    env2 = {**env, "run": bad}
    assert run_all(env2)[2:] == [common.GATE_FAILED, common.PRECONDITION]
    assert (env["registry"] / "current.json").read_text() == good
    assert not (env["registry"] / "models" / "run-2").exists()


def test_promote_retry_is_idempotent(env):
    assert run_all(env) == [0, 0, 0, 0]
    assert promote.main(["--run-dir", str(env["run"]), "--registry-dir", str(env["registry"])]) == 0


def test_unexpected_error_exits_1(env):
    (env["input"] / "raw.csv").unlink()
    assert validate.main(args(env, "input", "run")) == common.UNEXPECTED
