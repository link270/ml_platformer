"""Train and evaluate fresh Q-tables on Easy, Medium or Hard using a frozen project."""

from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import argparse
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import zipfile


HERE = Path(__file__).resolve().parent
SEED = 78436291
EVAL_SEED = 78436300
MILESTONES = (1000, 5000, 10000)
EVAL_RUNS = 30
PRESETS = (
    "baseline", "time_penalty", "long_exploration", "discount_099",
    "horizontal_bins", "late_learning_rate", "fixed_reward_per_block",
)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dump(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def snapshot(runtime, course_position):
    project_name = "course-position" if course_position else "standard"
    runtime.mkdir(parents=True, exist_ok=False)
    with zipfile.ZipFile(HERE / "source.zip") as archive:
        members = [name for name in archive.namelist() if name.startswith(project_name + "/")]
        archive.extractall(runtime, members=members)
    project = runtime / project_name
    hashes = {path.relative_to(project).as_posix(): digest(path)
              for path in project.rglob("*") if path.is_file()}
    return project, hashes


def execute(godot, project, runtime, folder, name, preset, milestone, count, load=None, *,
            level="easy", training_milestones=MILESTONES, worker="res://easy_worker.gd"):
    folder.mkdir(parents=True, exist_ok=True)
    metrics = folder / (name + ".jsonl")
    result_path = folder / (name + ".result.json")
    recording = folder / (name + ".mlpaths")
    checkpoint = load if load else folder / f"{milestone:05d}.json"
    phase = "evaluation" if load else "training"
    seed = EVAL_SEED if load else SEED
    env = os.environ.copy()
    env.update({
        "ML_COMPARISON_SEED": str(seed), "ML_COMPARISON_PHASE": phase,
        "ML_COMPARISON_MILESTONE": str(milestone), "ML_COMPARISON_METRICS": str(metrics),
        "ML_COMPARISON_RESULT": str(result_path), "APPDATA": str(runtime / "appdata" / folder.name),
    })
    Path(env["APPDATA"]).mkdir(parents=True, exist_ok=True)
    options = [
        "--episodes", str(count), "--level", level, "--preset", preset, "--stuck-detection", "on",
        "--mode", phase, "--save", str(checkpoint), "--save-every", str(count),
        "--record-every", "1" if load else "100", "--record-to", str(recording),
    ]
    if load:
        options += ["--load", str(load)]
    before = digest(load) if load else None
    command = [godot, "--headless", "--path", str(project), "--fixed-fps", "60",
               "--disable-render-loop", "--script", worker, "--", *options]
    log = folder / (name + ".log")
    with log.open("wb") as output:
        process = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=2700)
    if process.returncode or b"SCRIPT ERROR" in log.read_bytes():
        raise RuntimeError(f"{preset} {name} failed. See {log}")
    result = read(result_path)
    rows = [json.loads(line) for line in metrics.read_text(encoding="utf-8").splitlines()]
    assert result["status"] == "completed" and result["completed"] == len(rows) == count
    assert result["physics_hz"] == result["episode_limit_seconds"] == 60 and result["stuck_detection"]
    assert sum(row["outcome"] == "success" for row in rows) == result["wins"]
    if load:
        assert digest(load) == before
        saved = read(load)
        assert all(not row["training"] and row["training_episode"] == milestone
                   and row["updates"] == saved["updates"] and row["episode_seed"] == seed + index
                   for index, row in enumerate(rows))
    else:
        assert all(row["training"] and row["training_episode"] == index
                   for index, row in enumerate(rows, 1))
        for target in training_milestones:
            saved = read(folder / f"{target:05d}.json")
            assert saved["training_episodes"] == target and saved["preset_id"] == preset
            assert saved["updates"] == rows[target - 1]["updates"]
    result.update(checkpoint=checkpoint.name, checkpoint_sha256=digest(checkpoint), recording=recording.name)
    dump(result_path, result)
    if not load:
        with metrics.open("rb") as raw, gzip.open(metrics.with_suffix(".jsonl.gz"), "wb") as compressed:
            shutil.copyfileobj(raw, compressed)
        metrics.unlink()
    print(f"{folder.name} {name}: {result['wins']}/{count} wins ({result['seconds']:.1f}s wall)", flush=True)


def run_preset(godot, project, runtime, output, preset, label, level):
    folder = output / label
    folder.mkdir(exist_ok=False)
    execute(godot, project, runtime, folder, "training", preset, 10000, 10000, level=level)
    for milestone in MILESTONES:
        execute(godot, project, runtime, folder, f"eval-{milestone:05d}", preset, milestone,
                EVAL_RUNS, folder / f"{milestone:05d}.json", level=level)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--level", choices=("easy", "medium", "hard"), default="easy")
    parser.add_argument("--jobs", type=int, default=len(PRESETS))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--course-position", action="store_true")
    mode.add_argument("--untrained", action="store_true")
    args = parser.parse_args()
    output, runtime = args.output.resolve(), args.runtime.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (output / "settings.json").exists():
        raise FileExistsError("Use a fresh output directory so earlier results are preserved.")
    project, hashes = snapshot(runtime, args.course_position)
    variants = {preset: preset for preset in PRESETS}
    if args.course_position:
        variants = {"course_position": "fixed_reward_per_block"}
    if args.untrained:
        variants = {"untrained": "baseline"}
        shutil.copyfile(HERE / "empty_baseline.gd", project / "empty_baseline.gd")
        hashes["empty_baseline.gd"] = digest(project / "empty_baseline.gd")
    dump(output / "settings.json", {
        "level": args.level, "training_seed": None if args.untrained else SEED,
        "milestones": [0] if args.untrained else MILESTONES,
        "evaluation_seed_first": EVAL_SEED, "evaluation_runs_per_checkpoint": EVAL_RUNS,
        "stuck_detection": True, "episode_limit_seconds": 60, "training_record_every": 100,
        "presets": variants, "source_sha256": hashes,
        "extra_observation": "Signed horizontal distance to the orb in four-block bands" if args.course_position else None,
        "engine": subprocess.check_output([args.godot, "--version"], text=True).strip(),
    })
    if args.untrained:
        folder = output / "untrained"
        folder.mkdir()
        empty = folder / "00000.json"
        subprocess.run([args.godot, "--headless", "--path", str(project),
                        "--log-file", str(folder / "empty-checkpoint.log"),
                        "--script", "res://empty_baseline.gd", "--", str(empty)], check=True)
        execute(args.godot, project, runtime, folder, "eval-00000", "baseline", 0, EVAL_RUNS, empty,
                level=args.level)
        return
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_preset, args.godot, project, runtime, output, preset, label, args.level)
                   for label, preset in variants.items()]
        for future in as_completed(futures):
            future.result()


if __name__ == "__main__":
    main()
