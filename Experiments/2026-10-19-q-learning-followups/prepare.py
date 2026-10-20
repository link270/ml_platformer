"""Create isolated experimental projects from the frozen current baseline.

Usage: python3 prepare.py /tmp/platformer-followups
Does not change the playable project or its default checkpoint.
"""
import hashlib
import json
from pathlib import Path
import sys
import zipfile

HERE = Path(__file__).resolve().parent
BASELINE = HERE.parent / "2026-10-16-q-learning-long-exploration"
VARIANTS = ["discount_099", "horizontal_bins", "late_learning_rate"]


def replace(path, old, new):
    source = path.read_text()
    assert source.count(old) == 1, (path, old)
    path.write_text(source.replace(old, new))


def prepare(destination):
    destination = Path(destination)
    for variant in VARIANTS:
        root = destination / variant
        root.mkdir(parents=True, exist_ok=False)
        with zipfile.ZipFile(BASELINE / "experiment.zip") as archive:
            for item in archive.infolist():
                relative = Path(item.filename).relative_to("experiment")
                # Copy source, not old data, checkpoints or reproduction notes.
                if relative.suffix not in {".gd", ".tscn", ".godot", ".uid"}:
                    continue
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(item))
        agent = root / "Agents/QLearningAgent.gd"
        checkpoint = root / "Agents/QCheckpoint.gd"
        if variant == "discount_099":
            replace(agent, "var discount := 0.95", "var discount := 0.99")
        elif variant == "horizontal_bins":
            state = root / "Agents/QState.gd"
            replace(state, "const MAX_STATES := 1728 # 2^6 rays * 3 horizontal * 3 vertical * 3 motion.",
                    "const MAX_STATES := 3888 # 3^2 horizontal rays * 2^4 other rays * 3^3 direction/motion.")
            replace(state,
                    '\t\tbits += "1" if state.ray_hits[index] and state.ray_clearances[index] <= NEAR_DISTANCE else "0"',
                    '\t\tif index in [6, 2] and state.ray_hits[index] and state.ray_clearances[index] > NEAR_DISTANCE:\n'
                    '\t\t\tbits += "2" # Far hit: beyond one unit, within the existing two-unit ray.\n'
                    '\t\telse:\n'
                    '\t\t\tbits += "1" if state.ray_hits[index] and state.ray_clearances[index] <= NEAR_DISTANCE else "0"')
            replace(checkpoint, '"rays": State.RAY_INDICES,',
                    '"horizontal_bins": ["no_hit", "near_0_to_1", "far_1_to_2"], "rays": State.RAY_INDICES,')
            replace(checkpoint, "^[01]{6}", "^[012]{2}[01]{4}")
        else:
            replace(agent, "\t\ttraining_episodes += 1",
                    "\t\ttraining_episodes += 1\n"
                    "\t\t# Keep early learning unchanged; taper alpha after exploration reaches its floor.\n"
                    "\t\tlearning_rate = maxf(0.02, 0.1 - 0.08 * maxf(0.0, training_episodes - 3000.0) / 7000.0)")
            # A resumed schedule needs this project, not a constant-alpha loader.
            replace(checkpoint, '"rays": State.RAY_INDICES,',
                    '"learning_schedule": "alpha_0.1_through_3000_linear_to_0.02_at_10000", "rays": State.RAY_INDICES,')
        (root / "variant.txt").write_text(variant + "\n")
        (root / "check_variant.gd").write_bytes((HERE / "check_variant.gd").read_bytes())
        if variant == "horizontal_bins":
            (root / "probe_bins.gd").write_bytes((HERE / "probe_bins.gd").read_bytes())
        fingerprints = {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                        for name in json.loads((BASELINE / "settings.json").read_text())["source_fingerprints"]}
        (root / "source-fingerprints.json").write_text(json.dumps(fingerprints, indent=2) + "\n")
        print(root)


if __name__ == "__main__":
    prepare(sys.argv[1])
