"""Compare recording off/all/every tenth using the real, seeded training worker."""

import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument("--episodes", type=int, default=1000)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--output", type=Path, default=Path("Docs/recording-benchmark.json"))
    args = parser.parse_args()
    if args.episodes < 1 or args.repeats < 1:
        parser.error("episodes and repeats must be positive")
    project = Path(__file__).resolve().parents[1]
    treatments = [0, 1, 10]
    runs = []
    with tempfile.TemporaryDirectory(prefix="ml-platformer-recording-benchmark-") as scratch:
        directory = Path(scratch)

        def run(name, interval, episodes):
            checkpoint = directory / f"{name}.json"
            recording = directory / f"{name}.mlpaths"
            command = [
                args.godot, "--headless", "--path", str(project),
                "--fixed-fps", "60", "--disable-render-loop",
                "--log-file", str(directory / f"{name}.log"),
                "--script", "res://Training/benchmark_training.gd", "--",
                "--episodes", str(episodes), "--save", str(checkpoint),
                "--record-every", str(interval),
            ]
            if interval:
                command += ["--record-to", str(recording)]
            process = subprocess.run(command, capture_output=True, text=True, timeout=600)
            result_path = Path(str(checkpoint) + ".benchmark.json")
            if process.returncode or not result_path.exists():
                raise RuntimeError(process.stdout + process.stderr)
            result = json.loads(result_path.read_text(encoding="utf-8"))
            result["record_every"] = interval
            result["disk_bytes"] = recording.stat().st_size if recording.exists() else 0
            if result["disk_bytes"] != result["recording_bytes"]:
                raise RuntimeError("Recording byte counter differs from actual file size")
            expected = episodes // interval if interval else 0
            if result["recorded_episodes"] != expected:
                raise RuntimeError("Incorrect number of sampled episodes")
            return result

        run("warmup", 0, min(100, args.episodes))
        for repetition in range(args.repeats):
            order = treatments[repetition % 3:] + treatments[:repetition % 3]
            for interval in order:
                result = run(f"repeat-{repetition}-every-{interval}", interval, args.episodes)
                result["repeat"] = repetition + 1
                runs.append(result)
                print(f"Repeat {repetition + 1}, every {interval}: "
                      f"{result['seconds']:.3f}s, {result['disk_bytes']:,} bytes", flush=True)

    fingerprints = {result["behavior_sha256"] for result in runs}
    if len(fingerprints) != 1:
        raise RuntimeError("Recording changed the training behavior fingerprint")
    medians = {}
    for interval in treatments:
        selected = [result for result in runs if result["record_every"] == interval]
        medians[str(interval)] = {
            field: statistics.median(result[field] for result in selected)
            for field in ["seconds", "episodes_per_second", "steps_per_second",
                          "disk_bytes", "recorded_episodes", "recorded_samples"]
        }
    baseline = medians["0"]
    for median in medians.values():
        median["elapsed_increase_percent"] = 100 * (median["seconds"] / baseline["seconds"] - 1)
        median["throughput_loss_percent"] = 100 * (1 - median["episodes_per_second"] / baseline["episodes_per_second"])
    report = {
        "environment": {"platform": platform.platform(),
                        "processor": platform.processor(),
                        "godot": subprocess.check_output([args.godot, "--version"], text=True).strip()},
        "method": "Serial rotating order, one warmup, fresh seed 12345 each run; real headless worker at fixed 60 Hz, default preset, saves every 100 episodes. Timings include capture initialization, training, writes, flushes and closes; exclude process startup and final fingerprint generation. Trails/rendering disabled. No compression.",
        "episodes_per_run": args.episodes,
        "repeats": args.repeats,
        "behavior_identical": True,
        "runs": runs,
        "medians": medians,
        "source_sha256": {},
    }
    import hashlib
    for name in ["Game/Level.gd", "Training/EpisodeRecorder.gd", "Training/train.gd",
                 "Training/benchmark_training.gd", "Training/benchmark_recording.py"]:
        report["source_sha256"][name] = hashlib.sha256((project / name).read_bytes()).hexdigest()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(medians, indent=2))


if __name__ == "__main__":
    main()
