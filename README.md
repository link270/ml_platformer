# ML Platformer

A small Godot platformer for human play, random agents, and Q-learning.

## Project layout

| Folder | Contents |
| --- | --- |
| `Game/` | Level, player, and block scenes; movement, sensing, rewards, and episode logic. Scenes live beside their scripts. |
| `UI/` | Main menu, agent display, and background-training controls. |
| `Agents/` | Agent interface, random policy, Q-learning, state encoding, and checkpoint persistence. |
| `Training/` | Command-line training worker and repeatable training benchmark. |
| `Tests/` | Executable checks for gameplay, learning, checkpoints, menus, and training parity. |
| `Docs/` | Design notes, implementation details, and recorded benchmark results. |
| `Experiments/` | Dated experiment reports, raw data, checkpoints, and archived project snapshots. Start with each experiment's `START-HERE.txt`. |

`project.godot` is the project entry point. `train.sh` stays at the root as a convenient training launcher. Godot's `.gd.uid` files belong with their scripts; `.godot/` is generated cache, and `.idea/` contains IDE settings.

## Run

Open `project.godot` in Godot 4.7 or later and run the project. It starts at `UI/MainMenu.tscn`.

Choose a controller, Training or Evaluation, saved training data, and the number of runs. A run ends on a win, death, timeout, or an optional stuck cutoff. Enable **Run headless** to keep just the setup screen and progress visible. Human play is unrestricted; the random agent only evaluates, since it has nothing to learn.

The **Level** selector includes the original course and four new 3,840 × 540 courses (four times the original width). All new courses start on the left and put the orb on the right, with a following camera and a 60-second agent episode limit:

| Level | Layout |
| --- | --- |
| Large template | 120 floor blocks in a continuous row; duplicate `Game/Levels/LargeTemplate.tscn` to start another level. |
| Easy | Continuous ground, low hurdles, and broad stepped hills. No pits. |
| Medium | Broad raised platforms, stairs, and 32–64 pixel gaps with safe landing space. |
| Hard | Chains of elevated platforms, 64-pixel gaps, and shorter 96-pixel landings, separated by rest areas. |

The new scenes inherit shared player, orb, camera, and HUD nodes from `Game/Levels/CourseBase.tscn`; blocks remain individual editable scene instances. New scenes also run directly in human mode. Switching levels selects **New training data**; new save filenames include the course name. Existing checkpoints can still be explicitly selected for transfer training. The original course remains the default for existing experiments.

`Tests/check_training_levels.gd` verifies every new course from spawn to orb using actual player collisions and six-tick agent actions, with three jump launch margins. This proves a route exists; it does not guarantee a particular learning algorithm will discover it. The hard course requires more consecutive jumps, without increasing movement speed or requiring pixel-perfect landings.

Q-learning's **Training data** dropdown reads `.json` checkpoints from `user://checkpoints` in Godot's application-data folder. **Folder** opens that location; **Refresh** picks up added or renamed files. The original `user://q_learning_checkpoint.json` save also appears if it exists.

- **New training data** creates a timestamped file, without replacing other saves.
- Training with an existing file continues learning and updates that file.
- Visible training saves when its run count is reached, on **Menu / Esc**, and before switching to evaluation. **More → Save now** saves on demand.
- Headless training saves every 100 runs and on completion or **Stop & save**. **Watch every** optionally pauses to show one evaluation run; `0` disables these check-ins.
- Evaluation runs never write to the selected file. Both visible and headless agent sessions stop at the requested count.

The game shows a small outcome panel and run progress. **More** expands learning details and save/mode controls. **V** toggles sensors, **R** restarts an unfinished episode, and **Esc** returns to setup. Completing a batch leaves its final result on screen.

