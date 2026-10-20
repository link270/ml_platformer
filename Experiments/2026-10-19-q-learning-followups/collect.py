"""Archive completed runs: python3 collect.py /tmp/platformer-followups.

Run analyze.py after writing findings.txt. Refresh SHA256SUMS.json last.
"""
import difflib
import hashlib
import json
from pathlib import Path
import shutil
import sys
import zipfile

from prepare import VARIANTS, BASELINE

HERE = Path(__file__).resolve().parent
RUNS = Path(sys.argv[1])
SEEDS = [12345, 42, 98765]
settings = json.loads((BASELINE / "settings.json").read_text())
expected_changes = {
    "discount_099": ["Agents/QLearningAgent.gd"],
    "horizontal_bins": ["Agents/QCheckpoint.gd", "Agents/QState.gd"],
    "late_learning_rate": ["Agents/QCheckpoint.gd", "Agents/QLearningAgent.gd"],
}
experiment = {
    "date": "2026-10-19", "engine": "Godot 4.7.1.stable.official.a13da4feb",
    "reference": "../2026-10-16-q-learning-long-exploration",
    "unchanged_reference_settings": settings,
    "variants": {
        "discount_099": {"discount": 0.99},
        "horizontal_bins": {
            "horizontal_ray_categories": {"0": "no hit within 2 units", "1": "hit at <=1 unit", "2": "hit at >1 to 2 units"},
            "other_four_rays": "unchanged binary", "maximum_state_count": 3888,
            "ray_range_units": 2},
        "late_learning_rate": {
            "after_each_training_episode": "max(0.02, 0.1 - 0.08 * max(0, training_episodes - 3000) / 7000)",
            "evaluation": "no learning or schedule updates"}
    },
    "protocol": {
        "seeds": SEEDS, "training_episodes_per_seed": 10000,
        "milestones": [0, 100, 300, 600, 1000, 2000, 3000, 5000, 10000],
        "evaluation_episodes_per_checkpoint": 30,
        "evaluation_seed": "training seed + 1000000",
        "training": "Uninterrupted, fresh Q-table for every run; checkpoints evaluated afterward.",
        "unchanged_diagnostic_sha256": "ceacd69fce5057de81ec11e2b9274105d6c7309a112e7a37447cc8e1f6ff6231",
        "saved_old_agent_probes": "Not repeated: these experiments train fresh agents.",
        "best_checkpoint_selection": "Retrospective; most wins, then fastest mean success, then earliest episode.",
        "parallel_processes": 3,
    },
    "scope": "Experiments only. Main game code, current defaults and normal user save are unchanged.",
    "limitations": [
        "Three seeds, one map and one spawn; repeated greedy episodes are often the same route.",
        "Only individual changes tested, no combinations.",
        "Selected best checkpoints use the same evaluation data; no held-out validation.",
        "Sparse checkpoints cannot establish an exact convergence episode.",
        "Checkpoint RNG state is not saved; resumed training is not bit-for-bit reproduction.",
    ],
}
verification = {"previous_archives": {}, "variants": {}}
for folder in HERE.parent.glob("2026-10-16-*"):
    hashes = json.loads((folder / "SHA256SUMS.json").read_text())
    for relative, digest in hashes.items():
        assert hashlib.sha256((folder / relative).read_bytes()).hexdigest() == digest
    verification["previous_archives"][folder.name] = {"files_verified": len(hashes)}
for filename, digest in settings["source_fingerprints"].items():
    assert hashlib.sha256((HERE.parent.parent / filename).read_bytes()).hexdigest() == digest, filename
