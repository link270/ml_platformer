"""Validate the archived Easy runs and write the performance report."""

from collections import Counter
from pathlib import Path
from statistics import mean, median
from html import escape
from itertools import groupby
import gzip
import json
import struct

from run import EVAL_RUNS, EVAL_SEED, MILESTONES, PRESETS, SEED, digest, dump, read


ROOT = Path(__file__).resolve().parent
LABELS = {
    "untrained": "Untrained baseline",
    "baseline": "1. Original baseline",
    "time_penalty": "2. Small time penalty",
    "long_exploration": "3. Longer exploration",
    "discount_099": "4. Higher discount",
    "horizontal_bins": "5. Richer horizontal rays",
    "late_learning_rate": "6. Lower late learning rate",
    "fixed_reward_per_block": "7. Fixed reward per block",
    "course_position": "Fixed reward + course position",
}


def rows_from(path):
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8") as file:
        return [json.loads(line) for line in file]


def validate_recording(path, rows, training, milestone, manifest):
    with path.open("rb") as file:
        assert file.read(8) == b"MLPATH01", path
        size, = struct.unpack("<I", file.read(4))
        header = json.loads(file.read(size))
        assert header["level_scene"] == "res://Game/Levels/TrainingEasy.tscn"
        assert header["physics_hz"] == 60 and header["sample_bytes"] == 13
        assert header["stuck_detection"] and header["stuck_patience_seconds"] == 8
        assert header["starting_training_episodes"] == (0 if training else milestone)
        for path_key, checksum in header["source_sha256"].items():
            assert manifest["source_sha256"][path_key.removeprefix("res://")] == checksum
        for row in rows:
            size, samples = struct.unpack("<II", file.read(8))
            episode = json.loads(file.read(size))
            assert episode["episode"] == row["session_episode"] and episode["training"] == training
            assert episode["ticks"] == row["ticks"] == samples - 1
            assert episode["outcome"] == row["outcome"]
            assert len(file.read(samples * 13)) == samples * 13
        assert not file.read(1), path


def measures(rows):
    wins = [row for row in rows if row["outcome"] == "success"]
    times = [row["seconds"] for row in wins]
    first = wins[0] if wins else None
    fastest = min(wins, key=lambda row: row["ticks"]) if wins else None
    median_time = median(times) if times else None
    representative = min(wins, key=lambda row: abs(row["seconds"] - median_time)) if wins else None
    return {
        "runs": len(rows), "wins": len(wins), "outcomes": dict(Counter(row["outcome"] for row in rows)),
        "win_rate": len(wins) / len(rows),
        "first_win_episode": first["session_episode"] if first else None,
        "first_win_seconds": first["seconds"] if first else None,
        "fastest_episode": fastest["session_episode"] if fastest else None,
        "fastest_seconds": min(times) if times else None,
        "median_episode": representative["session_episode"] if representative else None,
        "median_seconds": median_time, "mean_seconds": mean(times) if times else None,
        "longest_win_streak": max(
            (sum(1 for _ in run) for won, run in groupby(rows, key=lambda row: row["outcome"] == "success") if won),
            default=0,
        ),
        "median_best_progress": median(row["best_progress"] for row in rows),
    }