While watching an agent, **Time** shows elapsed simulation seconds / the run's timeout (20 seconds on the original course, 60 on the larger courses). It resets for each attempt and stops when the run ends. **Speed** supports 0.5×, 1×, 2×, 4×, 8×, 16×, 32×, 64×, and 128× during training, evaluation, random-agent runs, and visible check-ins. Speed changes preserve the simulation's physics steps and timeout; returning to setup restores normal timing. High speeds are targets: the actual rate depends on hardware and the cost of physics, sensors, trails, and UI rendering. They process every physics step rather than skipping gameplay or learning updates.

**Stuck detection (8s)** is optional and defaults off. When enabled, an agent attempt ends after eight simulation seconds without another full block (32 pixels) of best progress toward the orb. Progress uses Euclidean distance from the player center to the orb; small advances accumulate toward the next block. Backtracking or revisiting the same positions does not refill patience. The overall timeout remains in place, and human play is unaffected. The live HUD shows remaining **Patience** and a separate **Stuck** count; headless progress aggregates that count across worker chunks. A stuck ending uses the ordinary -1 failure reward, with no extra penalty, and preserves the agent's learned data.

The toggle applies to training, evaluation, and visible check-ins, and is remembered while the app is open. For an on/off comparison, use the same level, reward preset, and run budget with fresh data for each condition. Fresh saves with detection enabled include `_stuck` in their filenames; recordings identify the setting and distinguish `stuck` outcomes. Existing saves can still be explicitly selected to continue training or compare an already learned policy. The CLI accepts `--stuck-detection on` or `off`; default CLI save paths also get a `_stuck` suffix when enabled. `Tests/check_stuck_detection.gd` verifies cutoff timing, meaningful progress, counters, recording/playback, and headless propagation.

Faint background dots and ascending block coordinates provide movement landmarks without competing with path trails. **Whole level** in the live HUD toggles between following the player and fitting the complete course, during human play, training, evaluation, or a check-in. The view selection survives episode resets and returning to setup until the application closes.

**Record every** defaults to `0` (off). Set `1` to record every episode or `X` to save episodes X, 2X, 3X within the new session. **Folder** beside it opens `user://recordings/`. **Show live path trails** draws the current attempt brightly and keeps the last 50 completed paths, fading older paths. Green endpoints mark successes, red deaths, amber timeouts, and purple stuck endings. Trails work independently of disk recording; headless runs skip drawing.

Recording works for visible and headless agent sessions, including evaluation. Headless check-in chunks create separate recording files and preserve the session's sampling interval; the evaluation check-ins themselves are excluded. Recordings contain complete episodes only; restarting or leaving an unfinished attempt discards that partial recording. See [episode recording](Docs/episode-recording.md) for the file format and benchmark.

Choose **Playback recordings → Open recordings…** to select one or more saved `.mlpaths` files. Play sequentially or in simultaneous groups of up to 100 ghosts, with the same persistent trails. **Show every** selects every Xth saved episode (`1` = all). Pause, restart, and playback speeds from 0.25× to 8× are available. Playback uses interpolated positions without physics or training; only the active group's positions are loaded.

