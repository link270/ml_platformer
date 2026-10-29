# Q-learning experiment modes

Select **Q-learning**, then choose an **Experiment**. Its description shows what
changed. Choose **Evaluation** and an **Archive · seed … · … episodes** under
**Training data**, then **Start evaluation** to film it. Leave **Run headless**
off to watch the viewport. The mode name stays visible in the level; **More**
shows the loaded archive's seed and milestone. Esc returns to the same selection.

| Mode | Change |
| --- | --- |
| 1. Original baseline | Six binary rays, no time cost, exploration decay 0.995 |
| 2. Small time penalty | Baseline plus 0.001 cost per six-frame decision |
| 3. Longer exploration | Mode 2 with exploration decay 0.999 (existing default) |
| 4. Higher discount | Mode 3 with discount 0.99 instead of 0.95 |
| 5. Richer horizontal rays | Mode 3 with left/right near, far, or no hit |
| 6. Lower late learning rate | Mode 3 with learning rate tapering from 0.1 to 0.02 over episodes 3,000–10,000 |
| 7. Fixed reward per block | Mode 3 with 0.005 reward per block of reduced orb distance, replacing normalized progress rewards |

Modes 4–7 are separate experiments based on mode 3, not cumulative upgrades.
Horizontal near means a hit within one block of the character's edge; far means
beyond one block within the existing two-block ray. The other four rays remain
binary. All modes share the same physics, six actions, and decision timing.

Modes 1–6 offer archived data for three training seeds (12345, 42, 98765) at nine milestones
(0, 100, 300, 600, 1,000, 2,000, 3,000, 5,000, 10,000 episodes).
Viewport evaluation of an archive starts with the diagnostic tie-break seed, so reopening the
same archive repeats its recorded first evaluation. Subsequent episodes advance
the random stream normally. To repeat a clip, return to the menu and reload;
R only restarts the episode.

## Fixed reward per block comparison

Choose a larger **Level**, then compare **3. Longer exploration** against
**7. Fixed reward per block**, starting each with **New training data** and the
same run budget. Mode 7 has no archived results yet. Its learning rate (0.1),
discount (0.95), exploration decay (0.999), exploration floor (0.05), observations,
physics, action timing, timeout, and terminal rewards are the same as mode 3.

For every nonterminal physics step, mode 7 uses:

`reward = 0.005 * (previous_orb_distance - current_orb_distance) / 32 - 0.001 / 6`

Distances are Euclidean pixels; one block is 32 pixels. Moving closer earns
progress reward, moving away incurs the same progress cost, and standing still
only pays the existing time penalty. This also applies beyond the starting
distance, without clipping progress to the normalized proximity range. Death
and timeout still give exactly -1; orb collection gives exactly +1. The standard
normalized reward remains unchanged in the other modes.

The separate preset ID, checkpoint reward schema, and filenames keep these
results separate from normalized-reward saves. Visible training, evaluation,
headless workers, recordings, and check-ins all use the selected reward preset.
For a terminal run, add `--preset fixed_reward_per_block --level easy` (or
`medium` / `hard`). `Tests/check_fixed_reward.gd` checks reward scaling, resets,
terminal outcomes, checkpoint isolation, and the worker/check-in path.

## Training and saves

- Choose **Training** and **New training data** to start an empty table.
- Choose a saved file to continue training, or **Evaluation** to watch it.
- **Run headless** uses the same mode and selected data. **Watch every** adds
  evaluation check-ins during training.
- Fresh training and continued archives get timestamped files in
  `user://checkpoints/`. Continuing a personal save updates that file.
  Training saves automatically at completion and on return to the menu.
- Archived files under `Experiments/` stay unchanged, even if you switch a
  viewport evaluation back to training. Evaluation never saves training data.
- After a headless training batch, the selector switches to the new session save.
- Earlier `user://q_learning_checkpoint.json` and per-mode saves remain available.
  Hover over **Training data** for the full selected path; **Folder** opens
  the personal checkpoint directory.

New saves include their mode ID and reject loading into a different mode. Older
archives have no mode ID; their catalog folder supplies the matching mode.
Keep the archived JSON files in `Experiments/` available when running the project.

The small catalog and fresh-agent settings live in `Agents/QPresets.gd`.
The shared agent, state encoder, and reward calculation still live in
`Agents/QLearningAgent.gd`, `Agents/QState.gd`, and `Game/Level.gd`.
The terminal worker also accepts `--preset <mode ID>`; its default save follows
the preset unless `--save` is explicitly supplied.

## Useful footage from the follow-up report

| Mode | Seed | Episodes | Recorded behavior |
| --- | --- | --- | --- |
| Higher discount | 98765 | 100 | Early fast success |
| Higher discount | 12345 | 300 | Stands still until timeout |
| Higher discount | 12345 | 600 | Repeated jumping without winning |
| Richer horizontal rays | 98765 | 3000 | Fast successful route |
| Richer horizontal rays | 12345 | 10000 | Dies despite earlier successful checkpoints |
| Lower late learning rate | 42 | 5000 | Successful route during the learning-rate taper |

`Tests/check_q_presets.gd` checks all 162 archived loads, replays the 18 final
checkpoints and 12 report candidates against their recorded results, and resumes
each mode through a headless worker and visible check-in using temporary saves.
