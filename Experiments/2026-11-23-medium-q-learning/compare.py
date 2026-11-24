"""Compare the matched Medium and Easy experiments and check two Easy policies on Medium."""

import argparse
from html import escape
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
EASY = ROOT.parent / "2026-11-20-easy-q-learning"
sys.path.insert(0, str(EASY))

from analyze import LABELS, collect_all, duration, measures, rows_from, validate_recording
from run import EVAL_RUNS, EVAL_SEED, MILESTONES, SEED, digest, dump, execute, read, snapshot


TRANSFER = ("fixed_reward_per_block", "course_position")


def source_directory(label):
    return "position-results" if label == "course_position" else "results"


def transfer_checkpoint(label, training_root, milestone):
    return training_root / source_directory(label) / label / f"{milestone:05d}.json"


def run_transfer(godot, runtime, *, root=ROOT, level="medium", training_root=EASY, milestone=5000):
    for label in TRANSFER:
        project_root = runtime / label
        project, hashes = snapshot(project_root, label == "course_position")
        manifest = read(root / source_directory(label) / "settings.json")
        assert manifest["source_sha256"] == hashes
        execute(godot, project, project_root, root / "transfer-results" / label, f"eval-{milestone:05d}",
                "fixed_reward_per_block", milestone, EVAL_RUNS,
                transfer_checkpoint(label, training_root, milestone), level=level)


def collect_transfer(*, root=ROOT, training_root=EASY, milestone=5000):
    data = {}
    for label in TRANSFER:
        stem = root / "transfer-results" / label / f"eval-{milestone:05d}"
        result = read(stem.with_suffix(".result.json"))
        assert result["checkpoint_sha256"] == digest(transfer_checkpoint(label, training_root, milestone))
        rows = rows_from(stem.with_suffix(".jsonl"))
        assert len(rows) == EVAL_RUNS and all(
            row["episode_seed"] == EVAL_SEED + index and not row["training"]
            and row["training_episode"] == milestone and row["updates"] == result["updates"]
            for index, row in enumerate(rows)
        )
        replay = stem.with_suffix(".mlpaths")
        validate_recording(replay, rows, False, milestone, read(root / source_directory(label) / "settings.json"))
        data[label] = {"frozen": measures(rows), "replay": replay.relative_to(root).as_posix()}
    return data


def evaluation_cell(row, *, link=False, detail=False):
    frozen = row["frozen"]
    wins = frozen["wins"]
    tone = "full" if wins == EVAL_RUNS else ("zero" if wins == 0 else "")
    if wins and detail:
        detail_text = " / ".join(duration(frozen[k]) for k in ("fastest_seconds", "median_seconds", "mean_seconds")) + " s"
    elif wins:
        detail_text = duration(frozen["median_seconds"]) + " s median"
    else:
        detail_text = f"{frozen['median_best_progress']:.1%} median best progress"
    replay = f'<br><a href="{escape(row["replay"])}">Replay</a>' if link else ""
    return f'<td class="{tone}"><strong>{wins}/{EVAL_RUNS}</strong><br>{detail_text}{replay}</td>'


def row_table(headers, rows):
    return ("<div class='scroll'><table><thead><tr>" + "".join(f"<th>{title}</th>" for title in headers)
            + "</tr></thead><tbody>" + "".join(rows) + "</tbody></table></div>")


def html_report(easy_results, medium_results, transfers):
    easy = {label: {int(k): v for k, v in results.items()} for label, results in easy_results.items()}
    compared, timings, training, transferred = [], [], [], []
    for label, results in medium_results.items():
        if label == "untrained":
            continue
        caption = f"<tr><th>{escape(LABELS[label])}</th>"
        paired = "".join(evaluation_cell(item) for n in MILESTONES for item in (easy[label][n], results[n]))
        compared.append(caption + paired + "</tr>")
        timings.append(caption + "".join(evaluation_cell(results[n], link=True, detail=True) for n in MILESTONES) + "</tr>")
        all_runs = results[10000]["training_through_milestone"]
        training_cells = [
            all_runs["first_win_episode"] or "—",
            duration(all_runs["first_win_seconds"]), duration(all_runs["fastest_seconds"]),
            duration(all_runs["median_seconds"]), duration(all_runs["mean_seconds"]),
            f'{all_runs["win_rate"]:.1%}', all_runs["longest_win_streak"],
            *(f'{results[n]["last_1000_training"]["win_rate"]:.1%}' for n in MILESTONES),
        ]
        training.append(caption + "".join(f"<td>{cell}</td>" for cell in training_cells) + "</tr>")
    for label, row in transfers.items():
        transferred.append(f"<tr><th>{escape(LABELS[label])}</th>" + evaluation_cell(easy[label][5000])
                           + evaluation_cell(row, link=True) + "</tr>")
    paired_header = ["Experiment", *(f"{course} {n:,}" for n in MILESTONES for course in ("Easy", "Medium"))]
    time_header = ["Experiment", *(f"{n:,} trained" for n in MILESTONES)]
    training_header = ["Experiment", "First win #", "First win (s)", "Fastest (s)", "Median (s)", "Mean (s)",
                       "All training wins", "Longest win streak", "Trials 1–1,000", "Trials 4,001–5,000",
                       "Trials 9,001–10,000"]
    return f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Medium vs Easy Q-learning results</title>