**Show heat map** in either the live HUD or playback viewer highlights commonly visited areas independently of trails. It counts each episode once per 16-pixel cell, including active paths so far, on a fixed 0–100% scale. Standing still does not add extra heat. The overlay defaults off and collects while hidden; playback includes only selected episodes as they play. Headless training skips the grid. See [heat-map behavior](Docs/episode-recording.md#heat-map) for reset and counting details.

For headless training from the project root:

```sh
godot --headless --path . --fixed-fps 60 --disable-render-loop --script res://Training/train.gd -- --episodes 1000
```

Add `--record-every 10` to save every tenth episode. Optional `--record-to /absolute/path/session.mlpaths` selects a new recording file; an existing file is never overwritten.

Add `--level template`, `--level easy`, `--level medium`, or `--level hard` for a larger course; the default is `--level original`. Default CLI save filenames include the new course ID; when specifying `--save`, use a separate path for each course. The setup screen passes its selected level to headless workers and evaluation check-ins. Recordings remember their course; playback follows sequential ghosts and shows the whole course for simultaneous groups. Open recordings from one course at a time.

On macOS/Linux, `sh ./train.sh --episodes 1000` provides the same launcher. Set `GODOT_BIN` if Godot is not on your PATH. Use `--help` for training options.

## Headless performance

The headless worker groups 16 physics ticks into each engine frame, scaling the
clock to retain 60 simulated physics ticks per second and six ticks per agent
decision. Every physics step and learning update still runs. Derived state-key
strings and fixed ray geometry are cached; repeated distance calculations and
temporary Q-value arrays are avoided, and the unused headless camera is disabled.
Checkpoint frequency, recording samples, stop/save behavior, and check-ins are
preserved. A completed or failed worker stops simulation before the remaining
ticks in its current frame can advance another attempt.

Measured on Windows / Godot 4.7.2 with three serial alternating-order before/after
pairs per workload, seed 12345, and normal saves every 100 episodes:

| Workload | Before, runs/s | After, runs/s | Throughput gain |
| --- | ---: | ---: | ---: |
| Fresh Easy, normalized rewards | 18.33 | 21.34 | 16.4% |
| Fresh Easy, fixed rewards | 19.54 | 22.73 | 16.4% |
| Continuing Easy, fixed rewards | 30.41 | 35.99 | 18.3% |
| Continuing Easy, recording every run | 30.53 | 34.53 | 13.1% |
| Original small level | 33.99 | 34.16 | 0.5% — within timing variation |

All compared behavior/RNG fingerprints, checkpoint bytes, and recorded episode
metadata/sample bytes matched. Before/after observation, action, physics, and
learning traces also matched across three seeds, with visible/headless parity.
All 15 regression checks passed; the state-key cache is checked against the
original representation for all 1,728 binary and 3,888 horizontal-bin states.
The mature-policy fixture was copied from a completed save; the original save
was not changed. See [raw measurements and validation](Docs/headless-optimization-benchmark.json)
for trial sizes, timings, hashes, and limitations.

`Training/benchmark_training.gd` accepts the worker's options and uses seed 12345.
Supply a new scratch `--save` path; its `.benchmark.json` sidecar reports timing
and a behavior fingerprint. Timings include training, saves, and recording,
excluding process startup and final fingerprint construction.

## Check changes

Run a check from the project root, replacing the script name as needed:

```sh
godot --headless --path . --fixed-fps 60 --disable-render-loop --script res://Tests/check_gameplay.gd
```

Other checks are `check_q_learning.gd`, `check_q_checkpoint.gd`, `check_headless_training.gd`, `check_headless_menu.gd`, `check_training_checkins.gd`, `check_training_trace.gd`, `check_episode_recording.gd`, `check_episode_playback.gd`, `check_path_heatmap.gd`, and `check_run_setup.gd`, all in `Tests/`. Checks that write files create unique directories in the operating system's temporary location and clean them up afterward. The same commands work on Windows, macOS, and Linux without scratch-path changes.

See [the project design and training guide](Docs/godot-platformer-plan.md) for controls, agent behavior, checkpoint details, and benchmarking. Experiment folders preserve historical snapshots and their original paths.

For filming the six Q-learning experiment stages, see [Q-learning experiment modes](Docs/experiment-modes.md). The setup form includes matching archived Q-tables.

**7. Fixed reward per block** is a separate experiment based on **3. Longer exploration**. It replaces normalized progress with **0.005 per 32 pixels closer to the orb**, with an equal cost for moving away. All other settings, the time penalty, and terminal rewards stay the same. Compare the two on the same larger level with fresh training data and equal run budgets. The new experiment has separate saves and no archived results yet; CLI runs accept `--preset fixed_reward_per_block`. See the [reward comparison](Docs/experiment-modes.md#fixed-reward-per-block-comparison) for the exact formula.
