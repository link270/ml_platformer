"""Extend the matched Hard training experiment to 50,000 episodes."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
EASY = HERE.parent / "2026-11-20-easy-q-learning"
HARD = HERE.parent / "2026-11-23-hard-q-learning"
sys.path.insert(0, str(EASY))

from run import EVAL_RUNS, EVAL_SEED, SEED, digest, dump, execute, read, snapshot


PRESETS = ("fixed_reward_per_block", "late_learning_rate")
TOTAL = 50000
MILESTONES = tuple(range(5000, TOTAL + 1, 5000))
WORKER = "res://hard_long_worker.gd"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=HERE / "results")
    args = parser.parse_args()
    output, runtime = args.output.resolve(), args.runtime.resolve()
    output.mkdir(parents=True, exist_ok=False)
    project, hashes = snapshot(runtime, False)
    reference = read(HARD / "results" / "settings.json")
    assert hashes == reference["source_sha256"]
    engine = subprocess.check_output([args.godot, "--version"], text=True).strip()
    assert engine == reference["engine"]
    shutil.copyfile(HERE / "worker.gd", project / "hard_long_worker.gd")
    hashes["hard_long_worker.gd"] = digest(project / "hard_long_worker.gd")
    dump(output / "settings.json", {
        "level": "hard", "training_seed": SEED, "evaluation_seed_first": EVAL_SEED,
        "evaluation_runs_per_checkpoint": EVAL_RUNS, "training_runs_per_preset": TOTAL,
        "milestones": MILESTONES, "presets": PRESETS, "stuck_detection": True,
        "episode_limit_seconds": 60, "training_record_every": 100, "engine": engine,
        "source_sha256": hashes,
    })

    with ThreadPoolExecutor(max_workers=len(PRESETS)) as pool:
        training = {
            preset: pool.submit(execute, args.godot, project, runtime, output / preset, "training",
                                preset, TOTAL, TOTAL, level="hard", worker=WORKER,
                                training_milestones=(1000, *MILESTONES))
            for preset in PRESETS
        }
        pending = [(preset, milestone) for milestone in MILESTONES for preset in PRESETS]
        while pending:
            ready = []
            for preset, milestone in pending:
                if training[preset].done():
                    training[preset].result()
                folder = output / preset
                checkpoint = folder / f"{milestone:05d}.json"
                if checkpoint.is_file():
                    execute(args.godot, project, runtime, folder, f"eval-{milestone:05d}",
                            preset, milestone, EVAL_RUNS, checkpoint, level="hard", worker=WORKER)
                    ready.append((preset, milestone))
            pending = [item for item in pending if item not in ready]
            if pending and not ready:
                time.sleep(3)
        for job in training.values():
            job.result()


if __name__ == "__main__":
    main()
