"""Rebuild the comparison from archived raw data. Requires ReportLab and pdftoppm.
Keep this folder beside the two earlier experiments when running this script.
"""
import csv
import html
import json
from pathlib import Path
import statistics as st
import subprocess
from reportlab.graphics import renderPDF, renderSVG
from reportlab.graphics.charts.lineplots import LinePlot
from reportlab.graphics.shapes import Drawing, Rect, String
from reportlab.lib import colors

OUT = Path(__file__).resolve().parent
SEEDS = [12345, 42, 98765]
MILESTONES = [0, 100, 300, 600, 1000, 2000, 3000, 5000, 10000]
FOLDERS = {
    'baseline': OUT.parent / '2026-10-16-q-learning-baseline',
    'time_penalty': OUT.parent / '2026-10-16-q-learning-time-penalty',
    'long_exploration': OUT,
}
LABELS = ['Baseline', 'Time penalty', 'Longer exploration + time penalty']
PALETTE = ['#687482', '#008577', '#b34f18']


def read(path):
    return json.loads(path.read_text())


def stats(runs):
    wins = [r for r in runs if r['win']]
    result = dict(episodes=len(runs), wins=len(wins),
        timeouts=sum(r['timeout'] for r in runs),
        deaths=sum(not (r['win'] or r['timeout']) for r in runs),
        success_rate=len(wins)/len(runs),
        mean_seconds=st.mean(r['ticks']/60 for r in runs),
        mean_win_seconds=st.mean(r['ticks']/60 for r in wins) if wins else None)
    if 'jumps' in runs[0]:
        actions = [sum(r['actions'][i] for r in runs) for i in range(6)]
        result.update(mean_jumps=st.mean(r['jumps'] for r in runs),
            mean_win_jumps=st.mean(r['jumps'] for r in wins) if wins else None,
            idle_action_fraction=actions[0]/sum(actions),
            jump_action_fraction=sum(actions[3:])/sum(actions),
            mean_longest_still_seconds=st.mean(r['longest_still_ticks']/60 for r in runs),
            max_longest_still_seconds=max(r['longest_still_ticks']/60 for r in runs))
    return result


def csvwrite(name, rows):
    with (OUT/name).open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]), lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)


def chart(name, title, subtitle, series, ymax, ystep, ylabel):
    drawing = Drawing(1000, 390)
    drawing.add(Rect(0, 0, 1000, 390, fillColor=colors.white, strokeColor=None))
    drawing.add(String(65, 360, title, fontSize=19))
    drawing.add(String(65, 338, subtitle, fontSize=11))
    plot = LinePlot()
    plot.x, plot.y, plot.width, plot.height = 65, 60, 875, 235
    plot.data = series
    plot.xValueAxis.valueMin = 0
    plot.xValueAxis.valueMax = 10000
    plot.xValueAxis.valueStep = 2000
    plot.yValueAxis.valueMin = 0
    plot.yValueAxis.valueMax = ymax
    plot.yValueAxis.valueStep = ystep
    for i, color in enumerate(PALETTE):
        plot.lines[i].strokeColor = colors.HexColor(color)
        plot.lines[i].strokeWidth = 2.4
        drawing.add(String([65, 230, 420][i], 315, LABELS[i], fontSize=11, fillColor=colors.HexColor(color)))
    drawing.add(plot)
    drawing.add(String(390, 18, 'Completed training episodes', fontSize=12))
    drawing.add(String(5, 290, ylabel, fontSize=10))
    renderSVG.drawToFile(drawing, str(OUT/(name+'.svg')))
    renderPDF.drawToFile(drawing, str(OUT/(name+'.pdf')))
    subprocess.run(['pdftoppm', '-scale-to', '1800', '-png', '-singlefile',
        str(OUT/(name+'.pdf')), str(OUT/name)], check=True, capture_output=True)


data = {c: {s: read(p/f'raw-data/results-{s}.json') for s in SEEDS} for c, p in FOLDERS.items()}
for condition, runs in data.items():
    for seed, run in runs.items():
        assert len(run['training']) == 10000, (condition, seed)
        assert [e['episode'] for e in run['evaluations']] == MILESTONES
        assert all(len(e['runs']) == 30 for e in run['evaluations'])
summary = {'seeds': SEEDS, 'episodes_per_seed': 10000, 'conditions': list(FOLDERS),
    'totals': {}, 'training_windows': [], 'evaluations': []}
for c, runs in data.items():
    summary['totals'][c] = stats([r for d in runs.values() for r in d['training']])
