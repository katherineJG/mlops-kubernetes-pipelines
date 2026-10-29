"""Exit-code contract and small helpers shared by every stage."""

import hashlib
import json
import logging
import sys
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

from churn_pipeline.validate import DataValidationError

OK = 0
UNEXPECTED = 1  # possibly transient: the only code the workflow retries
DATA_INVALID = 10  # deterministic: input violates the data contract
GATE_FAILED = 20  # deterministic: candidate misses an acceptance gate
PRECONDITION = 30  # deterministic: an upstream stage did not leave what this one needs

log = logging.getLogger("mlops_stages")


class GateFailedError(Exception):
    """Evaluation finished but the candidate is ineligible."""


class PreconditionError(Exception):
    """A required upstream artifact is missing or says the run must not continue."""


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8", newline="\n")


def read_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise PreconditionError(f"required artifact missing: {path}")
    data: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
    return data


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_stage(body: Callable[[Sequence[str]], None], argv: Sequence[str] | None) -> int:
    """Run a stage body and translate its outcome into the exit-code contract."""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    try:
        body(sys.argv[1:] if argv is None else argv)
    except DataValidationError as exc:
        log.error("data invalid: %s", exc)
        return DATA_INVALID
    except GateFailedError as exc:
        log.error("gate failed: %s", exc)
        return GATE_FAILED
    except PreconditionError as exc:
        log.error("precondition not met: %s", exc)
        return PRECONDITION
    except Exception:
        log.exception("unexpected error")
        return UNEXPECTED
    return OK
