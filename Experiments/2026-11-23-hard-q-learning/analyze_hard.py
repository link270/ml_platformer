"""Validate the Hard experiments and compare them with the Easy and Medium results."""

import argparse
from html import escape
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
MEDIUM = ROOT.parent / "2026-11-23-medium-q-learning"
sys.path.insert(0, str(MEDIUM))

from compare import (EASY, LABELS, TRANSFER, collect_all, collect_transfer, duration,
                     evaluation_cell, row_table, run_transfer)
from run import EVAL_RUNS, EVAL_SEED, MILESTONES, SEED, dump, read


def html_report(courses, transfers):
    hard = courses["Hard"]
    progress, evaluation, training, transferred = [], [], [], []
    for label, results in hard.items():
        if label == "untrained":
            continue
        heading = f"<tr><th>{escape(LABELS[label])}</th>"
        progress_cells = []
        for course in courses.values():
            batches = [course[label][n]["frozen"] for n in MILESTONES]
            counts = " / ".join(str(batch["wins"]) for batch in batches)
            tone = "full" if all(batch["wins"] == EVAL_RUNS for batch in batches) else ""
            times = [batch["median_seconds"] for batch in batches if batch["wins"]]
            best = f"<br>Best median {min(times):.2f} s" if times else ""
            progress_cells.append(f'<td class="{tone}"><strong>{counts}</strong>{best}</td>')
        progress.append(heading + "".join(progress_cells) + "</tr>")
        evaluation.append(heading + "".join(evaluation_cell(results[n], link=True, detail=True)
                                            for n in MILESTONES) + "</tr>")
        trained = results[10000]["training_through_milestone"]
        training_cells = [
            trained["first_win_episode"] or "—", duration(trained["first_win_seconds"]),
            duration(trained["fastest_seconds"]), duration(trained["median_seconds"]),
            duration(trained["mean_seconds"]), f'{trained["win_rate"]:.1%}', trained["longest_win_streak"],
            *(f'{results[n]["last_1000_training"]["win_rate"]:.1%}' for n in MILESTONES),
        ]
        training.append(heading + "".join(f"<td>{cell}</td>" for cell in training_cells) + "</tr>")
    for label in TRANSFER:
        transferred.append(f"<tr><th>{escape(LABELS[label])}</th>"
                           + "".join(evaluation_cell(row, link=course == "Hard")
                                     for course, row in transfers[label].items()) + "</tr>")
    return f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hard Q-learning results across three courses</title>