for lo, hi in [(0,100),(100,300),(300,600),(600,1000),(1000,2000),(2000,3000),(3000,5000),(5000,10000),(9000,10000)]:
    window = {'first_episode': lo+1, 'last_episode': hi}
    for c, runs in data.items():
        window[c] = {**stats([r for d in runs.values() for r in d['training'][lo:hi]]),
            'per_seed': [{'seed': s, **stats(d['training'][lo:hi])} for s, d in runs.items()]}
    summary['training_windows'].append(window)
for i, milestone in enumerate(MILESTONES):
    evaluation = {'training_episodes': milestone}
    for c, runs in data.items():
        evaluation[c] = {**stats([r for d in runs.values() for r in d['evaluations'][i]['runs']]),
            'per_seed': [{'seed': s, 'epsilon': d['evaluations'][i]['epsilon'],
                'rows': d['evaluations'][i]['rows'], **stats(d['evaluations'][i]['runs'])} for s, d in runs.items()]}
    summary['evaluations'].append(evaluation)
summary['saved_policy_probes'] = {str(s): stats(read(OUT/f'raw-data/results-{s}.json')['evaluations'][0]['runs']) for s in [2026,2027]}
(OUT/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
csvwrite('training-curve.csv', [{'condition': c, 'seed': s, 'first_episode': end-499,
    'last_episode': end, **stats(d['training'][end-500:end])}
    for c, runs in data.items() for s, d in runs.items() for end in range(500,10001,500)])
csvwrite('evaluation-results.csv', [{'condition': c, 'training_episodes': e['training_episodes'], **s}
    for e in summary['evaluations'] for c in FOLDERS for s in e[c]['per_seed']])
csvwrite('exploration-schedule.csv', [{'episode': e, 'baseline_and_time_penalty': max(.05,.995**e),
    'long_exploration': max(.05,.999**e)} for e in MILESTONES])
chart('training-comparison', 'Does longer exploration help?',
    'Training win rate: mean of three seeds, non-overlapping 500-episode windows',
    [[(end,100*st.mean(sum(r['win'] for r in d['training'][end-500:end])/500 for d in runs.values()))
        for end in range(500,10001,500)] for runs in data.values()], 100, 20, 'Win %')
chart('evaluation-comparison', 'Greedy evaluation at each checkpoint',
    '90 episodes per point: three trained seeds, 30 fixed-spawn episodes each; repeated paths are not independent trials',
    [[(e['training_episodes'], 100*e[c]['success_rate']) for e in summary['evaluations']] for c in FOLDERS], 100, 20, 'Win %')


def pct(value):
    return f'{100*value:.1f}%'


def table(headers, rows):
    return '<div class="scroll"><table><thead><tr>'+''.join('<th>'+html.escape(str(x))+'</th>' for x in headers)+'</tr></thead><tbody>'+''.join('<tr>'+''.join('<td>'+html.escape(str(x))+'</td>' for x in row)+'</tr>' for row in rows)+'</tbody></table></div>'


final = summary['evaluations'][-1]
rows = []
for label, source, key, fmt in [
    ('All training: win rate',summary['totals'],'success_rate',pct),
    ('Training 5,001–10,000: win rate',summary['training_windows'][-2],'success_rate',pct),
    ('Training 9,001–10,000: win rate',summary['training_windows'][-1],'success_rate',pct),
    ('All training: deaths',summary['totals'],'deaths',str),
    ('All training: timeouts',summary['totals'],'timeouts',str),
    ('Final greedy evaluation: wins',final,'wins',lambda x:f'{x}/90'),
    ('Final evaluation: mean duration',final,'mean_seconds',lambda x:f'{x:.2f} s'),
    ('Final evaluation: actual takeoffs',final,'mean_jumps',lambda x:f'{x:.2f}'),
    ('Final evaluation: idle action share',final,'idle_action_fraction',pct),
    ('Final evaluation: jump action share',final,'jump_action_fraction',pct)]:
    rows.append([label]+[fmt(source[c][key]) for c in FOLDERS])
window_rows = [[f"{w['first_episode']:,}–{w['last_episode']:,}"]+[pct(w[c]['success_rate']) for c in FOLDERS] for w in summary['training_windows']]
seed_rows = [[s]+[f"{final[c]['per_seed'][i]['wins']}/30; {final[c]['per_seed'][i]['mean_seconds']:.2f} s; {final[c]['per_seed'][i]['mean_jumps']:.1f} jumps" for c in FOLDERS] for i,s in enumerate(SEEDS)]
eval_rows = [[e['training_episodes'],s]+[f"{e[c]['per_seed'][i]['wins']}/30; {e[c]['per_seed'][i]['timeouts']} T; {e[c]['per_seed'][i]['deaths']} D" for c in FOLDERS] for e in summary['evaluations'] for i,s in enumerate(SEEDS)]
findings = (OUT/'findings.txt').read_text()
page = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Platformer: longer exploration</title><style>body{font:16px/1.6 system-ui,sans-serif;background:#f3f6f8;color:#182838;margin:0}main{max-width:1100px;margin:auto;padding:42px 24px}h1{font-size:36px;line-height:1.15}h2{font-size:23px;margin-top:36px}p{max-width:930px}.tag{color:#a34512;font-weight:650}table{border-collapse:collapse;width:100%;font-size:14px;background:white}th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #dce3e8}th{background:#e8eef2}img{width:100%;background:white;margin:18px 0}.scroll{overflow-x:auto}a{color:#006c63}.findings{white-space:pre-line;background:white;border-left:4px solid #b34f18;padding:16px 22px}footer{font-size:13px;color:#526373;margin-top:35px}</style><main><p class="tag">PLATFORMER EXPERIMENT 03 · 16 OCTOBER 2026</p><h1>Give exploration five times longer</h1><p>The only new change is exploration decay: 0.995 → 0.999 per completed training episode. Exploration starts at 100% and reaches its unchanged 5% floor after 2,995 episodes instead of 598. The −0.001 time cost per six-frame decision stays enabled. Physics, observations, actions, other rewards, learning rate and discount are unchanged.</p>'''
page += table(['Setting']+LABELS,[['Decay multiplier',.995,.995,.999],['5% floor reached after episodes',598,598,2995],['Exploration after 1,000 episodes','5%','5%','36.8%'],['Time cost per decision',0,.001,.001]])
page += '<div class="findings">'+html.escape(findings)+'</div><h2>Three-way comparison</h2>'+table(['Metric']+LABELS,rows)
page += '<p>Training includes random exploratory actions. Its early win rate is not a fair stand-alone measure of policy quality when schedules differ. Frozen greedy evaluations remove exploration. All schedules are at 5% after episode 2,995, so the later training windows also help comparison. Duration and jump counts include failures: check the win rate alongside them. Raw returns are not compared across reward definitions.</p><img src="training-comparison.svg" alt="Training success under all three conditions"><img src="evaluation-comparison.svg" alt="Greedy checkpoint evaluation success under all three conditions"><h2>Final checkpoint, by seed</h2>'+table(['Training seed']+LABELS,seed_rows)
page += '<h2>Training windows</h2>'+table(['Episodes per seed']+LABELS,window_rows)
page += '<details><summary>All evaluation checkpoints: wins, timeouts (T), deaths (D)</summary>'+table(['Training episodes','Seed']+LABELS,eval_rows)+'</details>'
page += '''<h2>Method and limitations</h2><p>Same diagnostic scripts as the saved baseline: seeds 12345, 42 and 98765; 10,000 uninterrupted fresh training episodes each. Nine saved milestones are evaluated afterward, with 30 episodes per seed/checkpoint and evaluation RNG seed = training seed + 1,000,000. Learning and exploration are disabled during evaluation. Only three training seeds and one fixed map/spawn are tested; repeated greedy evaluations often repeat an identical route. These are descriptive results, not evidence of generalization or a precise convergence point. Longer exploration without the time penalty was not tested, so this experiment measures the added schedule change with the penalty present.</p><p>The original 16,988-episode saved policy was also retested: 0/30 greedy wins, or 89/100 with fixed 5% exploration and no learning. Its traces, outcomes and rewards match the time-penalty experiment exactly. Its checkpoint restores the old schedule; changing a fresh-agent default does not rewrite a saved table.</p><p>The normal headless worker matches the diagnostic checkpoint after 1,000 episodes when both receive the same JSON load/save round trip. Seven regression checks pass, including identical visible/headless physics and learning traces. Both earlier experiment archives were verified by checksum.</p><h2>Reload or use in the video</h2><p><a href="START-HERE.txt">Reload and reproduce</a> · <a href="settings.json">Settings</a> · <a href="summary.json">Summary</a> · <a href="evaluation-results.csv">Evaluation CSV</a> · <a href="training-curve.csv">Training CSV</a> · <a href="exploration-schedule.csv">Exploration schedule</a> · <a href="experiment.zip">Frozen project</a> · <a href="../2026-10-16-q-learning-baseline/report.html">Baseline report</a> · <a href="../2026-10-16-q-learning-time-penalty/report.html">Time-penalty report</a></p><footer>Checkpoints, per-episode results, recorded decision traces, charts and validation logs are preserved beside this report. Your live saved agent was not replaced.</footer></main></html>'''
(OUT/'report.html').write_text(page)
print(json.dumps({'totals':summary['totals'],'final':final,'last_window':summary['training_windows'][-1]},indent=2))
