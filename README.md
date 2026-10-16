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

For headless training from the project root:

```sh
godot --headless --path . --fixed-fps 60 --disable-render-loop --script res://Training/train.gd -- --episodes 1000
```

On macOS/Linux, `sh ./train.sh --episodes 1000` provides the same launcher. Set `GODOT_BIN` if Godot is not on your PATH. Use `--help` for training options.

## Check changes

Run a check from the project root, replacing the script name as needed:

```sh
godot --headless --path . --fixed-fps 60 --disable-render-loop --script res://Tests/check_gameplay.gd
```

Other checks are `check_q_learning.gd`, `check_q_checkpoint.gd`, `check_headless_training.gd`, `check_headless_menu.gd`, `check_training_checkins.gd`, and `check_training_trace.gd`, all in `Tests/`. The checkpoint, headless-menu, and training-check-in checks currently use `/tmp` for scratch files; on Windows they require an available scratch directory at that path or a local path substitution.

See [the project design and training guide](Docs/godot-platformer-plan.md) for controls, agent behavior, checkpoint details, and benchmarking. Experiment folders preserve historical snapshots and their original paths.