def collect(directory, label):
    manifest = read(directory / "settings.json")
    folder = directory / label
    milestones = (0,) if label == "untrained" else MILESTONES
    training = None
    if milestones != (0,):
        assert manifest["training_seed"] == SEED
        training = rows_from(folder / "training.jsonl.gz")
        assert len(training) == 10000 and all(row["training"] and row["episode_seed"] == SEED
                                             for row in training)
        validate_recording(folder / "training.mlpaths", training[99::100], True, 10000, manifest)
    checkpoints = {}
    for milestone in milestones:
        stem = folder / f"eval-{milestone:05d}"
        frozen = rows_from(stem.with_suffix(".jsonl"))
        result = read(stem.with_suffix(".result.json"))
        checkpoint = folder / f"{milestone:05d}.json"
        recording = stem.with_suffix(".mlpaths")
        assert len(frozen) == EVAL_RUNS and digest(checkpoint) == result["checkpoint_sha256"]
        assert all(row["episode_seed"] == EVAL_SEED + index and row["training_episode"] == milestone
                   and row["training"] is False and row["updates"] == result["updates"]
                   for index, row in enumerate(frozen))
        validate_recording(recording, frozen, False, milestone, manifest)
        checkpoints[milestone] = {
            "frozen": measures(frozen),
            "training_through_milestone": measures(training[:milestone]) if training else None,
            "last_1000_training": measures(training[milestone - 1000:milestone]) if training else None,
            "replay": recording.relative_to(ROOT).as_posix(),
            "checkpoint": checkpoint.relative_to(ROOT).as_posix(),
        }
    return checkpoints


def duration(seconds):
    return "—" if seconds is None else f"{seconds:.2f}"


def html_report(all_results):
    fixed = all_results["fixed_reward_per_block"][5000]["frozen"]
    position = all_results["course_position"][10000]["frozen"]
    table = []
    training_table = []
    for label, checkpoints in all_results.items():
        cells = []
        for milestone in (0, *MILESTONES):
            if milestone not in checkpoints:
                cells.append("<td>—</td>")
                continue
            row = checkpoints[milestone]
            frozen = row["frozen"]
            tone = "full" if frozen["wins"] == EVAL_RUNS else ("zero" if not frozen["wins"] else "")
            timing = "fastest / median / mean · " + " / ".join(
                duration(frozen[key]) for key in ("fastest_seconds", "median_seconds", "mean_seconds")
            ) + " s" if frozen["wins"] else "No completions"
            cells.append(f'<td class="{tone}"><strong>{frozen["wins"]}/{EVAL_RUNS}</strong>'
                         f'<small>{timing}</small><a href="{escape(row["replay"])}">Recording</a></td>')
        table.append(f"<tr><th>{escape(LABELS[label])}</th>{''.join(cells)}</tr>")
        if 10000 in checkpoints:
            trained = checkpoints[10000]["training_through_milestone"]
            late = [f'<td>{checkpoints[m]["last_1000_training"]["win_rate"]:.1%}</td>' for m in MILESTONES]
            training_table.append(
                f'<tr><th>{escape(LABELS[label])}</th><td>{trained["first_win_episode"] or "—"}</td>'
                f'<td>{duration(trained["first_win_seconds"])}</td><td>{duration(trained["fastest_seconds"])}</td>'
                f'<td>{duration(trained["median_seconds"])}</td><td>{duration(trained["mean_seconds"])}</td>'
                f'<td>{trained["win_rate"]:.1%}</td><td>{trained["longest_win_streak"]}</td>{"".join(late)}</tr>'
            )
    return f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Easy course Q-learning comparison</title>
