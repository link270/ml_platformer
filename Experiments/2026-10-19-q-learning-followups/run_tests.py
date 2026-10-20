"""Run the unchanged diagnostic in prepared projects, three processes at a time.

Usage: python3 run_tests.py /tmp/platformer-followups /path/to/godot
Each invocation overwrites that project's generated results; use a fresh directory.
"""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import sys
import time

from prepare import VARIANTS

ROOT = Path(sys.argv[1]).resolve()
GODOT = sys.argv[2]
SEEDS = [12345, 42, 98765]


def run(variant, seed):
    project = ROOT / variant
    log = project / f"run-{seed}.log"
    start = time.monotonic()
    print(f"START {variant} seed={seed}", flush=True)
    with log.open("w") as output:
        result = subprocess.run(
            [GODOT, "--headless", "--path", str(project), "--fixed-fps", "60",
             "--disable-render-loop", "--log-file", str(project / f"engine-{seed}.log"),
             "--script", "res://diagnose.gd", "--", str(seed)],
            stdout=output, stderr=subprocess.STDOUT, timeout=3600)
    data = json.loads((project / f"results-{seed}.json").read_text())
    assert result.returncode == 0 and len(data["training"]) == 10000, (variant, seed)
    assert len(data["evaluations"]) == 9
    assert all(len(e["runs"]) == 30 for e in data["evaluations"])
    print(f"DONE {variant} seed={seed} seconds={time.monotonic()-start:.1f}", flush=True)
    return {"variant": variant, "seed": seed, "exit_code": result.returncode}


if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(run, variant, seed) for seed in SEEDS for variant in VARIANTS]
        completed = [f.result() for f in concurrent.futures.as_completed(futures)]
    (ROOT / "completed.json").write_text(json.dumps(completed, indent=2) + "\n")
