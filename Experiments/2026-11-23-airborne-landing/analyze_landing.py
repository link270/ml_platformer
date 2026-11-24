"""Check the landing-memory archive and compare the matched Hard presets."""

from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
GAP = HERE.parent / "2026-11-23-gap-rays"
HARD = HERE.parent / "2026-11-23-hard-q-learning"
sys.path.insert(0, str(GAP))

from analyze_gap_rays import collect, duration, frozen_cell, table
from run import EVAL_RUNS, EVAL_SEED, MILESTONES, SEED, dump, read


def report(memory, gap, fixed):
    rows = [
        "<tr><th>Fixed reward per block</th>"
        + "".join(frozen_cell(fixed[str(n)]) for n in MILESTONES) + "</tr>",
        "<tr><th>Fixed reward + gap rays</th>"
        + "".join(frozen_cell(gap[str(n)]) for n in MILESTONES) + "</tr>",
        "<tr><th>Fixed reward + landing memory</th>"
        + "".join(frozen_cell(memory[n], link=True) for n in MILESTONES) + "</tr>",
    ]
    training = []
    for label, result in [("Fixed reward per block", fixed["10000"]),
                          ("Fixed reward + gap rays", gap["10000"]),
                          ("Fixed reward + landing memory", memory[10000])]:
        all_runs = result["training_through_milestone"]
        cells = [all_runs["first_win_episode"] or "—",
                 " / ".join(duration(all_runs[key]) for key in ("fastest_seconds", "median_seconds", "mean_seconds")),
                 f'{all_runs["wins"]:,}/10,000', all_runs["longest_win_streak"],
                 result["last_1000_training"]["wins"]]
        training.append(f"<tr><th>{label}</th>" + "".join(f"<td>{cell}</td>" for cell in cells) + "</tr>")
    return f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Landing memory Q-learning on Hard</title>
<style>
body{{margin:0;background:#f3f6f7;color:#17282d;font:16px/1.5 system-ui,sans-serif}}
main{{max-width:1020px;margin:auto;padding:2rem clamp(1rem,4vw,4rem) 4rem}}
h1{{font-size:clamp(2rem,4vw,3rem);margin:.1em 0;line-height:1.15}}
h2{{margin-top:2rem}} p{{max-width:88ch}} a{{color:#086477}} .scroll{{overflow:auto}}
table{{width:100%;min-width:640px;border-collapse:collapse;background:#fff;font-variant-numeric:tabular-nums}}
th,td{{text-align:left;padding:.5rem .65rem;border:1px solid #d4dfe2}} thead{{background:#dce9eb}}
.full{{background:#def1e9}} .zero{{background:#f9e9e6}}
</style>
<main><h1>Landing memory Q-learning on Hard</h1>
<p>Hard · elevated gap chains · November 23, 2026</p>
<p><a href="findings.txt">Conclusions and filming notes</a> · <a href="summary.json">Full metrics</a> ·
<a href="START-HERE.txt">Playback and reproduction</a> · <a href="../2026-11-23-gap-rays/report.html">Grounded gap-ray comparison</a></p>
<h2>Frozen evaluation</h2>
<p>Each checkpoint got 30 attempts with exploration and learning off. Winning times are fastest / median / mean, in simulation seconds. For zero wins, the table shows median best progress toward the orb.</p>
{table(["Experiment", *(f"{n:,} trained" for n in MILESTONES)], rows)}
<h2>Training performance</h2>
<p>Training includes exploration. Completion times cover the winning attempts.</p>
{table(["Experiment", "First win #", "Fastest / median / mean (s)", "Wins", "Longest streak", "Last 1,000 wins"], training)}
<h2>Matched test</h2>
<p>All variants start with empty tables on the same Hard course and seed {SEED}. The frozen tests use seeds
{EVAL_SEED}–{EVAL_SEED + EVAL_RUNS - 1}. Actions, decision timing, fixed reward, the 60-second limit, and the eight-second stuck cutoff match.</p>
<p>Landing memory keeps the last visible far lip from the grounded gap scan and bins the player's horizontal distance and vertical clearance while in the air. It clears on ground contact or reset. The original gap-ray preset uses the same grounded observations. The test uses one training seed and one fixed spawn.</p>
</main></html>
"""


def main():
    manifest = read(HERE / "results" / "settings.json")
    gap_manifest = read(GAP / "results" / "settings.json")
    assert manifest["preset"] == "airborne_landing" and manifest["level"] == ["hard"]
    for key in ("engine", "training_seed", "evaluation_seed_first", "evaluation_runs_per_checkpoint",
                "milestones", "stuck_detection", "episode_limit_seconds"):
        assert manifest[key] == gap_manifest[key]
    memory = collect("hard", manifest, HERE)
    gap = read(GAP / "summary.json")["hard"]
    fixed = read(HARD / "summary.json")["hard"]["fixed_reward_per_block"]
    dump(HERE / "summary.json", {"hard": memory})
    (HERE / "report.html").write_text(report(memory, gap, fixed), encoding="utf-8")
    for n, row in memory.items():
        f = row["frozen"]
        print(n, f'{f["wins"]}/{EVAL_RUNS}', duration(f["median_seconds"]),
              f["outcomes"], f'{f["median_best_progress"]:.1%} median progress',
              f'{row["training_through_milestone"]["wins"]} cumulative training wins')


if __name__ == "__main__":
    main()
