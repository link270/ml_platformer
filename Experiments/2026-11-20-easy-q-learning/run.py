"""Train and evaluate fresh Q-tables on the Easy course using a frozen project."""

from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import argparse
import gzip
import hashlib
import json
import os
import shutil
import subprocess


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SEED = 78436291
EVAL_SEED = 78436300
MILESTONES = (1000, 5000, 10000)
EVAL_RUNS = 30
PRESETS = (
    "baseline", "time_penalty", "long_exploration", "discount_099",
    "horizontal_bins", "late_learning_rate", "fixed_reward_per_block",
)
WORKER = Path("Experiments/2026-10-29-medium-reward-comparison/worker.gd")
SOURCE_FOLDERS = ("Agents", "Game", "Training", "UI")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dump(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def snapshot(runtime):
    project = runtime / "project"
    project.mkdir(parents=True, exist_ok=False)
    files = [Path("project.godot"), WORKER]
    for name in SOURCE_FOLDERS:
        files.extend(path.relative_to(ROOT) for path in (ROOT / name).rglob("*")
                     if path.is_file() and path.suffix in {".gd", ".uid", ".tscn", ".tres"})
    hashes = {}
    for relative in sorted(files):
        target = project / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, target)
        hashes[relative.as_posix()] = digest(target)
    shutil.copyfile(HERE / "worker.gd", project / "easy_worker.gd")
    hashes["easy_worker.gd"] = digest(project / "easy_worker.gd")
    return project, hashes


def add_course_position(project, hashes):
    """Give the fixed-reward agent one extra observation in the frozen copy."""
    agent_path = "Agents/QLearningAgent.gd"
    checkpoint_path = "Agents/QCheckpoint.gd"
    agent = (project / agent_path).read_text(encoding="utf-8")
    expression = 'var key := State.encode(state, preset_id == "horizontal_bins")'
    assert agent.count(expression) == 2
    agent = agent.replace(expression, expression + '''
	if preset_id == "fixed_reward_per_block":
		key += "|%d" % floori(state.orb_offset.x / 4.0)''')
    (project / agent_path).write_text(agent, encoding="utf-8")
    checkpoint = (project / checkpoint_path).read_text(encoding="utf-8")
    marker = '\t# JSON reads all numbers as floats, including numbers inside arrays.'
    assert checkpoint.count(marker) == 1
    checkpoint = checkpoint.replace(marker, '\t\tschema.orb_x_band_blocks = 4\n' + marker)
    marker = '\tif not table is Dictionary or table.size() > max_states:'
    assert checkpoint.count(marker) == 1
    checkpoint = checkpoint.replace(marker, '\tif preset_id == "fixed_reward_per_block":\n\t\tmax_states *= 64\n' + marker)
    pattern = r'key_pattern.compile("^" + rays + "\\|(-1|0|1)\\|(-1|0|1)\\|[012]\\z")'
    replacement = (
        r'var band := "\\|-?[0-9]+" if preset_id == "fixed_reward_per_block" else ""'
        "\n\t" + r'key_pattern.compile("^" + rays + "\\|(-1|0|1)\\|(-1|0|1)\\|[012]" + band + "\\z")'
    )
    assert checkpoint.count(pattern) == 1
    (project / checkpoint_path).write_text(checkpoint.replace(pattern, replacement), encoding="utf-8")
    for relative in (agent_path, checkpoint_path):
        hashes[relative] = digest(project / relative)


def execute(godot, project, runtime, folder, name, preset, milestone, count, load=None):
    folder.mkdir(parents=True, exist_ok=True)
    metrics = folder / (name + ".jsonl")
    result_path = folder / (name + ".result.json")
    recording = folder / (name + ".mlpaths")
    checkpoint = load if load else folder / "10000.json"
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
        "--episodes", str(count), "--level", "easy", "--preset", preset, "--stuck-detection", "on",
        "--mode", phase, "--save", str(checkpoint), "--save-every", "10000",
        "--record-every", "1" if load else "100", "--record-to", str(recording),
    ]
    if load:
        options += ["--load", str(load)]
    before = digest(load) if load else None
    command = [godot, "--headless", "--path", str(project), "--fixed-fps", "60",
               "--disable-render-loop", "--script", "res://easy_worker.gd", "--", *options]
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
        for target in MILESTONES:
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


def run_preset(godot, project, runtime, output, preset, label):
    folder = output / label
    folder.mkdir(exist_ok=False)
    execute(godot, project, runtime, folder, "training", preset, 10000, 10000)
    for milestone in MILESTONES:
        execute(godot, project, runtime, folder, f"eval-{milestone:05d}", preset, milestone,
                EVAL_RUNS, folder / f"{milestone:05d}.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=len(PRESETS))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--course-position", action="store_true")
    mode.add_argument("--untrained", action="store_true")
    args = parser.parse_args()
    output, runtime = args.output.resolve(), args.runtime.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (output / "settings.json").exists():
        raise FileExistsError("Use a fresh output directory so earlier results are preserved.")
    project, hashes = snapshot(runtime)
    variants = {preset: preset for preset in PRESETS}
    if args.course_position:
        add_course_position(project, hashes)
        variants = {"course_position": "fixed_reward_per_block"}
    if args.untrained:
        variants = {"untrained": "baseline"}
        shutil.copyfile(HERE / "empty_baseline.gd", project / "empty_baseline.gd")
        hashes["empty_baseline.gd"] = digest(project / "empty_baseline.gd")
    dump(output / "settings.json", {
        "level": "easy", "training_seed": None if args.untrained else SEED,
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
        execute(args.godot, project, runtime, folder, "eval-00000", "baseline", 0, EVAL_RUNS, empty)
        return
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_preset, args.godot, project, runtime, output, preset, label)
                   for label, preset in variants.items()]
        for future in as_completed(futures):
            future.result()


if __name__ == "__main__":
    main()
