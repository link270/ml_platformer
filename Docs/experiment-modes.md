# Q-learning experiment modes

Select **Q-learning**, then choose an **Experiment**. Its description shows what
changed. Choose **Evaluation** and a checkpoint under **Training data**, then
**Start evaluation**. Leave **Run headless** off to watch the viewport. **Options**
shows the loaded archive label. Esc returns to setup.

For the filming sequence, select **Easy · steps and hills** and **Evaluation**
before switching between the first three experiments. The menu picks the
untrained Original baseline, Fixed reward per block at 5,000 runs, and Fixed
reward + course position at 10,000 runs. The selector also offers the 1,000,
5,000, and 10,000 checkpoints for each experiment on Easy. Choosing an Easy
archive enables the eight-second stuck cutoff used in the comparison.

| Mode | Change |
| --- | --- |
| Original baseline | Six binary rays, no time cost, exploration decay 0.995 |
| Fixed reward per block | Longer exploration with 0.005 reward per block of reduced orb distance |
| Fixed reward + course position | Fixed reward per block with signed horizontal distance to the orb in four-block bands |
| Fixed reward + gap rays | Fixed reward per block with bounded ground probes for runway, gap width, and landing height |
| Fixed reward + landing memory | Gap rays with a remembered far lip during the jump |
| Small time penalty | Baseline plus 0.001 cost per six-frame decision |
| Longer exploration | Small time penalty with exploration decay 0.999 (default) |
| Higher discount | Longer exploration with discount 0.99 instead of 0.95 |
| Richer horizontal rays | Longer exploration with left/right near, far, or no hit |
| Lower late learning rate | Longer exploration with learning rate tapering from 0.1 to 0.02 over episodes 3,000–10,000 |

Horizontal near means a hit within one block of the character's edge; far means
beyond one block within the existing two-block ray. The other four rays remain
binary. All modes share the same physics, six actions, and decision timing.

The original course offers archived data for three training seeds (12345, 42, 98765) at nine milestones
(0, 100, 300, 600, 1,000, 2,000, 3,000, 5,000, 10,000 episodes).
Viewport evaluation of an archive starts with the diagnostic tie-break seed, so reopening the
same archive repeats its recorded first evaluation. Subsequent episodes advance
the random stream normally. To repeat a clip, return to the menu and reload;
R only restarts the episode.

## Fixed reward per block comparison

Choose a larger **Level**, then compare **Longer exploration** against
**Fixed reward per block**, starting each with **New training data** and the
same run budget. The fixed-reward preset's learning rate (0.1),
discount (0.95), exploration decay (0.999), exploration floor (0.05), observations,
physics, action timing, timeout, and terminal rewards match Longer exploration.

For every nonterminal physics step, both fixed-reward presets use:

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
Use `--preset course_position --level easy` to train with the additional position observation.

## Gap ray comparison

**Fixed reward + gap rays** keeps the six original rays, six actions, and
fixed-reward training settings. On the ground it samples nearby surfaces
every 16 pixels toward the orb's horizontal direction. It looks for a gap
within 96 pixels and for the far platform within 160 pixels, up to 64 pixels
above or below the player's feet. The Q-table receives the edge-distance bin
and a combined gap-width and landing-height bin. Missing landings have their
own value, and airborne decisions keep the original observations.

The **V** sensor overlay also shows these probes. In **Evaluation**, choose
Easy, Medium, or Hard and select one of this preset's archives under
**Training data**. The matched archive enables the recorded stuck cutoff.
For new command-line training, use `--preset gap_rays`.

**Fixed reward + landing memory** keeps the same grounded scan. While
airborne, its Q-table distinguishes a remembered lip behind, aligned,
near ahead, or far ahead, plus whether the player has enough vertical
clearance. The target clears on touchdown and restart. A Hard archive is
available at each milestone. Use `--preset airborne_landing` for training.

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
