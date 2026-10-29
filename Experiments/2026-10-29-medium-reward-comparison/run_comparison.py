"""Run the frozen Medium reward comparison; existing completed stages are reused."""

from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import time


ROOT = Path(__file__).resolve().parent


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_rows(path):
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--smoke", action="store_true", help="Two one-episode instrumentation checks, outside the comparison.")
    parser.add_argument("--diagnose-9000", action="store_true", help="Matched post-hoc evaluation of the 9,000-episode pair after final-checkpoint regression.")
    args = parser.parse_args()
    settings = json.loads((ROOT / "settings.json").read_text(encoding="utf-8"))
    project = Path(settings["frozen_project"])
    godot = settings["godot"]
    progress = {"started_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "stages": []}
    progress_path = ROOT / ("smoke-progress.json" if args.smoke else ("diagnostic-progress.json" if args.diagnose_9000 else "progress.json"))

    def run(preset, phase, milestone, count, seed, load=None, offset=0):
        folder = ROOT / preset / ("smoke" if args.smoke else phase)
        folder.mkdir(parents=True, exist_ok=True)
        stem = folder / f"{milestone:05d}"
        done_path = Path(str(stem) + ".done.json")
        metrics = Path(str(stem) + ".episodes.jsonl")
        result_path = Path(str(stem) + ".result.json")
        checkpoint = ROOT / preset / "checkpoints" / f"checkpoint-{settings['base_seed']}-{milestone}.json"
        checkpoint.parent.mkdir(parents=True, exist_ok=True)
        if args.smoke:
            checkpoint = folder / "smoke-checkpoint.json"
        if done_path.exists():
            done = json.loads(done_path.read_text())
            assert done["seed"] == seed and done["completed"] == count
            assert len(read_rows(metrics)) == count
            if phase == "training":
                assert sha256(checkpoint) == done["checkpoint_sha256"]
            progress["stages"].append(done)
            progress_path.write_text(json.dumps(progress, indent=2) + "\n")
            return checkpoint, done
        if metrics.exists() or result_path.exists() or (phase == "training" and checkpoint.exists()):
            raise RuntimeError(f"Refusing to overwrite an incomplete stage: {stem}")
        training = phase == "training"
        env = os.environ.copy()
        env.update({
            "ML_COMPARISON_SEED": str(seed), "ML_COMPARISON_PHASE": phase,
            "ML_COMPARISON_MILESTONE": str(milestone),
            "ML_COMPARISON_METRICS": str(metrics), "ML_COMPARISON_RESULT": str(result_path),
        })
        env["APPDATA"] = str(Path(settings["runtime_directory"]) / "appdata")
        env["TEMP"] = env["TMP"] = str(Path(settings["runtime_directory"]) / "tmp")
        Path(env["APPDATA"]).mkdir(parents=True, exist_ok=True)
        Path(env["TEMP"]).mkdir(parents=True, exist_ok=True)
        interval = settings["training_record_every"] if training else 1
        recording = Path(str(stem) + ".mlpaths")
        options = [
            "--episodes", str(count), "--level", "medium", "--preset", preset,
            "--stuck-detection", "on", "--mode", "training" if training else "evaluation",
            "--save", str(checkpoint if training else load), "--save-every", "100",
            "--record-every", str(interval), "--record-to", str(recording),
            "--record-offset", str(offset),
        ]
        if load is not None:
            options += ["--load", str(load)]
        command = [godot, "--headless", "--path", str(project), "--fixed-fps", "60",
                   "--disable-render-loop", "--log-file", str(stem) + ".log",
                   "--script", "res://experiment_worker.gd", "--", *options]
        source_hash = sha256(load) if load else None
        process = subprocess.run(command, env=env, capture_output=True, text=True, timeout=900)
        Path(str(stem) + ".console.txt").write_text(process.stdout + process.stderr, encoding="utf-8")
        if process.returncode or "SCRIPT ERROR" in process.stdout + process.stderr:
            raise RuntimeError(process.stdout + process.stderr)
        result = json.loads(result_path.read_text())
        rows = read_rows(metrics)
        assert result["status"] == "completed" and result["completed"] == count and len(rows) == count
        assert result["physics_hz"] == 60 and result["episode_limit_seconds"] == 60
        assert result["stuck_detection"] and result["patience_seconds"] == 8
        assert result["settings"] == settings["shared_learning_settings"]
        assert sum(row["outcome"] == "success" for row in rows) == result["wins"]
        if training:
            data = json.loads(checkpoint.read_text())
            assert data["preset_id"] == preset and data["training_episodes"] == milestone
            assert rows[0]["training_episode"] == offset + 1 and rows[-1]["training_episode"] == milestone
            result["checkpoint_sha256"] = sha256(checkpoint)
        else:
            assert sha256(load) == source_hash
            source = json.loads(Path(load).read_text())
            assert all(not row["training"] and row["training_episode"] == milestone and row["updates"] == source["updates"] for row in rows)
        result.update(command=command, checkpoint=str(checkpoint if training else load), metrics=str(metrics), recording=str(recording))
        done_path.write_text(json.dumps(result, indent=2) + "\n")
        progress["stages"].append(result)
        progress_path.write_text(json.dumps(progress, indent=2) + "\n")
        print(f"{preset} | {phase} | milestone {milestone:,} | {result['wins']}/{count} wins | "
              f"deaths {result['deaths']} stuck {result['stuck']} timeouts {result['timeouts']} | {result['seconds']:.1f}s", flush=True)
        return checkpoint, result

    if args.smoke:
        for preset in settings["presets"]:
            run(preset, "training", 1, 1, settings["base_seed"])
        return

    if args.diagnose_9000:
        for preset in settings["presets"]:
            checkpoint = ROOT / preset / "checkpoints" / f"checkpoint-{settings['base_seed']}-9000.json"
            run(preset, "diagnostic_evaluation", 9000, settings["final_evaluation_episodes"],
                settings["final_evaluation_seed"], checkpoint)
        progress["complete"] = True
        progress["post_hoc"] = True
        progress_path.write_text(json.dumps(progress, indent=2) + "\n")
        print("Matched post-hoc 9,000-episode checkpoint evaluations completed.", flush=True)
        return

    checkpoints = {preset: None for preset in settings["presets"]}
    for index, milestone in enumerate(settings["milestones"]):
        order = settings["presets"] if index % 2 == 0 else list(reversed(settings["presets"]))
        for preset in order:
            checkpoint, _ = run(preset, "training", milestone, settings["chunk_episodes"],
                                settings["training_seeds"][index], checkpoints[preset],
                                offset=milestone - settings["chunk_episodes"])
            checkpoints[preset] = checkpoint
            run(preset, "check_in", milestone, 1, settings["check_in_seeds"][index], checkpoint)
    for preset in settings["presets"]:
        run(preset, "final_evaluation", 10000, settings["final_evaluation_episodes"],
            settings["final_evaluation_seed"], checkpoints[preset])
    progress["completed_at_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    progress["complete"] = True
    progress_path.write_text(json.dumps(progress, indent=2) + "\n")
    print("Both matched 10,000-episode training sessions and final evaluations completed.", flush=True)


if __name__ == "__main__":
    main()