<style>
body{{font:16px/1.55 system-ui,sans-serif;background:#f3f6f7;color:#17282d;margin:0}}
main{{max-width:1250px;margin:auto;padding:2rem clamp(1rem,4vw,4rem) 4rem}}
h1{{font-size:clamp(1.8rem,4vw,3rem);margin-bottom:.2rem;letter-spacing:-.035em}}
h2{{margin-top:2.2rem}} p{{max-width:88ch}} a{{color:#086477}} small{{display:block}}
.scroll{{overflow:auto}} table{{border-collapse:collapse;background:white;min-width:850px;width:100%;font-variant-numeric:tabular-nums}}
td,th{{padding:.5rem .7rem;border:1px solid #d4dfe2;text-align:left}} thead{{background:#dce9eb}}
.full{{background:#def1e9}} .zero{{background:#f9e9e6}} td a{{font-size:.85rem}}
</style>
<main><h1>Easy course Q-learning comparison</h1>
<p>Easy · steps and hills · November 20, 2026</p>
<p>Film the empty baseline first, then Fixed reward per block at 5,000 runs ({fixed["wins"]}/{EVAL_RUNS}, {duration(fixed["median_seconds"])} s), then Fixed reward + course position at 10,000 ({position["wins"]}/{EVAL_RUNS}, {duration(position["median_seconds"])} s).</p>
<p><a href="filming-notes.txt">Filming notes and interpretation</a> · <a href="summary.json">Full metrics and checkpoint paths</a> · <a href="START-HERE.txt">Playback and reproducibility</a></p>
<h2>Frozen-policy evaluation</h2>
<p>Each checkpoint ran 30 evaluations with learning and epsilon exploration disabled. Times are simulation seconds for wins only.</p>
<div class="scroll"><table><thead><tr><th>Experiment</th><th>0 trained</th><th>1,000 trained</th><th>5,000 trained</th><th>10,000 trained</th></tr></thead>
<tbody>{''.join(table)}</tbody></table></div>
<h2>Training and sustained completion</h2>
<p>The first win is its episode number and duration. Fastest, median and mean cover successful training runs through episode 10,000. The three rightmost columns show training win rate in the 1,000 runs ending at each milestone.</p>
<div class="scroll"><table><thead><tr><th>Experiment</th><th>First win #</th><th>First win (s)</th><th>Fastest (s)</th><th>Median (s)</th><th>Mean (s)</th><th>Overall wins</th><th>Longest win streak</th><th>Through 1,000</th><th>Through 5,000</th><th>Through 10,000</th></tr></thead>
<tbody>{''.join(training_table)}</tbody></table></div>
<h2>Protocol</h2>
<p>Each trained agent started with an empty table and seed {SEED}. It trained continuously for 10,000 episodes. Each frozen evaluation used seeds {EVAL_SEED}–{EVAL_SEED + EVAL_RUNS - 1}, paired across checkpoints and experiments. Identical runs can occur because the course and spawn are fixed. Stuck detection was enabled for all agents (8 simulation seconds with no new block of best progress); the overall timeout was 60 seconds.</p>
<p>The extra variant adds the signed horizontal distance to the orb in four-block bands to Fixed reward per block. On this course that also tells the agent roughly where it is. Its different Q-table schema requires the experiment worker, and its recordings play in the standard game. The staged training and evaluation data, recording metadata and checkpoint hashes were validated before this report was generated.</p>
<p><a href="results/settings.json">Preset settings and frozen-source hashes</a> · <a href="position-results/settings.json">Course-position settings</a> · <a href="control-results/settings.json">Untrained control settings</a></p></main></html>
"""


def main():
    normal, extra, control = (ROOT / name for name in ("results", "position-results", "control-results"))
    normal_hashes = read(normal / "settings.json")["source_sha256"]
    extra_hashes = read(extra / "settings.json")["source_sha256"]
    control_hashes = read(control / "settings.json")["source_sha256"]
    assert control_hashes.keys() - normal_hashes.keys() == {"empty_baseline.gd"}
    assert all(control_hashes[name] == checksum for name, checksum in normal_hashes.items())
    assert {name for name, checksum in normal_hashes.items() if extra_hashes[name] != checksum} == {
        "Agents/QLearningAgent.gd", "Agents/QCheckpoint.gd"
    }
    data = {"untrained": collect(control, "untrained")}
    data.update({label: collect(normal, label) for label in PRESETS})
    data["course_position"] = collect(extra, "course_position")
    dump(ROOT / "summary.json", data)
    (ROOT / "report.html").write_text(html_report(data), encoding="utf-8")
    for label, checkpoints in data.items():
        print(label)
        for milestone, row in checkpoints.items():
            frozen = row["frozen"]
            print(milestone, frozen["wins"], *(duration(frozen[key]) for key in
                                              ("fastest_seconds", "median_seconds", "mean_seconds")))


if __name__ == "__main__":
    main()
