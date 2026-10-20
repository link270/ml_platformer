"""Rebuild the report from archived results. Requires ReportLab and pdftoppm.

Keep the three October 16 experiment folders beside this folder.
"""
import html
import json
from pathlib import Path
import re
import statistics as st
import subprocess

from reportlab.graphics import renderPDF, renderSVG
from reportlab.graphics.charts.lineplots import LinePlot
from reportlab.graphics.shapes import Drawing, Rect, String
from reportlab.lib import colors

ROOT = Path(__file__).resolve().parent
SEEDS = [12345, 42, 98765]
MILESTONES = [0, 100, 300, 600, 1000, 2000, 3000, 5000, 10000]
LABELS = {
    "original": "Original baseline",
    "time_penalty": "Time penalty",
    "current": "Current: longer exploration",
    "discount_099": "Discount 0.99",
    "horizontal_bins": "Horizontal distance bins",
    "late_learning_rate": "Late learning-rate reduction",
}
FOLDERS = {
    "original": ROOT.parent / "2026-10-16-q-learning-baseline",
    "time_penalty": ROOT.parent / "2026-10-16-q-learning-time-penalty",
    "current": ROOT.parent / "2026-10-16-q-learning-long-exploration",
    **{name: ROOT / name for name in list(LABELS)[3:]},
}
PRIMARY = list(LABELS)[2:]
PALETTE = ["#657186", "#135fca", "#008374", "#ad4a0b"]


def read(path):
    return json.loads(path.read_text())


def stats(runs):
    wins = [r for r in runs if r["win"]]
    result = {
        "episodes": len(runs), "wins": len(wins),
        "deaths": sum(not r["win"] and not r["timeout"] for r in runs),
        "timeouts": sum(r["timeout"] for r in runs),
        "success_percent": 100 * len(wins) / len(runs),
        "mean_win_seconds": st.mean(r["ticks"] / 60 for r in wins) if wins else None,
    }
    if "jumps" in runs[0]:
        actions = [sum(r["actions"][i] for r in runs) for i in range(6)]
        result.update(
            mean_win_jumps=st.mean(r["jumps"] for r in wins) if wins else None,
            mean_all_jumps=st.mean(r["jumps"] for r in runs),
            idle_percent=100 * actions[0] / sum(actions),
            jump_command_percent=100 * sum(actions[3:]) / sum(actions),
            longest_still_seconds=max(r["longest_still_ticks"] / 60 for r in runs),
        )
    return result


