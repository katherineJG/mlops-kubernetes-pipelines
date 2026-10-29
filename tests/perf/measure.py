"""Measure peak memory and CPU of each stage for synthetic datasets of increasing size.

Runs inside the stage image (see tests/perf/run.sh). Each stage is a child process, so the kernel's
rusage gives its true peak RSS and CPU time. Prints one markdown row per (rows, stage).
"""
import os
import pathlib
import shutil
import subprocess
import sys
import time

import yaml

WORK = pathlib.Path(os.environ.get("WORK", "/work"))
rows_list = [int(x) for x in sys.argv[1:]] or [5000]


def run(stage, args):
    t0 = time.monotonic()
    pid_status = subprocess.Popen([sys.executable, "-m", stage, *args])
    _, status, ru = os.wait4(pid_status.pid, 0)
    pid_status.returncode = os.waitstatus_to_exitcode(status)
    wall = time.monotonic() - t0
    cpu = ru.ru_utime + ru.ru_stime
    return pid_status.returncode, ru.ru_maxrss / 1024, cpu, wall  # ru_maxrss is KiB on Linux


print("| rows | stage | exit | peak MiB | CPU s | wall s | avg cores |")
print("|---|---|---|---|---|---|---|")
for n in rows_list:
    d = WORK / f"r{n}"
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    cfg = yaml.safe_load(open("/app/configs/data.yaml"))
    cfg["n_rows"] = n
    yaml.safe_dump(cfg, open(d / "data.yaml", "w"))
    data, model = str(d / "data.yaml"), "/app/configs/model.yaml"
    i, r = f"{d}/input", str(d)
    train_args = ["--input-dir", i, "--run-dir", r, "--data-config", data, "--model-config", model]
    promote_args = ["--run-dir", r, "--registry-dir", str(WORK / "registry"),
                    "--source-revision", "perf", "--image", "perf"]
    stages = [
        ("churn_pipeline.ingest", ["--config", data, "--out", i]),
        ("mlops_stages.validate", ["--input-dir", i, "--run-dir", r]),
        ("mlops_stages.train", train_args),
        ("mlops_stages.evaluate", train_args),
        ("mlops_stages.promote", promote_args),
    ]
    for stage, args in stages:
        code, peak, cpu, wall = run(stage, args)
        name = stage.split(".")[-1]
        row = [n, name, code, f"{peak:.0f}", f"{cpu:.1f}", f"{wall:.1f}", f"{cpu / wall:.2f}"]
        print("| " + " | ".join(map(str, row)) + " |", flush=True)
        if code:
            break
    shutil.rmtree(d, ignore_errors=True)