verification["main_game_core_sources_unchanged"] = True
with zipfile.ZipFile(BASELINE / "experiment.zip") as baseline_zip:
    for variant in VARIANTS:
        source = RUNS / variant
        destination = HERE / variant
        for folder in ["raw-data", "checkpoints", "validation"]:
            (destination / folder).mkdir(parents=True, exist_ok=True)
        fingerprints = json.loads((source / "source-fingerprints.json").read_text())
        changed = sorted(name for name, value in fingerprints.items()
                         if settings["source_fingerprints"][name] != value)
        assert changed == expected_changes[variant], (variant, changed)
        assert hashlib.sha256((source / "diagnose.gd").read_bytes()).hexdigest() == experiment["protocol"]["unchanged_diagnostic_sha256"]
        patch = ""
        for name in changed:
            old = baseline_zip.read("experiment/" + name).decode().splitlines(keepends=True)
            new = (source / name).read_text().splitlines(keepends=True)
            patch += "".join(difflib.unified_diff(old, new, fromfile="current/" + name, tofile=variant + "/" + name))
        (destination / "changes.patch").write_text(patch)
        for seed in SEEDS:
            result_path = source / f"results-{seed}.json"
            result = json.loads(result_path.read_text())
            assert len(result["training"]) == 10000 and len(result["evaluations"]) == 9
            assert result["source"] == fingerprints
            assert "DONE seed " in (source / f"run-{seed}.log").read_text()
            for evaluation in result["evaluations"]:
                assert len(evaluation["runs"]) == 30
                filename = f'checkpoint-{seed}-{evaluation["episode"]}.json'
                checkpoint = json.loads((source / filename).read_text())
                assert checkpoint["training_episodes"] == evaluation["episode"]
                assert len(checkpoint["q_table"]) == evaluation["rows"]
                if variant == "late_learning_rate":
                    expected = max(.02, .1 - .08 * max(0, evaluation["episode"] - 3000) / 7000)
                    assert abs(checkpoint["learning_rate"] - expected) < 1e-12
                if variant == "discount_099":
                    assert checkpoint["discount"] == .99
                shutil.copy2(source / filename, destination / "checkpoints" / filename)
            if variant == "late_learning_rate":
                reference = json.loads((BASELINE / f"raw-data/results-{seed}.json").read_text())
                assert result["training"][:3000] == reference["training"][:3000], seed
            shutil.copy2(result_path, destination / "raw-data" / result_path.name)
        for filename, marker in [
            ("variant-check.log", "Variant check passed"),
            ("check_training_trace.log", "Training trace check passed"),
            ("check_q_checkpoint.log", "checkpoint"),
        ]:
            text = (source / filename).read_text()
            assert marker.lower() in text.lower()
            assert "SCRIPT ERROR" not in text and "Assertion failed" not in text
        for log in source.glob("*.log"):
            shutil.copy2(log, destination / "validation" / log.name)
        if variant == "horizontal_bins":
            shutil.copy2(source / "bin-alias-probe.json", destination / "raw-data/bin-alias-probe.json")
            probe = json.loads((source / "bin-alias-probe.json").read_text())
            old_probe = json.loads((BASELINE / "raw-data/alias-probe.json").read_text())
            assert [(p["x"], p["y"]) for p in probe] == [(p["x"], p["y"]) for p in old_probe]
            assert len(probe) == 7
            assert sum(p["horizontal_bin_key"] == "000101|1|1|0" for p in probe) == 5
            assert sum(p["horizontal_bin_key"] == "020101|1|1|0" for p in probe) == 2
        shutil.copy2(source / "source-fingerprints.json", destination / "source-fingerprints.json")
        with zipfile.ZipFile(destination / "experiment.zip", "w", zipfile.ZIP_DEFLATED) as frozen:
            for path in source.rglob("*"):
                relative = path.relative_to(source)
                if not path.is_file() or any(part.startswith(".") for part in relative.parts):
                    continue
                if path.suffix not in {".gd", ".godot", ".tscn", ".uid"} and path.name not in {
                    "variant.txt", "source-fingerprints.json"} and not path.name.startswith("checkpoint-"):
                    continue
                frozen.write(path, "experiment/" + str(relative))
        verification["variants"][variant] = {
            "source_changes": changed, "fresh_training_episodes": 30000, "frozen_evaluations": 810,
            "checks": ["variant settings/boundaries/schedule/checkpoint roundtrip", "checkpoint regression",
                       "visible/headless full physics and learning trace parity (3 seeds, 50 episodes each)"],
            "diagnostic_unchanged": True,
        }
shutil.copy2(RUNS / VARIANTS[0] / "Level.tscn", HERE / "level-for-report.tscn")
experiment["source_fingerprints"] = {
    variant: json.loads((RUNS / variant / "source-fingerprints.json").read_text()) for variant in VARIANTS}
verification["late_learning_rate_matches_reference_through_3000_episodes_all_seeds"] = True
verification["startup_note"] = "Godot prints a macOS CA certificate lookup error in this sandbox; scripts complete and checks pass. No networking is used."
(HERE / "settings.json").write_text(json.dumps(experiment, indent=2) + "\n")
(HERE / "verification.json").write_text(json.dumps(verification, indent=2) + "\n")
print("Collected and verified all three experiments.")
