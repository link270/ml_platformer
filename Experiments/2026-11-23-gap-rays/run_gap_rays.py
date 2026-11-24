"""Train the gap-ray or landing-memory preset on one or more courses."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import shutil
import subprocess
import sys
import time
import zipfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
EASY = HERE.parent / "2026-11-20-easy-q-learning"
sys.path.insert(0, str(EASY))

from run import EVAL_RUNS, EVAL_SEED, MILESTONES, SEED, digest, dump, execute, snapshot


PRESET = "gap_rays"
LEVELS = ("easy", "medium", "hard")
UPDATED = (
    "Agents/QCheckpoint.gd", "Agents/QLearningAgent.gd", "Agents/QPresets.gd",
    "Game/GapRays.gd", "Game/Level.gd", "Game/Player.gd",
)


def freeze(runtime, source_zip):
    with zipfile.ZipFile(source_zip, "r") as archive:
        runtime.mkdir(parents=True, exist_ok=False)
        archive.extractall(runtime)
    project = runtime / "standard"
    hashes = {p.relative_to(project).as_posix(): digest(p)
              for p in project.rglob("*") if p.is_file()}
    return project, hashes


def capture_source(runtime, output):
    project, hashes = snapshot(runtime, False)
    for relative in UPDATED:
        src = REPO / relative
        shutil.copyfile(src, project / relative)
        hashes[relative] = digest(project / relative)
    with zipfile.ZipFile(output / "source.zip", "x", zipfile.ZIP_DEFLATED) as archive:
        for relative in sorted(hashes):
            archive.write(project / relative, f"standard/{relative}")
    return project, hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=HERE / "results")
    parser.add_argument("--preset", choices=(PRESET, "airborne_landing"), default=PRESET)
    parser.add_argument("--levels", choices=LEVELS, nargs="+", default=LEVELS)
    parser.add_argument("--source", type=Path, help="Reuse results/source.zip to reproduce the archived runs.")
    args = parser.parse_args()
    runtime, output = args.runtime.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    project, hashes = (freeze(runtime, args.source) if args.source
                       else capture_source(runtime, output))
    dump(output / "settings.json", {
        "level": list(args.levels), "preset": args.preset, "training_seed": SEED,
        "evaluation_seed_first": EVAL_SEED, "evaluation_runs_per_checkpoint": EVAL_RUNS,
        "milestones": MILESTONES, "stuck_detection": True, "episode_limit_seconds": 60,
        "training_record_every": 100, "source_sha256": hashes,
        "engine": subprocess.check_output([args.godot, "--version"], text=True).strip(),
    })
    with ThreadPoolExecutor(max_workers=len(args.levels)) as pool:
        jobs = {level: pool.submit(execute, args.godot, project, runtime, output / level, "training",
                                   args.preset, 10000, 10000, level=level)
                for level in args.levels}
        pending = [(level, milestone) for milestone in MILESTONES for level in args.levels]
        while pending:
            ready = []
            for level, milestone in pending:
                if jobs[level].done():
                    jobs[level].result()
                folder = output / level
                checkpoint = folder / f"{milestone:05d}.json"
                if checkpoint.is_file():
                    execute(args.godot, project, runtime, folder, f"eval-{milestone:05d}",
                            args.preset, milestone, EVAL_RUNS, checkpoint, level=level)
                    ready.append((level, milestone))
            pending = [item for item in pending if item not in ready]
            if pending and not ready:
                time.sleep(3)
        for job in jobs.values():
            job.result()


if __name__ == "__main__":
    main()
