"""Validate and summarize longer Hard training runs."""

import gzip
from html import escape
import json

from run_long import EVAL_RUNS, EVAL_SEED, HARD, HERE, MILESTONES, PRESETS, SEED, TOTAL, digest, dump, read
from analyze import LABELS, duration, measures, rows_from, validate_recording


def collect(folder, preset, manifest):
    training = rows_from(folder / "training.jsonl.gz")
    assert len(training) == TOTAL
    assert all(row["training"] and row["training_episode"] == index and row["episode_seed"] == SEED
               for index, row in enumerate(training, 1))
    reference = HARD / "results" / preset
    hashes = {n: digest(folder / f"{n:05d}.json") == digest(reference / f"{n:05d}.json")
              for n in (1000, 5000, 10000)}
    with gzip.open(reference / "training.jsonl.gz", "rt", encoding="utf-8") as original:
        prefix = [json.loads(line) for line in original]
    assert len(prefix) == 10000
    # The target run budget is recorded in each row, including the shared prefix.
    original_rows_match = all((row | {"milestone": TOTAL}) == new
                              for row, new in zip(prefix, training[:10000], strict=True))
    validate_recording(folder / "training.mlpaths", training[99::100], True, TOTAL, manifest)
    checkpoints = {}
    for n in MILESTONES:
        stem = folder / f"eval-{n:05d}"
        result = read(stem.with_suffix(".result.json"))
        frozen = rows_from(stem.with_suffix(".jsonl"))
        checkpoint = folder / f"{n:05d}.json"
        assert len(frozen) == EVAL_RUNS and digest(checkpoint) == result["checkpoint_sha256"]
        assert all(row["episode_seed"] == EVAL_SEED + index and row["training_episode"] == n
                   and not row["training"] and row["updates"] == training[n - 1]["updates"]
                   for index, row in enumerate(frozen))
        replay = stem.with_suffix(".mlpaths")
        validate_recording(replay, frozen, False, n, manifest)
        checkpoints[n] = {
            "frozen": measures(frozen),
            "training_window": measures(training[n - 5000:n]),
            "last_1000_training": measures(training[n - 1000:n]),
            "replay": replay.relative_to(HERE).as_posix(),
            "checkpoint": checkpoint.relative_to(HERE).as_posix(),
        }
    return {"original_checkpoint_hashes_match": hashes, "original_training_rows_match": original_rows_match,
            "training_all": measures(training), "checkpoints": checkpoints}


def evaluation_cell(result):
    frozen = result["frozen"]
    if frozen["wins"]:
        times = " / ".join(duration(frozen[key]) for key in ("fastest_seconds", "median_seconds", "mean_seconds"))
        detail = f"{times} s"
    else:
        detail = f'{frozen["median_best_progress"]:.1%} median best progress'
    tone = "full" if frozen["wins"] == EVAL_RUNS else ("zero" if frozen["wins"] == 0 else "")
    outcomes = ", ".join(f"{count} {outcome}" for outcome, count in frozen["outcomes"].items())
    return (f'<td class="{tone}"><strong>{frozen["wins"]}/{EVAL_RUNS}</strong> · {detail}'
            f'<br><small>{outcomes}</small> · <a href="{escape(result["replay"])}">Replay</a></td>')


def html_report(results):
    frozen_rows, training_rows = [], []
    labels = "".join(f"<th>{escape(LABELS[preset])}</th>" for preset in PRESETS)
    for n in MILESTONES:
        frozen_rows.append(f"<tr><th>{n:,}</th>"
                           + "".join(evaluation_cell(results[preset]["checkpoints"][n]) for preset in PRESETS)
                           + "</tr>")
        cells = []
        for preset in PRESETS:
            runs = results[preset]["checkpoints"][n]
            window, late = runs["training_window"], runs["last_1000_training"]
            cells.append(f'<td>{window["wins"]:,}/5,000 ({window["win_rate"]:.1%})'
                         f'<br><small>Last 1,000: {late["wins"]:,} wins</small></td>')
        training_rows.append(f"<tr><th>{n-4999:,}–{n:,}</th>" + "".join(cells) + "</tr>")
    matched = all(result["original_training_rows_match"] and all(result["original_checkpoint_hashes_match"].values())
                  for result in results.values())
    comparison = ("The first 10,000 training records and the 1,000, 5,000, and 10,000 Q-table hashes "
                  "matched the previous Hard run for both presets.") if matched else (
                  "See summary.json for the prefix comparison against the previous Hard run.")
    return f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Extended Q-learning training on Hard</title>
