"""Validate the gap-ray checkpoints and compare them with matched course archives."""

from html import escape

from run_gap_rays import HERE, EVAL_RUNS, EVAL_SEED, LEVELS, MILESTONES, SEED
from run import digest, dump, read
from analyze import duration, measures, rows_from, validate_recording


REFERENCES = {
    "easy": HERE.parent / "2026-11-20-easy-q-learning",
    "medium": HERE.parent / "2026-11-23-medium-q-learning",
    "hard": HERE.parent / "2026-11-23-hard-q-learning",
}


def collect(level, manifest, root=HERE):
    folder = root / "results" / level
    course_manifest = manifest | {"level": level}
    old_settings = read(REFERENCES[level] / "results" / "settings.json")
    for key in ("engine", "evaluation_seed_first", "training_seed", "stuck_detection", "episode_limit_seconds"):
        assert course_manifest[key] == old_settings[key]
    for key in (f"Game/Levels/Training{level.title()}.tscn", "Game/Levels/CourseBase.tscn",
                "Game/Block.tscn", "Game/Player.tscn", "Training/train.gd"):
        assert course_manifest["source_sha256"][key] == old_settings["source_sha256"][key], key
    training = rows_from(folder / "training.jsonl.gz")
    assert len(training) == 10000 and all(
        row["training"] and row["training_episode"] == index and row["episode_seed"] == SEED
        for index, row in enumerate(training, 1)
    )
    validate_recording(folder / "training.mlpaths", training[99::100], True, 10000, course_manifest)
    output = {}
    for n in MILESTONES:
        checkpoint = folder / f"{n:05d}.json"
        stem = folder / f"eval-{n:05d}"
        result = read(stem.with_suffix(".result.json"))
        rows = rows_from(stem.with_suffix(".jsonl"))
        saved = read(checkpoint)
        fixed = read(REFERENCES[level] / "results" / "fixed_reward_per_block" / f"{n:05d}.json")
        for key in ("learning_rate", "discount", "epsilon", "epsilon_decay", "minimum_epsilon"):
            assert saved[key] == fixed[key], key
        for key in ("reward_shaping", "ticks_per_decision", "actions", "rays"):
            assert saved["schema"][key] == fixed["schema"][key], key
        assert saved["preset_id"] == manifest["preset"] and saved["schema"]["gap_rays"]
        if manifest["preset"] == "airborne_landing":
            assert saved["schema"]["landing_memory"]
        assert len(rows) == EVAL_RUNS and result["checkpoint_sha256"] == digest(checkpoint)
        assert all(not row["training"] and row["episode_seed"] == EVAL_SEED + index
                   and row["training_episode"] == n and row["updates"] == saved["updates"]
                   for index, row in enumerate(rows))
        replay = stem.with_suffix(".mlpaths")
        validate_recording(replay, rows, False, n, course_manifest)
        output[n] = {"frozen": measures(rows), "training_through_milestone": measures(training[:n]),
                     "last_1000_training": measures(training[n - 1000:n]),
                     "table_rows": len(saved["q_table"]),
                     "replay": replay.relative_to(root).as_posix(),
                     "checkpoint": checkpoint.relative_to(root).as_posix()}
    return output


def reference_tables(level):
    reference = read(REFERENCES[level] / "summary.json")
    return reference if level == "easy" else reference[level]


def table(headers, rows):
    return ("<div class='scroll'><table><thead><tr>" + "".join(f"<th>{header}</th>" for header in headers)
            + "</tr></thead><tbody>" + "".join(rows) + "</tbody></table></div>")


def frozen_cell(row, link=False):
    frozen = row["frozen"]
    tone = "full" if frozen["wins"] == EVAL_RUNS else ("zero" if not frozen["wins"] else "")
    if frozen["wins"]:
        values = (duration(frozen[key]) for key in ("fastest_seconds", "median_seconds", "mean_seconds"))
        detail = " / ".join(values) + " s"
    else:
        detail = f'{frozen["median_best_progress"]:.1%} median best progress'
    replay = f'<br><a href="{escape(row["replay"])}">Replay</a>' if link else ""
    return f'<td class="{tone}"><strong>{frozen["wins"]}/{EVAL_RUNS}</strong><br>{detail}{replay}</td>'


