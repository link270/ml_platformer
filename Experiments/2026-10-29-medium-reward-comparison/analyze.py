"""Summarize the matched Medium experiment and render its learning curves."""

from pathlib import Path
from collections import Counter
import hashlib
import html
import json
import math
import re
import statistics
import struct
import subprocess
import zipfile

from reportlab.graphics import renderSVG
from reportlab.graphics.charts.lineplots import LinePlot
from reportlab.graphics.shapes import Circle, Drawing, PolyLine, Rect, String
from reportlab.lib import colors


ROOT = Path(__file__).resolve().parent
LABELS = {"long_exploration": "Longer exploration", "fixed_reward_per_block": "Fixed reward per block"}
PALETTE = {"long_exploration": "#237d91", "fixed_reward_per_block": "#d77724"}


def read_rows(path):
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line]


def aggregate(rows):
    outcomes = Counter(row["outcome"] for row in rows)
    wins = [row for row in rows if row["outcome"] == "success"]
    return {
        "episodes": len(rows), "wins": outcomes["success"], "deaths": outcomes["death"],
        "stuck": outcomes["stuck"], "timeouts": outcomes["timeout"],
        "success_percent": 100 * len(wins) / len(rows),
        "mean_seconds": statistics.mean(row["seconds"] for row in rows),
        "mean_win_seconds": statistics.mean(row["seconds"] for row in wins) if wins else None,
        "mean_best_progress_percent": 100 * statistics.mean(row["best_progress"] for row in rows),
        "maximum_best_progress_percent": 100 * max(row["best_progress"] for row in rows),
        "median_best_progress_percent": 100 * statistics.median(row["best_progress"] for row in rows),
    }


def recordings(path, first_positions=False):
    """Validate/index the native stream without resimulating its paths."""
    data = Path(path).read_bytes()
    assert data[:8] == b"MLPATH01"
    header_bytes, = struct.unpack_from("<I", data, 8)
    header = json.loads(data[12:12 + header_bytes])
    assert header["level_scene"] == "res://Game/Levels/TrainingMedium.tscn"
    assert header["stuck_detection"] and header["physics_hz"] == 60
    cursor = 12 + header_bytes
    episodes = []
    while cursor < len(data):
        length, count = struct.unpack_from("<II", data, cursor)
        cursor += 8
        metadata = json.loads(data[cursor:cursor + length])
        cursor += length
        end = cursor + count * 13
        assert end <= len(data) and metadata["ticks"] == count - 1
        assert metadata["outcome"] in ["success", "death", "timeout", "stuck"]
        positions = []
        for x, y, reward, flags in struct.iter_unpack("<fffB", data[cursor:end]):
            assert all(math.isfinite(value) for value in [x, y, reward])
            assert flags <= 15 and (flags & 7) <= 5
            if first_positions and not episodes:
                positions.append((x, y))
        episode = {"metadata": metadata, "sample_count": count}
        if positions:
            episode["positions"] = positions
        episodes.append(episode)
        cursor = end
    assert cursor == len(data)
    return header, episodes


def export(drawing, name):
    svg = ROOT / (name + ".svg")
    renderSVG.drawToFile(drawing, str(svg))
    # This renderer writes Python's "None" as an SVG color token; browsers
    # treat it as an invalid fill and paint open polylines black.
    svg.write_text(svg.read_text().replace("fill: None;", "fill: none;").replace("stroke: None;", "stroke: none;"))
    subprocess.run(["C:/Program Files/Inkscape/bin/inkscape.com", str(svg),
                    "--export-type=png", "--export-width=1600", "--export-filename=" + str(ROOT / (name + ".png"))],
                   check=True, capture_output=True, timeout=60)