<style>
body{{margin:0;background:#f3f6f7;color:#17282d;font:16px/1.5 system-ui,sans-serif}}
main{{max-width:1020px;margin:auto;padding:2rem clamp(1rem,4vw,4rem) 4rem}}
h1{{font-size:clamp(2rem,4vw,3rem);margin:.1em 0;line-height:1.15}}
h2{{margin-top:2rem}} p{{max-width:88ch}} a{{color:#086477}} .scroll{{overflow:auto}}
table{{width:100%;min-width:630px;border-collapse:collapse;background:#fff;font-variant-numeric:tabular-nums}}
th,td{{text-align:left;padding:.5rem .65rem;border:1px solid #d4dfe2}} thead{{background:#dce9eb}}
.full{{background:#def1e9}} .zero{{background:#f9e9e6}}
</style>
<main><h1>Extended Q-learning training on Hard</h1>
<p>Hard · elevated gap chains · November 23, 2026</p>
<p><a href="findings.txt">Conclusions and replay picks</a> · <a href="summary.json">Full metrics</a> ·
<a href="START-HERE.txt">Playback and reproduction</a> ·
<a href="../2026-11-23-hard-q-learning/report.html">Original Hard comparison</a></p>
<h2>Frozen evaluations</h2>
<p>Each checkpoint was evaluated 30 times with exploration and updates off. Times are fastest / median / mean among successful attempts. If a checkpoint had zero wins, the result gives median best progress toward the orb.</p>
<div class="scroll"><table><thead><tr><th>Trained runs</th>{labels}</tr></thead><tbody>{''.join(frozen_rows)}</tbody></table></div>
<h2>Training wins by interval</h2>
<p>Training includes exploratory moves. Each row shows a 5,000-run window and the number of wins in its last 1,000 attempts.</p>
<div class="scroll"><table><thead><tr><th>Training episodes</th>{labels}</tr></thead><tbody>{''.join(training_rows)}</tbody></table></div>
<h2>Same experiment through 50,000 runs</h2>
<p>Both variants started from empty Q-tables with training seed {SEED}. Each checkpoint used the same 30 evaluation seeds, {EVAL_SEED}–{EVAL_SEED + EVAL_RUNS - 1}. Both used the original 60-second time limit and eight-second stuck cutoff. {comparison}</p>
<p>This test uses one training seed and one fixed spawn. The saved checkpoints sample the run at 5,000-episode intervals.</p>
</main></html>
"""


def main():
    output = HERE / "results"
    manifest = read(output / "settings.json")
    reference = read(HARD / "results" / "settings.json")
    assert manifest["source_sha256"] == (reference["source_sha256"] | {
        "hard_long_worker.gd": digest(HERE / "worker.gd")
    })
    results = {preset: collect(output / preset, preset, manifest) for preset in PRESETS}
    dump(HERE / "summary.json", results)
    (HERE / "report.html").write_text(html_report(results), encoding="utf-8")
    for preset, result in results.items():
        print(preset, "original rows match", result["original_training_rows_match"],
              "checkpoint hashes match", result["original_checkpoint_hashes_match"])
        for n, batch in result["checkpoints"].items():
            frozen = batch["frozen"]
            print(n, f'{frozen["wins"]}/{EVAL_RUNS}', duration(frozen["median_seconds"]),
                  f'{batch["training_window"]["wins"]}/5000 training wins')


if __name__ == "__main__":
    main()