<style>
body{{margin:0;background:#f3f6f7;color:#17282d;font:16px/1.5 system-ui,sans-serif}}
main{{max-width:1260px;margin:auto;padding:2rem clamp(1rem,4vw,4rem) 4rem}}
h1{{font-size:clamp(2rem,4vw,3rem);margin:.1em 0;line-height:1.15}} h2{{margin-top:2rem}}
p{{max-width:88ch}} a{{color:#086477}} .scroll{{overflow:auto}} table{{width:100%;min-width:730px;
border-collapse:collapse;background:#fff;font-variant-numeric:tabular-nums}}
th,td{{text-align:left;padding:.5rem .65rem;border:1px solid #d4dfe2}} thead{{background:#dce9eb}}
.full{{background:#def1e9}} .zero{{background:#f9e9e6}}
</style>
<main><h1>Hard Q-learning results across three courses</h1>
<p>Hard · elevated gap chains · November 23, 2026</p>
<p><a href="findings.txt">Conclusions and filming picks</a> · <a href="summary.json">Full metrics</a> ·
<a href="START-HERE.txt">Playback and reproduction</a> ·
<a href="../2026-11-23-medium-q-learning/report.html">Medium comparison</a> ·
<a href="../2026-11-20-easy-q-learning/report.html">Easy results</a></p>
<h2>Matched wins across courses</h2>
<p>Each series gives frozen wins out of 30 at 1,000, 5,000, and 10,000 training runs. The fastest median gives the best successful time across the three checkpoints.</p>
{row_table(["Experiment", *courses], progress)}
<h2>Hard checkpoint evaluations</h2>
<p>Each table started evaluation from the same Hard spawn. Times are fastest / median / mean among successful frozen runs, in simulation seconds. When a policy never won, the table shows median best progress toward the orb. <a href="{hard["untrained"][0]["replay"]}">Untrained baseline recording</a>.</p>
{row_table(["Experiment", *(f"{n:,} trained" for n in MILESTONES)], evaluation)}
<h2>Hard training performance</h2>
<p>Training wins include exploration. Timing and longest streak cover all 10,000 training runs. The rightmost columns show win rates in the 1,000 runs ending at each checkpoint.</p>
{row_table(["Experiment", "First win #", "First win (s)", "Fastest (s)", "Median (s)", "Mean (s)", "All wins", "Longest streak", "Trials 1–1,000", "Trials 4,001–5,000", "Trials 9,001–10,000"], training)}
<h2>Easy policies on harder layouts</h2>
<p>The same two 5,000-run Easy Q-tables were evaluated on Medium and Hard without retraining. Those results are separate from the policies trained directly on Hard.</p>
{row_table(["Easy-trained policy", "Easy", "Medium", "Hard"], transferred)}
<h2>Test protocol</h2>
<p>All eight Hard agents started from empty tables with seed {SEED}. Each frozen batch used evaluation seeds {EVAL_SEED}–{EVAL_SEED + EVAL_RUNS - 1}. Every course used a 60-second overall limit and an eight-second stuck cutoff that resets after a full block of best progress toward the orb.</p>
<p>The three course comparisons use one shared training seed and one fixed spawn per course. Frozen evaluation can repeat identical routes. Prior Medium and Easy policies were not used to initialize Hard training.</p>
</main></html>
"""


def load_reference_data(hard, hard_transfer):
    easy = read(EASY / "summary.json")
    medium = read(MEDIUM / "summary.json")
    prior = {"Easy": easy, "Medium": medium["medium"]}
    courses = {name: {label: {int(n): row for n, row in results.items()} for label, results in data.items()}
               for name, data in prior.items()}
    courses["Hard"] = hard
    transfers = {label: {"Easy": courses["Easy"][label][5000],
                         "Medium": medium["easy_transfer_to_medium"][label],
                         "Hard": hard_transfer[label]} for label in TRANSFER}
    return courses, transfers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transfer", action="store_true")
    parser.add_argument("--godot")
    parser.add_argument("--runtime", type=Path)
    args = parser.parse_args()
    if args.transfer:
        if args.godot is None or args.runtime is None:
            parser.error("--transfer requires --godot and --runtime")
        run_transfer(args.godot, args.runtime.resolve(), root=ROOT, level="hard")
        return

    matched = ("source_sha256", "engine", "training_seed", "evaluation_seed_first",
               "evaluation_runs_per_checkpoint", "stuck_detection", "episode_limit_seconds")
    for directory in ("results", "position-results", "control-results"):
        settings = read(ROOT / directory / "settings.json")
        assert settings["level"] == "hard"
        for reference_dir, level in [(EASY, "easy"), (MEDIUM, "medium")]:
            reference = read(reference_dir / directory / "settings.json")
            assert reference["level"] == level and all(settings[key] == reference[key] for key in matched)
    hard = collect_all(ROOT)
    transfer = collect_transfer(root=ROOT)
    courses, transfers = load_reference_data(hard, transfer)
    dump(ROOT / "summary.json", {"hard": hard, "easy_transfer_to_hard": transfer})
    (ROOT / "report.html").write_text(html_report(courses, transfers), encoding="utf-8")
    for label, results in hard.items():
        print(label, [(n, row["frozen"]["wins"], duration(row["frozen"]["median_seconds"])) for n, row in results.items()])
    for label, row in transfer.items():
        print("Easy-to-Hard", label, row["frozen"]["wins"], row["frozen"]["outcomes"])


if __name__ == "__main__":
    main()