<style>
body{{margin:0;background:#f3f6f7;color:#17282d;font:16px/1.5 system-ui,sans-serif}}
main{{max-width:1330px;margin:auto;padding:2rem clamp(1rem,4vw,4rem) 4rem}}
h1{{font-size:clamp(2rem,4vw,3rem);margin:.1em 0;line-height:1.15}} h2{{margin-top:2rem}}
p{{max-width:88ch}} a{{color:#086477}} .scroll{{overflow:auto}} table{{width:100%;min-width:750px;
border-collapse:collapse;background:#fff;font-variant-numeric:tabular-nums}}
th,td{{text-align:left;padding:.5rem .65rem;border:1px solid #d4dfe2}} thead{{background:#dce9eb}}
.full{{background:#def1e9}} .zero{{background:#f9e9e6}}
</style>
<main><h1>Medium vs Easy Q-learning results</h1>
<p>Medium · platforms and gaps · November 23, 2026</p>
<p><a href="findings.txt">Conclusions and filming picks</a> · <a href="summary.json">Full metrics</a> ·
<a href="START-HERE.txt">Playback and reproduction</a> ·
<a href="../2026-11-20-easy-q-learning/report.html">Easy results</a></p>
<h2>Matched checkpoint comparison</h2>
<p>Both courses used the same starting training seed, budgets, settings, and frozen evaluation seeds. The empty baseline went 0/30 on both. Each cell shows frozen wins and the median winning time, or median best progress toward the orb when there were no wins.</p>
{row_table(paired_header, compared)}
<h2>Medium completion times</h2>
<p>Times are fastest / median / mean for successful frozen runs, in simulation seconds. The replay links open the associated files. Select them with Playback recordings in the Godot project.</p>
{row_table(time_header, timings)}
<h2>Medium training and sustained completion</h2>
<p>Training includes exploration. The timings and longest winning streak cover the full 10,000 training runs. The rightmost columns show the training win rate in the 1,000 runs ending at each checkpoint.</p>
{row_table(training_header, training)}
<h2>Easy policies on Medium without retraining</h2>
<p>These two checkpoints were trained on Easy and both won 30/30 there at 5,000 runs. The exact tables were evaluated again from the Medium spawn. These 60 attempts are separate from the Medium-trained results.</p>
{row_table(["Easy-trained policy", "Easy", "Medium"], transferred)}
<h2>Test protocol</h2>
<p>Each Medium variant started with an empty Q-table and seed {SEED}. Workers trained continuously through 10,000 runs. Each frozen batch used the same 30 evaluation seeds, {EVAL_SEED}–{EVAL_SEED + EVAL_RUNS - 1}. All runs had a 60-second limit and an eight-second stuck cutoff that resets after a full block of best progress toward the orb.</p>
<p>Each course has one tested training seed and one fixed spawn. Frozen evaluation can repeat identical routes. The two transfer clips test these particular tables and layouts.</p>
</main></html>
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transfer", action="store_true")
    parser.add_argument("--godot")
    parser.add_argument("--runtime", type=Path)
    args = parser.parse_args()
    if args.transfer:
        if args.godot is None or args.runtime is None:
            parser.error("--transfer requires --godot and --runtime")
        run_transfer(args.godot, args.runtime.resolve())
        return

    for directory in ("results", "position-results", "control-results"):
        settings = read(ROOT / directory / "settings.json")
        reference = read(EASY / directory / "settings.json")
        assert settings["level"] == "medium" and reference["level"] == "easy"
        shared = ("source_sha256", "engine", "training_seed", "evaluation_seed_first",
                  "evaluation_runs_per_checkpoint", "stuck_detection", "episode_limit_seconds")
        assert all(settings[key] == reference[key] for key in shared)
    medium = collect_all(ROOT)
    easy = read(EASY / "summary.json")
    transferred = collect_transfer()
    dump(ROOT / "summary.json", {"medium": medium, "easy_transfer_to_medium": transferred})
    (ROOT / "report.html").write_text(html_report(easy, medium, transferred), encoding="utf-8")
    for label, results in medium.items():
        print(label, [(n, row["frozen"]["wins"], duration(row["frozen"]["median_seconds"])) for n, row in results.items()])
    for label, row in transferred.items():
        print("Easy-to-Medium", label, row["frozen"]["wins"], row["frozen"]["outcomes"])


if __name__ == "__main__":
    main()