def chart(name, title, series):
    drawing = Drawing(1000, 430)
    drawing.add(Rect(0, 0, 1000, 430, fillColor=colors.white, strokeColor=None))
    drawing.add(String(65, 397, title, fontSize=20))
    for i, condition in enumerate(PRIMARY):
        drawing.add(String(65 + 450 * (i % 2), 367 - 23 * (i // 2),
                           LABELS[condition], fontSize=12, fillColor=colors.HexColor(PALETTE[i])))
    plot = LinePlot()
    plot.x, plot.y, plot.width, plot.height = 65, 60, 875, 255
    plot.data = series
    plot.xValueAxis.valueMin, plot.xValueAxis.valueMax, plot.xValueAxis.valueStep = 0, 10000, 2000
    plot.yValueAxis.valueMin, plot.yValueAxis.valueMax, plot.yValueAxis.valueStep = 0, 100, 20
    for i, color in enumerate(PALETTE):
        plot.lines[i].strokeColor = colors.HexColor(color)
        plot.lines[i].strokeWidth = 2.5
        if i == 3:
            plot.lines[i].strokeDashArray = [6, 4]
    drawing.add(plot)
    drawing.add(String(385, 19, "Completed training episodes", fontSize=12))
    drawing.add(String(8, 305, "Win %", fontSize=10))
    renderSVG.drawToFile(drawing, str(ROOT / (name + ".svg")))
    renderPDF.drawToFile(drawing, str(ROOT / (name + ".pdf")))
    subprocess.run(["pdftoppm", "-scale-to", "1800", "-png", "-singlefile",
                    str(ROOT / (name + ".pdf")), str(ROOT / name)],
                   check=True, capture_output=True)


def route_svg(run, blocks):
    points = " ".join(f'{d["x"]:.1f},{d["y"]:.1f}' for d in run["trace"])
    left = min(0, run["end_x"] - 24, *(d["x"] - 24 for d in run["trace"]))
    right = max(960, run["end_x"] + 24, *(d["x"] + 24 for d in run["trace"]))
    top = min(280, *(y - 24 for _, y in blocks), *(d["y"] - 24 for d in run["trace"]))
    bottom = max(630, run["end_y"] + 24, *(d["y"] + 24 for d in run["trace"]))
    terrain = "".join(f'<rect x="{x-16}" y="{y-16}" width="32" height="32" fill="#5e6b80"/>'
                      for x, y in blocks)
    return (f'<svg viewBox="{left} {top} {right-left} {bottom-top}" role="img" aria-label="Decision positions over the level">'
            f'<rect x="{left}" y="{top}" width="{right-left}" height="{bottom-top}" fill="#eef2f6"/>{terrain}'
            '<circle cx="720" cy="456" r="12" fill="#d48700"/>'
            f'<polyline points="{points}" fill="none" stroke="#d02d5b" stroke-width="3" opacity=".8"/>'
            f'<circle cx="{run["end_x"]}" cy="{run["end_y"]}" r="7" fill="#111"/>'
            '</svg>')


def number(value, digits=1):
    return "—" if value is None else f"{value:.{digits}f}"


def reversals(run):
    directions = [(-1 if d["action"] in [1, 4] else 1)
                  for d in run["trace"] if d["action"] in [1, 2, 4, 5]]
    return sum(a != b for a, b in zip(directions, directions[1:]))


def main():
    data = {c: {seed: read(folder / f"raw-data/results-{seed}.json") for seed in SEEDS}
            for c, folder in FOLDERS.items()}
    for condition, seeds in data.items():
        for seed, run in seeds.items():
            assert len(run["training"]) == 10000, (condition, seed)
            assert [e["episode"] for e in run["evaluations"]] == MILESTONES
            assert all(len(e["runs"]) == 30 for e in run["evaluations"])
    for seed in SEEDS:
        assert data["current"][seed]["training"][:3000] == data["late_learning_rate"][seed]["training"][:3000]

    summary = {"conditions": {}, "evaluations": [], "best_checkpoints": [], "video_candidates": [],
               "regressions": []}
    for condition, seeds in data.items():
        runs = [r for d in seeds.values() for r in d["training"]]
        final = [r for d in seeds.values() for r in d["evaluations"][-1]["runs"]]
        summary["conditions"][condition] = {
            "label": LABELS[condition], "training": stats(runs), "final_evaluation": stats(final),
            "late_training": stats([r for d in seeds.values() for r in d["training"][5000:]]),
            "solved_checkpoints_after_3000": sum(
                all(r["win"] for r in e["runs"]) for d in seeds.values()
                for e in d["evaluations"] if e["episode"] >= 3000),
            "sampled_checkpoints_after_3000": 9,
        }
        for seed, data_run in seeds.items():
            for previous, following in zip(data_run["evaluations"], data_run["evaluations"][1:]):
                if all(r["win"] for r in previous["runs"]) and not all(r["win"] for r in following["runs"]):
                    summary["regressions"].append({
                        "condition": condition, "seed": seed,
                        "from_episode": previous["episode"], "to_episode": following["episode"],
                        "following_wins": sum(r["win"] for r in following["runs"])})
            for evaluation in data_run["evaluations"]:
                summary["evaluations"].append({
                    "condition": condition, "seed": seed, "episode": evaluation["episode"],
                    "rows": evaluation["rows"], **stats(evaluation["runs"])})
            best = max(data_run["evaluations"], key=lambda e: (
                sum(r["win"] for r in e["runs"]),
                -(stats(e["runs"])["mean_win_seconds"] or 999),
                -e["episode"]))
            summary["best_checkpoints"].append({
                "condition": condition, "seed": seed, "episode": best["episode"],
                "checkpoint": str(FOLDERS[condition].relative_to(ROOT.parent) /
                                  f'checkpoints/checkpoint-{seed}-{best["episode"]}.json'),
                **stats(best["runs"])})

    def candidate(condition, seed, evaluation, kind):
        run = evaluation["runs"][0]
        return {"condition": condition, "seed": seed, "episode": evaluation["episode"], "kind": kind,
                "checkpoint": f'{condition}/checkpoints/checkpoint-{seed}-{evaluation["episode"]}.json',
                "evaluation": stats(evaluation["runs"]),
                "first_run": {key: run[key] for key in [
                    "win", "timeout", "ticks", "jumps", "longest_still_ticks", "actions", "end_x", "end_y"]}}

    cards = []
    for condition in PRIMARY[1:]:
        evaluations = [(seed, e) for seed, d in data[condition].items()
                       for e in d["evaluations"] if e["episode"] > 0]
        successes = [(s, e) for s, e in evaluations if all(r["win"] for r in e["runs"])]
        chosen = []
        if successes:
            seed, evaluation = min(successes, key=lambda item: stats(item[1]["runs"])["mean_win_seconds"])
            chosen.append((seed, evaluation, "Fastest checkpoint with 30/30 wins"))
        failures = [(s, e) for s, e in evaluations if not e["runs"][0]["win"]
                    and (condition != "late_learning_rate" or e["episode"] > 3000)]
        if failures:
            seed, evaluation = max(failures, key=lambda item: item[1]["runs"][0]["jumps"])
            chosen.append((seed, evaluation, "Most takeoffs in a failed first evaluation"))
            seed, evaluation = max(failures, key=lambda item: item[1]["runs"][0]["longest_still_ticks"])
            if evaluation["runs"][0]["longest_still_ticks"] >= 60:
                chosen.append((seed, evaluation, "Longest stationary stretch in a failed first evaluation"))
            seed, evaluation = max(failures, key=lambda item: reversals(item[1]["runs"][0]))
            if reversals(evaluation["runs"][0]) >= 20:
                chosen.append((seed, evaluation,
                               f'Most horizontal direction reversals in a failed first evaluation ({reversals(evaluation["runs"][0])})'))
        regressions = [r for r in summary["regressions"] if r["condition"] == condition
                       and (condition != "late_learning_rate" or r["from_episode"] >= 3000)]
        if regressions:
            regression = max(regressions, key=lambda r: r["to_episode"])
            seed = regression["seed"]
            evaluation = next(e for e in data[condition][seed]["evaluations"]
                              if e["episode"] == regression["to_episode"])
            chosen.append((seed, evaluation,
                           f'Regression after 30/30 wins at episode {regression["from_episode"]}'))
        unique = {}
        for seed, evaluation, kind in chosen:
            key = (seed, evaluation["episode"])
            if key in unique:
                unique[key][2] += "; " + kind
            else:
                unique[key] = [seed, evaluation, kind]
        for seed, evaluation, kind in unique.values():
            summary["video_candidates"].append(candidate(condition, seed, evaluation, kind))
            cards.append((condition, seed, evaluation, kind))
    alias_probe = read(ROOT / "horizontal_bins/raw-data/bin-alias-probe.json")
    summary["alias_probe"] = {
        "previous_key": "000101|1|1|0", "sampled_positions": len(alias_probe),
        "new_keys": {key: sum(p["horizontal_bin_key"] == key for p in alias_probe)
                     for key in sorted({p["horizontal_bin_key"] for p in alias_probe})},
        "note": "Synthetic position probe; shared observations alone do not establish which action is optimal."
    }
    (ROOT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (ROOT / "best-checkpoints.json").write_text(json.dumps({
        "selection": "Retrospective: maximize wins out of 30, then minimize mean successful duration, then prefer earlier episode.",
        "caution": "Selected using these same evaluation runs; not an independent validation or implemented live selection feature.",
        "checkpoints": summary["best_checkpoints"]}, indent=2) + "\n")
    (ROOT / "video-candidates.json").write_text(json.dumps(summary["video_candidates"], indent=2) + "\n")

    chart("training-comparison", "Training success (500-episode windows, three seeds)",
          [[(end, stats([r for d in data[c].values() for r in d["training"][end-500:end]])["success_percent"])
            for end in range(500, 10001, 500)] for c in PRIMARY])
    chart("evaluation-comparison", "Frozen greedy evaluation (30 runs per seed)",
          [[(milestone, stats([r for d in data[c].values() for r in d["evaluations"][i]["runs"]])["success_percent"])
            for i, milestone in enumerate(MILESTONES)] for c in PRIMARY])
    rows = ""
    for c, result in summary["conditions"].items():
        final = result["final_evaluation"]
        rows += (f'<tr><th>{LABELS[c]}</th><td>{result["training"]["success_percent"]:.1f}%</td>'
                 f'<td>{result["late_training"]["success_percent"]:.1f}%</td>'
                 f'<td>{final["wins"]}/90</td><td>{number(final["mean_win_seconds"], 2)}</td>'
                 f'<td>{number(final["mean_win_jumps"])}</td>'
                 f'<td>{result["solved_checkpoints_after_3000"]}/9</td></tr>')
    grid = ""
    for c in PRIMARY:
        for seed in SEEDS:
            grid += f'<tr><th>{LABELS[c]} · {seed}</th>'
            for evaluation in data[c][seed]["evaluations"]:
                s = stats(evaluation["runs"])
                cls = "win" if s["wins"] == 30 else "fail" if s["wins"] == 0 else "mixed"
                grid += (f'<td class="{cls}">{s["wins"]}/30<br><small>'
                         f'{number(s["mean_win_seconds"], 2)}s</small></td>')
            grid += "</tr>"
    # Terrain is unchanged in every variant.
    scene = (ROOT / "level-for-report.tscn").read_text()
    blocks = [tuple(map(float, match)) for match in re.findall(
        r'\[node [^\n]*instance=ExtResource\("2"\)\]\nposition = Vector2\(([-\d.]+), ([-\d.]+)\)', scene)]
    assert blocks
    video = ""
    for c, seed, evaluation, kind in cards:
        run = evaluation["runs"][0]
        outcome = "orb" if run["win"] else "timeout" if run["timeout"] else "death"
        video += (f'<article><h3>{LABELS[c]} · {seed} · episode {evaluation["episode"]}</h3>'
                  f'<p>{kind}. First run: {outcome}, {run["ticks"]/60:.2f}s, {run["jumps"]} takeoffs, '
                  f'{run["longest_still_ticks"]/60:.2f}s longest stationary stretch.</p>'
                  f'{route_svg(run, blocks)}<p><a href="{c}/checkpoints/checkpoint-{seed}-{evaluation["episode"]}.json">'
                  'Saved Q-table</a> · Reopen using this variant’s frozen project.</p></article>')
    findings = html.escape((ROOT / "findings.txt").read_text())
    page = f"""<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Q-learning: three follow-up experiments</title>
<style>
body{{font:17px/1.5 system-ui,sans-serif;max-width:1250px;margin:36px auto;padding:0 24px;color:#172333;background:#f7f9fc}}
h1{{font-size:34px}}h2{{margin-top:40px}}p{{max-width:1000px}}a{{color:#125cbd}}
table{{border-collapse:collapse;width:100%;background:white;font-size:14px}}
th,td{{padding:10px 9px;border:1px solid #dbe2eb;text-align:center}}th:first-child{{text-align:left}}
.scroll{{overflow:auto}}.win{{background:#dff3e8}}.fail{{background:#fce5e5}}.mixed{{background:#fff1ce}}
img{{width:100%;background:white}}.findings{{white-space:pre-wrap;background:#fff;border-left:5px solid #135fca;padding:22px}}
article{{background:white;padding:20px;margin:20px 0;border:1px solid #dbe2eb}}article svg{{width:100%;max-height:350px}}
small{{color:#42526a}}code{{font-size:.9em}}
</style>
<h1>Can simple Q-learning get better—or stranger?</h1>
<p>October 19, 2026 · Three isolated changes · 90,000 new training episodes · 2,430 frozen evaluations</p>
<p>The current reference keeps the time penalty and longer exploration. Each experiment changes only one learning choice.
The playable game and its normal save remain unchanged.</p>
<div class="findings">{findings}</div>
<h2>Final outcomes and consistency</h2>
<div class="scroll"><table><tr><th>Condition</th><th>Training wins</th><th>Last 5k wins</th>
<th>Final eval wins</th><th>Seconds / win</th><th>Takeoffs / win</th><th>Fully successful late checkpoints</th></tr>{rows}</table></div>
<p><small>Durations and takeoffs describe successful runs only: always read alongside wins.
Late checkpoints are 3,000, 5,000 and 10,000 episodes for each seed (nine policies).
Repeated evaluations from one fixed spawn are not independent tests of generalization.</small></p>
<h2>Learning curves</h2><img src="training-comparison.svg" alt="Training success by episode">
<img src="evaluation-comparison.svg" alt="Frozen greedy evaluation success by checkpoint">
<p>Lines connect sampled checkpoints; they do not establish what happened between checkpoints.
Training uses exploration. Evaluation freezes learning and sets exploration to zero.
The current and lower-learning-rate aggregate evaluation curves overlap exactly; the dashed orange line
shows the latter. Their per-seed successes at episode 5,000 differ, as the table below shows.</p>
<h2>Every seed and checkpoint</h2><div class="scroll"><table><tr><th>Condition / seed</th>
{''.join(f'<th>{m}</th>' for m in MILESTONES)}</tr>{grid}</table></div>
<p>Each cell shows wins out of 30 and mean successful duration. A dash means no successful runs.</p>
<h2>What do the extra ray bins actually distinguish?</h2>
<p>The unchanged geometry probe's seven positions formerly shared key <code>000101|1|1|0</code>.
The new encoding splits them into two keys: five positions still share the original key,
and two use <code>020101|1|1|0</code>. The extra information helps distinguish some situations,
but does not uniquely identify the platform or route.
<a href="horizontal_bins/raw-data/bin-alias-probe.json">Exact positions and keys</a>.</p>
<h2>Footage candidates</h2><p>Paths join decision positions every six physics ticks; they are sampled traces,
not frame-perfect animation. Black dot: end position. Gold circle: orb.</p>{video}
<h2>Methods and saved artifacts</h2>
<p>Godot 4.7.1, 60 Hz physics, six-tick actions, identical fixed map/spawn, seeds 12345, 42 and 98765.
Each seed trains uninterrupted for 10,000 episodes, then evaluates nine saved checkpoints 30 times each.
Evaluation tie-breaking uses seed + 1,000,000; training RNG and Q-values are asserted unchanged by evaluation.
The diagnostic is byte-identical to earlier tests.</p>
<ul><li>Discount: 0.95 → 0.99 per decision.</li>
<li>Horizontal bins: no hit / ≤1 unit / &gt;1 to 2 units; other four rays remain binary.
Maximum states: 1,728 → 3,888. No ray extension or physics change.</li>
<li>Late learning rate: 0.1 through episode 3,000, linearly decreasing to 0.02 at 10,000.
An episode uses the rate set after the preceding episode. Exploration and discount remain unchanged.</li></ul>
<p>Best-checkpoint selection is retrospective, using these evaluations, and is not an independent performance test.
No combinations or new maps were tested. The horizontal-bin and learning-schedule checkpoints require their matching frozen projects.</p>
<p><a href="START-HERE.txt">Reload and reproduce</a> · <a href="settings.json">Exact settings</a> ·
<a href="summary.json">Structured results</a> · <a href="best-checkpoints.json">Best checkpoint references</a> ·
<a href="video-candidates.json">Footage candidates</a></p></html>"""
    (ROOT / "report.html").write_text(page)
    for condition, result in summary["conditions"].items():
        print(condition, json.dumps(result))


if __name__ == "__main__":
    main()