def report(results):
    evaluation, training = [], []
    labels = {"fixed_reward_per_block": "Fixed reward", "course_position": "Fixed reward + course position"}
    for level, milestones in results.items():
        reference = reference_tables(level)
        for label, title in labels.items():
            evaluation.append(f"<tr><th>{level.title()}</th><th>{title}</th>"
                              + "".join(frozen_cell(reference[label][str(n)]) for n in MILESTONES) + "</tr>")
        evaluation.append(f"<tr><th>{level.title()}</th><th>Fixed reward + gap rays</th>"
                          + "".join(frozen_cell(milestones[n], link=True) for n in MILESTONES) + "</tr>")
        last = milestones[10000]
        total = last["training_through_milestone"]
        cells = [
            total["first_win_episode"] or "—",
            duration(total["first_win_seconds"]),
            " / ".join(duration(total[key]) for key in ("fastest_seconds", "median_seconds", "mean_seconds")),
            f'{total["wins"]:,}/10,000 ({total["win_rate"]:.1%})', total["longest_win_streak"],
            *(f'{milestones[n]["last_1000_training"]["win_rate"]:.1%}' for n in MILESTONES),
        ]
        training.append(f"<tr><th>{level.title()}</th>" + "".join(f"<td>{cell}</td>" for cell in cells) + "</tr>")
    return f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Gap ray Q-learning comparison</title>
<style>
body{{margin:0;background:#f3f6f7;color:#17282d;font:16px/1.5 system-ui,sans-serif}}
main{{max-width:1120px;margin:auto;padding:2rem clamp(1rem,4vw,4rem) 4rem}}
h1{{font-size:clamp(2rem,4vw,3rem);margin:.1em 0;line-height:1.15}}
h2{{margin-top:2rem}} p{{max-width:88ch}} a{{color:#086477}} .scroll{{overflow:auto}}
table{{width:100%;min-width:690px;border-collapse:collapse;background:#fff;font-variant-numeric:tabular-nums}}
th,td{{text-align:left;padding:.5rem .65rem;border:1px solid #d4dfe2}} thead{{background:#dce9eb}}
.full{{background:#def1e9}} .zero{{background:#f9e9e6}}
</style>
<main><h1>Gap ray Q-learning comparison</h1>
<p>Easy, Medium, and Hard · November 23, 2026</p>
<p><a href="findings.txt">Conclusions and filming notes</a> · <a href="summary.json">Full metrics</a> ·
<a href="START-HERE.txt">Playback and reproduction</a></p>
<h2>Frozen checkpoints</h2>
<p>Each checkpoint was evaluated 30 times with learning and exploration off. Winning times are fastest / median / mean, in simulation seconds. With zero wins the table shows median best progress toward the orb.</p>
{table(["Course", "Experiment", *(f"{n:,} trained" for n in MILESTONES)], evaluation)}
<h2>Gap ray training results</h2>
<p>Training wins include exploration. The three rightmost columns show the win rate in the 1,000 episodes ending at each checkpoint.</p>
{table(["Course", "First win #", "First win (s)", "Fastest / median / mean (s)", "All wins", "Longest streak",
         "Through 1,000", "Through 5,000", "Through 10,000"], training)}
<h2>Matched conditions</h2>
<p>Each gap-ray agent started from an empty Q-table with seed {SEED}. Each frozen batch uses seeds {EVAL_SEED}–{EVAL_SEED + EVAL_RUNS - 1}. The level geometry, six actions, physics timing, fixed reward, learning settings, 60-second limit, and eight-second stuck cutoff match the fixed-reward comparison.</p>
<p>The additional traces sample the ground within a bounded area toward the goal. They encode runway to the next gap, gap width, and whether a visible landing is higher. The original air observations remain in use. These results cover one training seed and one spawn per course.</p>
</main></html>
"""


def main():
    manifest = read(HERE / "results" / "settings.json")
    results = {level: collect(level, manifest) for level in LEVELS}
    dump(HERE / "summary.json", results)
    (HERE / "report.html").write_text(report(results), encoding="utf-8")
    for level, checkpoints in results.items():
        for milestone, row in checkpoints.items():
            frozen = row["frozen"]
            print(level, milestone, f'{frozen["wins"]}/{EVAL_RUNS}', duration(frozen["median_seconds"]),
                  frozen["outcomes"], f'{row["training_through_milestone"]["wins"]} training wins')


if __name__ == "__main__":
    main()
