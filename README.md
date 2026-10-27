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

Choose a controller, Training or Evaluation, saved training data, and the number of runs. A run ends on a win, death, or timeout. Enable **Run headless** to keep just the setup screen and progress visible. Human play is unrestricted; the random agent only evaluates, since it has nothing to learn.

Q-learning's **Training data** dropdown reads `.json` checkpoints from `user://checkpoints` in Godot's application-data folder. **Folder** opens that location; **Refresh** picks up added or renamed files. The original `user://q_learning_checkpoint.json` save also appears if it exists.

- **New training data** creates a timestamped file, without replacing other saves.
- Training with an existing file continues learning and updates that file.
- Visible training saves when its run count is reached, on **Menu / Esc**, and before switching to evaluation. **More → Save now** saves on demand.
- Headless training saves every 100 runs and on completion or **Stop & save**. **Watch every** optionally pauses to show one evaluation run; `0` disables these check-ins.
- Evaluation runs never write to the selected file. Both visible and headless agent sessions stop at the requested count.

The game shows a small outcome panel and run progress. **More** expands learning details and save/mode controls. **V** toggles sensors, **R** restarts an unfinished episode, and **Esc** returns to setup. Completing a batch leaves its final result on screen.

**Record every** defaults to `0` (off). Set `1` to record every episode or `X` to save episodes X, 2X, 3X within the new session. **Folder** beside it opens `user://recordings/`. **Show live path trails** draws the current attempt brightly and keeps the last 50 completed paths, fading older paths. Green endpoints mark successes, red deaths, and amber timeouts. Trails work independently of disk recording; headless runs skip drawing.

Recording works for visible and headless agent sessions, including evaluation. Headless check-in chunks create separate recording files and preserve the session's sampling interval; the evaluation check-ins themselves are excluded. Recordings contain complete episodes only; restarting or leaving an unfinished attempt discards that partial recording. See [episode recording](Docs/episode-recording.md) for the file format and benchmark.

Choose **Playback recordings → Open recordings…** to select one or more saved `.mlpaths` files. Play sequentially or in simultaneous groups of up to 100 ghosts, with the same persistent trails. **Show every** selects every Xth saved episode (`1` = all). Pause, restart, and playback speeds from 0.25× to 8× are available. Playback uses interpolated positions without physics or training; only the active group's positions are loaded.

**Show heat map** in either the live HUD or playback viewer highlights commonly visited areas independently of trails. It counts each episode once per 16-pixel cell, including active paths so far, on a fixed 0–100% scale. Standing still does not add extra heat. The overlay defaults off and collects while hidden; playback includes only selected episodes as they play. Headless training skips the grid. See [heat-map behavior](Docs/episode-recording.md#heat-map) for reset and counting details.

For headless training from the project root:

```sh
godot --headless --path . --fixed-fps 60 --disable-render-loop --script res://Training/train.gd -- --episodes 1000
```

Add `--record-every 10` to save every tenth episode. Optional `--record-to /absolute/path/session.mlpaths` selects a new recording file; an existing file is never overwritten.

On macOS/Linux, `sh ./train.sh --episodes 1000` provides the same launcher. Set `GODOT_BIN` if Godot is not on your PATH. Use `--help` for training options.

## Check changes

Run a check from the project root, replacing the script name as needed:

```sh
godot --headless --path . --fixed-fps 60 --disable-render-loop --script res://Tests/check_gameplay.gd
```

Other checks are `check_q_learning.gd`, `check_q_checkpoint.gd`, `check_headless_training.gd`, `check_headless_menu.gd`, `check_training_checkins.gd`, `check_training_trace.gd`, `check_episode_recording.gd`, `check_episode_playback.gd`, `check_path_heatmap.gd`, and `check_run_setup.gd`, all in `Tests/`. Checks that write files create unique directories in the operating system's temporary location and clean them up afterward. The same commands work on Windows, macOS, and Linux without scratch-path changes.

See [the project design and training guide](Docs/godot-platformer-plan.md) for controls, agent behavior, checkpoint details, and benchmarking. Experiment folders preserve historical snapshots and their original paths.

For filming the six Q-learning experiment stages, see [Q-learning experiment modes](Docs/experiment-modes.md). The setup form includes matching archived Q-tables.