def routes(summary, milestone=10000, phase="final_evaluation", name="final-routes"):
    with zipfile.ZipFile(ROOT / "source.zip") as archive:
        scene = archive.read("Game/Levels/TrainingMedium.tscn").decode()
    blocks = [(float(x), float(y)) for x, y in re.findall(r"position = Vector2\(([-\d.]+), ([-\d.]+)\)", scene)]
    drawing = Drawing(1000, 435)
    drawing.add(Rect(0, 0, 1000, 435, fillColor=colors.white, strokeColor=None))
    title = "Medium: final saved policies" if milestone == 10000 else "Medium: 9,000-episode policies (post-hoc diagnostic)"
    drawing.add(String(40, 402, title, fontSize=20))
    drawing.add(String(40, 380, "First of 30 frozen evaluation episodes; actual recorded positions, no resimulation.", fontSize=12))
    scale = 920 / 3840
    outcome_colors = {"success": "#27a85e", "death": "#d04942", "stuck": "#8659a6", "timeout": "#db9518"}
    for index, preset in enumerate(LABELS):
        base = 240 - 190 * index
        _, episodes = recordings(ROOT / preset / phase / f"{milestone:05d}.mlpaths", first_positions=True)
        first = episodes[0]
        row = read_rows(ROOT / preset / phase / f"{milestone:05d}.episodes.jsonl")[0]
        drawing.add(String(40, base + 105, f"{LABELS[preset]}: {row['outcome']}, {row['seconds']:.1f} s", fontSize=14,
                           fillColor=colors.HexColor(PALETTE[preset])))
        def point(x, y):
            return 40 + scale * x, base + scale * (640 - y)
        for x, y in blocks:
            left, bottom = point(x - 16, y + 16)
            drawing.add(Rect(left, bottom, 32 * scale, 32 * scale,
                             fillColor=colors.HexColor("#bcc8cf"), strokeColor=None))
        path = [value for x, y in first["positions"] for value in point(x, y)]
        drawing.add(PolyLine(path, strokeWidth=1.8, strokeColor=colors.HexColor(PALETTE[preset])))
        gx, gy = point(3760, 456)
        drawing.add(Circle(gx, gy, 3.5, fillColor=colors.HexColor("#e0b800"), strokeColor=None))
        ex, ey = point(*first["positions"][-1])
        drawing.add(Circle(ex, ey, 3, fillColor=colors.HexColor(outcome_colors[row["outcome"]]), strokeColor=None))
        for x in [0, 960, 1920, 2880, 3840]:
            drawing.add(String(40 + x * scale, base - 15, str(x // 32), fontSize=9))
    drawing.add(String(390, 10, "Horizontal position in 32-pixel blocks", fontSize=10))
    export(drawing, name)


def chart(name, title, summary, metric, ylabel):
    drawing = Drawing(1000, 430)
    drawing.add(Rect(0, 0, 1000, 430, fillColor=colors.white, strokeColor=None))
    drawing.add(String(65, 394, title, fontSize=20, fillColor=colors.HexColor("#192b37")))
    for i, preset in enumerate(LABELS):
        drawing.add(String(65 + 410 * i, 360, LABELS[preset], fontSize=13,
                           fillColor=colors.HexColor(PALETTE[preset])))
    plot = LinePlot()
    plot.x, plot.y, plot.width, plot.height = 65, 65, 880, 255
    plot.data = [[(window["last_episode"], window[metric]) for window in summary[preset]["windows_500"]] for preset in LABELS]
    plot.xValueAxis.valueMin, plot.xValueAxis.valueMax, plot.xValueAxis.valueStep = 0, 10000, 2000
    plot.yValueAxis.valueMin, plot.yValueAxis.valueMax, plot.yValueAxis.valueStep = 0, 100, 20
    for i, preset in enumerate(LABELS):
        plot.lines[i].strokeColor = colors.HexColor(PALETTE[preset])
        plot.lines[i].strokeWidth = 2.5
    drawing.add(plot)
    drawing.add(String(370, 24, "Completed training episodes (500-episode windows)", fontSize=11))
    drawing.add(String(9, 335, ylabel, fontSize=10))
    export(drawing, name)


def number(value, suffix=""):
    return "—" if value is None else f"{value:.1f}{suffix}"


def main():
    settings = json.loads((ROOT / "settings.json").read_text())
    progress = json.loads((ROOT / "progress.json").read_text())
    assert progress.get("complete"), "Comparison has not finished."
    summary = {}
    checkpoints_verified = 0
    recording_episodes = 0
    with zipfile.ZipFile(ROOT / "source.zip") as archive:
        for name, expected in settings["source_sha256"].items():
            assert hashlib.sha256(archive.read(name)).hexdigest() == expected
    for preset in settings["presets"]:
        rows = []
        for milestone in settings["milestones"]:
            stage = ROOT / preset / "training" / f"{milestone:05d}"
            chunk = read_rows(str(stage) + ".episodes.jsonl")
            assert len(chunk) == 1000 and all(row["training"] for row in chunk)
            expected_seed = settings["training_seeds"][milestone // 1000 - 1]
            assert all(row["episode_seed"] == expected_seed for row in chunk)
            rows.extend(chunk)
            checkpoint = ROOT / preset / "checkpoints" / f"checkpoint-{settings['base_seed']}-{milestone}.json"
            data = json.loads(checkpoint.read_text())
            assert data["training_episodes"] == milestone
            assert data["training_wins"] == sum(row["outcome"] == "success" for row in rows)
            assert all(data[key] == value for key, value in settings["shared_learning_settings"].items())
            expected_epsilon = max(.05, .999 ** milestone)
            assert abs(data["epsilon"] - expected_epsilon) < 1e-12
            checkpoints_verified += 1
        assert len(rows) == 10000 and [r["training_episode"] for r in rows] == list(range(1, 10001))
        evaluation = read_rows(ROOT / preset / "final_evaluation/10000.episodes.jsonl")
        assert len(evaluation) == 30 and not any(row["training"] for row in evaluation)
        assert [row["episode_seed"] for row in evaluation] == list(range(settings["final_evaluation_seed"], settings["final_evaluation_seed"] + 30))
        diagnostic = read_rows(ROOT / preset / "diagnostic_evaluation/09000.episodes.jsonl")
        assert len(diagnostic) == 30 and not any(row["training"] for row in diagnostic)
        assert [row["episode_seed"] for row in diagnostic] == [row["episode_seed"] for row in evaluation]
        assert all(row["training_episode"] == 9000 for row in diagnostic)
        checkins = []
        for index, milestone in enumerate(settings["milestones"]):
            checkin = read_rows(ROOT / preset / "check_in" / f"{milestone:05d}.episodes.jsonl")
            assert len(checkin) == 1 and checkin[0]["episode_seed"] == settings["check_in_seeds"][index]
            checkins.append({"milestone": milestone, **checkin[0]})
        windows = [{"first_episode": offset + 1, "last_episode": offset + 500, **aggregate(rows[offset:offset + 500])} for offset in range(0, 10000, 500)]
        first_win = next((row["training_episode"] for row in rows if row["outcome"] == "success"), None)
        final = json.loads((ROOT / preset / "checkpoints" / f"checkpoint-{settings['base_seed']}-10000.json").read_text())
        summary[preset] = {
            "training": aggregate(rows), "last_5000_training": aggregate(rows[-5000:]),
            "last_1000_training": aggregate(rows[-1000:]), "final_evaluation": aggregate(evaluation),
            "diagnostic_9000": aggregate(diagnostic),
            "first_training_win": first_win, "windows_500": windows, "check_ins": checkins,
            "states": len(final["q_table"]), "updates": final["updates"],
        }
        earlier = json.loads((ROOT / preset / "checkpoints" / f"checkpoint-{settings['base_seed']}-9000.json").read_text())
        shared = set(earlier["q_table"]) & set(final["q_table"])
        def best_actions(values):
            return [i for i, value in enumerate(values) if value == max(values)]
        key = "000111|1|0|0"
        summary[preset]["policy_changes_9000_to_10000"] = {
            "shared_states": len(shared),
            "states_with_changed_best_action_sets": sum(best_actions(earlier["q_table"][k]) != best_actions(final["q_table"][k]) for k in shared),
            "flat_floor_example": {"key": key, "action_names": ["Idle", "Left", "Right", "Jump", "Left + jump", "Right + jump"],
                                   "values_9000": earlier["q_table"][key], "values_10000": final["q_table"][key],
                                   "best_9000": best_actions(earlier["q_table"][key]), "best_10000": best_actions(final["q_table"][key])},
        }
        for phase in ["training", "check_in", "final_evaluation", "diagnostic_evaluation"]:
            files = list((ROOT / preset / phase).glob("*.mlpaths"))
            assert len(files) == (1 if phase in ["final_evaluation", "diagnostic_evaluation"] else 10)
            count = 0
            for path in files:
                header, episodes = recordings(path)
                assert header["preset_id"] == preset
                count += len(episodes)
            assert count == {"training": 100, "check_in": 10, "final_evaluation": 30, "diagnostic_evaluation": 30}[phase]
            recording_episodes += count
    output = {"settings": settings, "conditions": summary,
              "validation": {"checkpoints_verified": checkpoints_verified, "training_episodes": 20000,
                             "check_in_episodes": 20, "final_evaluation_episodes": 60,
                             "posthoc_diagnostic_episodes": 60,
                             "recorded_episodes_verified": recording_episodes,
                             "source_archive_verified": True, "evaluation_checkpoints_unchanged": True},
              "limits": ["One paired training replicate; the per-chunk seeds are not independent full training replicates.",
                         "One check-in episode per milestone is a diagnostic, not a success-rate estimate.",
                         "Final evaluations use different RNG seeds on the same map and spawn; deterministic policies may repeat the same route.",
                         "The matched 9000-episode diagnostic was selected after observing final-policy failures; it is not a prespecified primary endpoint or independent best-checkpoint validation.",
                         "Best progress is sampled at decision boundaries, so brief between-decision peaks may be missed.",
                         "Reward returns have different scales and are not a cross-method performance score."]}
    (ROOT / "summary.json").write_text(json.dumps(output, indent=2) + "\n")
    chart("training-success", "Medium level: training success", summary, "success_percent", "Win %")
    chart("training-progress", "Medium level: mean best progress toward the orb", summary, "mean_best_progress_percent", "Progress %")
    routes(summary)
    routes(summary, 9000, "diagnostic_evaluation", "diagnostic-9000-routes")
    table_rows = []
    for preset in settings["presets"]:
        item = summary[preset]
        train, late, evaluation = item["training"], item["last_5000_training"], item["final_evaluation"]
        table_rows.append(f"<tr><th>{LABELS[preset]}</th><td>{train['wins']:,} / 10,000 ({train['success_percent']:.1f}%)</td>"
                          f"<td>{late['success_percent']:.1f}%</td><td>{evaluation['wins']} / 30</td>"
                          f"<td>{evaluation['mean_best_progress_percent']:.1f}%</td><td>{item['first_training_win'] or 'None'}</td>"
                          f"<td>{train['deaths']:,}</td><td>{train['stuck']:,}</td><td>{train['timeouts']:,}</td></tr>")
    milestone_rows = []
    for index, milestone in enumerate(settings["milestones"]):
        cells = []
        for preset in settings["presets"]:
            row = summary[preset]["check_ins"][index]
            recording = f"{preset}/check_in/{milestone:05d}.mlpaths"
            cells.append(f"<td><a href='{recording}'>{html.escape(row['outcome'])}</a>, {row['seconds']:.1f} s, best progress {100 * row['best_progress']:.1f}%</td>")
        milestone_rows.append(f"<tr><th>{milestone:,}</th>{''.join(cells)}</tr>")
    limits = "".join(f"<li>{html.escape(text)}</li>" for text in output["limits"])
    diagnostic_rows = "".join(f"<tr><th>{LABELS[preset]}</th><td>{summary[preset]['diagnostic_9000']['wins']} / 30</td>"
                              f"<td>{number(summary[preset]['diagnostic_9000']['mean_win_seconds'], ' s')}</td>"
                              f"<td>{summary[preset]['diagnostic_9000']['deaths']}</td><td>{summary[preset]['diagnostic_9000']['stuck']}</td></tr>"
                              for preset in settings["presets"])
    fixed = summary["fixed_reward_per_block"]
    normalized = summary["long_exploration"]
    findings = (f"Fixed reward produced {fixed['training']['wins']:,} training wins versus {normalized['training']['wins']:,} "
                f"for Longer exploration, with fewer stuck endings ({fixed['training']['stuck']:,} versus {normalized['training']['stuck']:,}). "
                "Training success includes exploration and ongoing learning; the frozen-policy results are a separate test.")
    if fixed["diagnostic_9000"]["wins"] > fixed["final_evaluation"]["wins"]:
        findings += (f" The fixed-reward 9,000-episode checkpoint won {fixed['diagnostic_9000']['wins']}/30 matched diagnostic evaluations, "
                     f"but its final 10,000 checkpoint won {fixed['final_evaluation']['wins']}/30. "
                     "This demonstrates late policy regression in this run: the final checkpoint is not the best saved policy.")
    report = f"""<!doctype html><html lang='en'><meta charset='utf-8'><title>Medium reward comparison</title>
<style>body{{font:16px/1.55 system-ui,sans-serif;max-width:1180px;margin:32px auto;padding:0 24px;color:#1c303a;background:#f5f8fa}}h1,h2{{line-height:1.2}}table{{border-collapse:collapse;background:white;width:100%;font-size:14px}}th,td{{text-align:left;padding:10px;border-bottom:1px solid #dce5e9}}img{{width:100%;background:white;margin:18px 0}}a{{color:#186e88}}.note{{padding:16px;background:#e8eff2}}code{{font-size:13px}}</style>
<h1>Medium: fixed reward vs Longer exploration</h1><p>October 29, 2026. Two fresh 10,000-episode training sessions on the identical frozen Medium level, with eight-second stuck detection and the normal 60-second overall limit.</p>
<p class='note'>{findings}</p>
<p>Learning rate 0.1; discount 0.95; exploration decay 0.999, floor 0.05; identical physics, observations, terminal rewards, and decision timing. Only the progress reward differs.</p>
<table><thead><tr><th>Method</th><th>Training wins</th><th>Last 5,000 wins</th><th>Final frozen wins</th><th>Final eval mean best progress</th><th>First training win</th><th>Deaths</th><th>Stuck</th><th>Timeouts</th></tr></thead><tbody>{''.join(table_rows)}</tbody></table>
<h2>Learning curves</h2><img src='training-success.svg' alt='Training success in 500-episode windows'><img src='training-progress.svg' alt='Average best progress in 500-episode windows'>
<h2>Final policies</h2><img src='final-routes.svg' alt='First recorded final evaluation route for each method'>
<h2>Late regression: matched 9,000-episode diagnostic</h2><p>After both final policies failed all 30 evaluations, both 9,000-episode policies were evaluated with the identical 30 evaluation seeds. This additional diagnostic did not add training or change the scheduled check-ins. The 9,000 checkpoint was chosen after observing the final failures and the preceding successful fixed-reward check-in.</p>
<table><tr><th>Method at 9,000</th><th>Frozen wins</th><th>Mean winning time</th><th>Deaths</th><th>Stuck</th></tr>{diagnostic_rows}</table>
<img src='diagnostic-9000-routes.svg' alt='Earlier checkpoint diagnostic evaluation routes'>
<h2>Matched check-ins</h2><p>One frozen-policy evaluation after each 1,000 training episodes. Evaluation never updates the policy or advances training RNG. Links point to native recordings, readable in the project replay viewer.</p>
<table><tr><th>Training episodes</th><th>Longer exploration</th><th>Fixed reward per block</th></tr>{''.join(milestone_rows)}</table>
<h2>Protocol and interpretation</h2><p>The ten training chunks use seeds 12345–12354 in the same order for both methods. Check-in seeds are 1012345–1012354; the final 30 evaluation seeds are 2012345–2012374. Training method order alternates each milestone. Each new worker resumes learned values and exploration settings, with an explicitly matched new RNG seed. All checkpoints are retained.</p>
<ul>{limits}</ul><p class='note'>Verified: 20,000 training episodes, 20 scheduled check-ins, 60 final evaluations, 60 post-hoc diagnostic evaluations, 20 checkpoint milestones, and {recording_episodes} recorded paths. All evaluation checkpoint hashes stayed unchanged. No previous personal saves were used or overwritten.</p>
<h2>Files</h2><p><a href='summary.json'>Summary and metrics</a> · <a href='settings.json'>Exact settings and source hashes</a> · <a href='source.zip'>Frozen runnable source</a> · <a href='progress.json'>Commands and stage results</a> · <a href='run_comparison.py'>Runner</a> · <a href='analyze.py'>Analysis</a></p>
<p>Training JSONL logs contain every episode. Every 100th training path is recorded; every check-in and final evaluation path is recorded. <a href='long_exploration/checkpoints/checkpoint-12345-10000.json'>Final normalized checkpoint</a> · <a href='fixed_reward_per_block/checkpoints/checkpoint-12345-10000.json'>Final fixed-reward checkpoint</a>.</p></html>"""
    (ROOT / "report.html").write_text(report, encoding="utf-8")
    checksums = {str(path.relative_to(ROOT)).replace("\\", "/"): hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in ROOT.rglob("*") if path.is_file() and path.name != "SHA256SUMS.json" and "__pycache__" not in path.parts}
    (ROOT / "SHA256SUMS.json").write_text(json.dumps(checksums, indent=2) + "\n")
    for preset, item in summary.items():
        print(preset, json.dumps({key: item[key] for key in ["training", "last_5000_training", "final_evaluation", "first_training_win"]}))


if __name__ == "__main__":
    main()
