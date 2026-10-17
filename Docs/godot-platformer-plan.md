# Godot minimal platformer implementation plan

Build a small human controlled platformer first, then add sensing and learning through the same movement API. This document records the current implementation and the original movement and sensing design.

## Scope and conventions

- Use Godot 4 and GDScript in a **2D side view**. “Cubes” are axis aligned squares, with no rotation.
- One gameplay unit is the player's width and height. Start with a 32 × 32 pixel player, so one unit equals 32 pixels.
- There are only two gameplay pieces: Player and Block. Duplicate Blocks in Godot's existing scene editor to make floors, walls, ceilings, and platforms.
- Use a fixed 60 Hz physics tick. Express tuning in gameplay units, converting to pixels for Godot movement.
- Collision stops movement **into the contacted surface**: floors stop falling, ceilings stop rising, and walls stop horizontal travel. Motion along an unblocked axis remains possible, so touching a floor does not prevent walking or jumping.

## Phase one Human controlled base

### Current start menu

The game starts at `UI/MainMenu.tscn`. One setup form selects Human playable, Random agent, or Q-learning; Training or Evaluation; a training-data file; a run count; and optional headless execution. Human play hides the agent-only settings. Random uses evaluation without saved data. Q-learning can start fresh, continue a selected checkpoint, or evaluate it. The data dropdown scans `user://checkpoints/*.json` and includes the original single-save checkpoint if present. New training creates a timestamped file rather than replacing another experiment.

The compact in-game panel shows success, wins, deaths, and timeouts; the top bar shows completed/target runs and the current controller/mode. Learning details and save controls are collapsed under More. Counts survive episode resets, while changing mode starts a new batch and resets session counts. Manual resets do not count as completions. Agent batches stop at the selected count and leave the result visible. Random and Q-learning episodes time out after 20 simulated seconds; human play has no run or time limit.

Human mode reads A/D or arrow keys each physics tick and Space as a just-pressed jump, for immediate control independent of agent decision timing. Both agents use the shared six-tick interface. Episodes reset after a terminal outcome. Use the Menu button or Esc to return to mode selection and R to reset. V toggles sensor rays in any mode. Q-learning starts with its six input rays visible. Raw observation text is not shown by default.

### 1 Create the smallest scene structure

Create these scenes and scripts:

| File | Responsibility |
| --- | --- |
| `Game/Player.tscn` | `CharacterBody2D`, square visual, and matching `CollisionShape2D` with a rectangle shape |
| `Game/Player.gd` | Action submission, movement, collision response, and reset |
| `Game/Block.tscn` | `StaticBody2D`, square visual, and matching rectangle collision shape; no script needed |
| `Game/Level.tscn` | `Node2D` containing one Player, placed Block instances, and a spawn marker |
| `Game/Level.gd` | Read keyboard actions each physics tick and submit them before advancing the Player |

Use contrasting solid colors and a fixed view that fits the test level. Place Blocks on a 32 pixel grid; build larger structures by duplication. Keep the Player and physics shapes unscaled. Put Blocks on a World collision layer and the Player on a Player layer, with the Player detecting World.

Godot's [CharacterBody2D](https://docs.godotengine.org/en/stable/classes/class_characterbody2d.html) provides scripted character movement and surface detection. Use its grounded mode and `move_and_slide()` for solid collision handling.

### 2 Separate actions from movement

Expose two small methods on Player:

- `set_action(move_axis, jump_pressed)`: accept a finite horizontal value and a boolean jump request. Convert the horizontal value to −1, 0, or +1 by its sign so movement always uses the fixed speed. Reject invalid values. A jump request is consumed once and discarded if airborne; it is not queued until landing.
- `physics_step(delta)`: consume this tick's action, update velocity, and resolve movement exactly once. Clear the submitted action afterward, so a missing submission means neutral input.

Level's `_physics_process(delta)` reads input, calls `set_action`, then calls `physics_step`. Player must not also advance itself in its own physics callback. Keep keyboard polling out of Player's movement logic.

Map A or Left Arrow to −1, D or Right Arrow to +1, and Space to a just pressed jump request. Both horizontal directions together produce zero. Holding Space must not cause repeated jumps.

A future AI replaces the keyboard action producer and uses the same methods, timing, limits, and collision rules. No controller framework, AI dependency, or external communication layer is needed now.

#### Current agent action interface

External callers can use `Level.step(delta, action_id)` once per physics tick and receive the resulting observation and reward. Built-in agents use the same physics advance internally, constructing observations only at decisions and learning transitions. The shared interface accepts a new action only at six-tick decision boundaries and holds it for all six ticks, enforcing 10 decisions per second at 60 Hz. The six IDs are fixed:

| ID | Action |
| --- | --- |
| 0 | Do nothing |
| 1 | Move left |
| 2 | Move right |
| 3 | Jump |
| 4 | Move left + jump |
| 5 | Move right + jump |

`Level.Action` provides named constants for these IDs, and `Level.TICKS_PER_DECISION` fixes the interval at six physics ticks. Observations include `action_id` for the held action and `decision_required` to indicate whether the next `step` will accept a new decision. At other ticks, valid replacement IDs are ignored; keep calling `step` with the previous ID to advance physics. Invalid IDs are rejected without advancing the simulation. Jump actions request a jump on each held tick; airborne requests are discarded while horizontal steering still applies. Repeating a jump action after landing requests another jump. Reset clears the held action and immediately requests a new decision. Terminal observations have `decision_required = false`.

Both agents inherit `Agents/Agent.gd`, which defines the actions, six-tick timing, and three hooks: `choose_action`, `learn`, and `finish_episode`. `Agents/RandomAgent.gd` samples uniformly from the six actions and uses the default no-op learning hooks. Level handles physics, held actions, reward accumulation, and resets for both agents. It calls `learn` once at each decision boundary or early termination, passing the decision's starting observation, action, sum of physics-tick rewards, and resulting observation. It calls `finish_episode` once for a completed runtime episode. Reset occurs on the next physics tick; movement resumes on the following tick.

For external stepping, disable Level's automatic physics processing with `set_physics_process(false)`. Direct `step` calls provide environment transitions and preserve terminal observations until `reset_episode()`; external callers are responsible for invoking their agent's learning hooks.

### Q-learning baseline experiment

The aim is an understandable baseline for comparison with Snake, including its limitations, rather than a guarantee of solving the platformer. Keep the original baseline when comparing future observation or reward changes.

| File | What to read or edit |
| --- | --- |
| `Agents/Agent.gd` | Shared action IDs, timing, and agent hooks |
| `Agents/RandomAgent.gd` | Uniform random baseline |
| `Agents/QState.gd` | Convert observations to a small table key |
| `Agents/QLearningAgent.gd` | Action selection, Bellman update, and learning parameters |
| `Agents/QCheckpoint.gd` | Save/load, checkpoint format, and validation |
| `UI/AgentPanel.gd` | Training/evaluation display |
| `Game/Level.gd` | Environment rewards, 20-second limit, and common episode runner |

The Q-state key contains six binary ray flags in **left, right, up, down, down-left, down-right** order, orb horizontal and vertical direction, and grounded/rising/falling. A ray is 1 only if it hits a surface within one unit (32 pixels) beyond the player's edge, including exactly one unit. Orb alignment has a half-unit tolerance on each axis. Airborne zero vertical speed belongs to falling. This gives `2^6 × 3 × 3 × 3 = 1,728` possible keys, each with six action values initialized to zero. Only learned rows are stored. The encoder does not use exact position, speed magnitude, orb distance, or the two upward diagonal rays.

Defaults: learning rate 0.1, discount 0.95 **per decision**, exploration probability 1.0 decaying by 0.999 after each completed training episode to a floor of 0.05. This extended-exploration experiment reaches the floor after 2,995 episodes instead of 598 with the previous 0.995 multiplier. The time penalty remains enabled. Fresh agents use the new default; loaded checkpoints retain their saved exploration schedule. Exploration picks a uniform random action; otherwise the agent picks a maximum Q-value and breaks ties randomly. The update is `Q(s,a) += learning_rate * (reward_sum + discount * max(Q(next_state)) - Q(s,a))`. Terminal transitions omit the future-value term. Rewards within the six-frame action are summed without discounting; discounting happens between decisions.

Rewards are +1 for collecting the orb, -1 for death, and `0.1 × change in normalized orb proximity` on nonterminal ticks. Agent timeouts give -1 and are treated as terminal failures, counted separately from deaths. The first reward experiment adds a time cost of **0.001 per six-tick decision**, spread equally over nonterminal physics ticks (0.01 per simulated second). Terminal ticks retain exactly +1 or -1, replacing shaping and the time cost on that tick. There is no separate jump or idle penalty. Raw episode return is the sum of tick rewards. The original zero-time-cost baseline is preserved in `Experiments/2026-10-16-q-learning-baseline`; all other settings remain unchanged.

One compact panel at the upper left shows session outcomes and training speed. More reveals exploration, last reward, lifetime training runs, Evaluate / Train this data, and Save now. The top bar shows batch progress. The six input rays use the original thin lines and endpoint dots, without numeric labels: orange means a surface hit and green means no hit within the full two-unit ray range. The learner still uses the one-unit binary threshold; the longer visual rays show surrounding geometry rather than the encoded bits.

The **Speed** selector offers 1x, 2x, 4x, and 8x. It scales the engine clock and physics tick frequency together, preserving 60 physics steps and 10 decisions per simulated second. Episode timeouts use simulated time. Actual acceleration depends on hardware. Switching to evaluation automatically selects 1x; leaving the level restores normal engine timing. Speed is a viewing/training control and is not saved in the checkpoint.

Click **Evaluate** to restart the episode with learning and exploration disabled. The table and training exploration setting stay unchanged, including for unseen states; maximum-value ties are still random. Evaluation has a separate success counter, reset each time a new evaluation batch starts. **Train this data** preserves the table and continues exploration decay. R and mode switching abandon the partial episode without counting it as completed.

Visible menu-launched training saves to the selected checkpoint on batch completion, Menu / Esc, and before switching to evaluation. More → Save now also saves on demand. New training uses a timestamped file under `user://checkpoints`; continuing training updates the selected file. Evaluation never saves. Hover over the data dropdown or save status for the full path. Directly instantiated levels remain unlimited and manually saved unless configured by a caller, preserving test and benchmark behavior. The save contains all Q-values, learning rate, discount, exploration probability/decay/floor, update count, and completed training episodes/wins. It excludes the current partial episode, evaluation counters, session death/timeout counts, and random-generator state. A loaded run starts a fresh episode; resuming continues the saved exploration schedule and training totals, while evaluating starts with learning/exploration disabled and fresh evaluation statistics.

The menu disables Start evaluation until a data file is selected. Corrupt or incompatible files leave the menu open with an error. Loading validates every row and setting before changing an agent. Saves use a temporary file and replace the prior checkpoint only after the write succeeds. The versioned format checks ray order/threshold, orb alignment, motion categories, action mapping, and decision timing; bump the format version if the state encoding changes in other ways. Physics, level geometry, rewards, and the episode time limit come from the current project rather than the checkpoint, so keep those consistent when comparing saved policies.

For a video comparison, report completed training episodes, exploration, and success over a fixed number of evaluation episodes. Random and Q-learning use the same physics, action timing, rewards, and episode limit. A short run or one random seed is not evidence of convergence. Binary inputs alias distances and locations, omit vertical speed magnitude, and thin rays can miss gaps/geometry; these are deliberate candidates for later experiments.

### Headless batch training

Enable **Run headless** on the same setup form to launch the selected agent and mode in a background worker. The form locks while it runs. Training resumes the selected file or creates new data; evaluation leaves files untouched. Progress shows completed/target runs, runs per second, and success across this batch.

For Q-learning training, **Watch every** shows one evaluation run after each interval; **0** disables check-ins. The interval starts from this batch's count even when continuing older data. A shorter final segment finishes without an extra check-in. Each check-in loads the saved table at normal speed with learning/exploration disabled. A death, win, or timeout resumes training; **Stop check-in / Esc** ends the batch with the already-saved progress intact.

**Stop & save** finishes the current training episode and saves; evaluation uses **Stop** and writes no checkpoint. Closing the menu requests the same graceful stop. Normal completion unlocks the form and selects newly created data. Errors appear beneath the controls; hover over the result for the worker log. Training saves every 100 episodes and at completion.

`UI/HeadlessPanel.gd` launches the same `Training/train.gd` runner using Godot's executable directly. With check-ins enabled it runs chunks of at most the chosen interval: each worker saves and exits before `UI/MainMenu.gd` shows an evaluation, then the next worker loads that checkpoint. This reuses the existing runner and checkpoint code without a second training implementation. Like other checkpoint resumptions, it preserves learning settings and counters but starts a new random-number sequence. Check-ins add the time spent watching plus worker startup and checkpoint I/O; small intervals will therefore reduce throughput.

The runner writes a small atomic progress snapshot about every two seconds (plus start/finish/error); a menu timer reads it four times a second. Rendering the menu has some overhead, but it does not render or slow the simulation to real time. Actual performance depends on hardware; no exact GUI overhead benchmark is claimed. Progress and logs use unique files in the Godot user-data directory, and normal panel completion removes its temporary status/stop files. The worker log remains available for troubleshooting.

The terminal launcher also remains available. From the project folder, run:

```sh
./train.sh --episodes 10000
```

This starts a fresh Q-table and trains **10,000 additional episodes**. It replaces the legacy checkpoint, shown as Original saved data in the menu. To continue the saved table instead:

```sh
./train.sh --episodes 10000 --load 'user://q_learning_checkpoint.json'
```

To keep an experiment in a separate file, specify both paths when resuming it:

```sh
./train.sh --episodes 10000 --save /tmp/experiment.json --save-every 250
./train.sh --episodes 5000 --load /tmp/experiment.json --save 'user://q_learning_checkpoint.json'
```

The last command adds 5,000 episodes and saves into the game's default checkpoint, ready for evaluation. `--save` defaults to the game checkpoint even when `--load` names another file. The destination folder must already exist. Avoid saving from the game and batch runner to the same file at the same time.

The tiny progress display lives in the terminal: `1000 / 10000 runs`, runs per second, and success rate for this batch. It updates about once every two wall-clock seconds at episode boundaries, plus at the start/end. A checkpoint is written every 100 episodes by default (`--save-every`) and at completion. Ctrl+C stops the process; restart from its latest completed checkpoint (work since that save may be lost). Errors stop with a nonzero exit code and preserve the last valid checkpoint.

`Training/train.gd` creates the existing Level with `headless_training` enabled and listens for completed episodes. It reuses the same agent, rewards, resets, physics, and checkpoint code; only rendering, input handling, and HUD updates are skipped. `train.sh` launches Godot with `--headless --fixed-fps 60 --disable-render-loop`: real-time synchronization is removed while each physics step remains 1/60 of a game second and decisions remain six ticks apart. Training runs as fast as the machine can process those steps. No changes to Q-learning settings or the state representation are made to speed it up.

The shared agent loop constructs state snapshots only when choosing an action or learning from a completed decision/terminal transition. Intermediate ticks still move, collide, accumulate reward, and check episode endings. Reading `player.tick` no longer copies an entire observation. Each snapshot owns its action dictionary and ray arrays, so agents cannot mutate another observation or the player's cached sensing data.

`Agent.observation_rays` defaults to all eight probes; Q-learning selects its six input rays. Player disables automatic ray updates and samples requested rays on demand, caching each until the next movement/reset. Visible rays still refresh after every movement tick. The initial spawn sensing remains eager to preserve the original first observation. Public `get_state()` and `step()` still return all eight fresh ray readings; callers requesting a subset must only read those indices. This keeps one physics/learning path for visible and headless play.

`Training/benchmark_training.gd` runs the real worker with seed 12345, its usual checkpoint cadence, and additional episode/step counters. It writes timings and a behavior fingerprint next to its checkpoint (`.benchmark.json`). The fingerprint covers every episode's length, return and outcome, plus the full Q-table, exploration, RNG state and update count. Use a temporary save path; its default is a separate `user://q_learning_benchmark.json`, not the normal training save:

```sh
godot --headless --path . --fixed-fps 60 --disable-render-loop --script res://Training/benchmark_training.gd -- --episodes 1000 --save /tmp/platformer-benchmark.json
```

`Tests/check_training_trace.gd` separately hashes every physics step, chosen action, and learning transition across three seeds, and compares headless with visible runs. Pass a missing JSON path after `--` to write a reference from a pre-change project copy; run the same script in the changed project with that existing path to compare against it. Run with `--headless --fixed-fps 60 --disable-render-loop`. This is a correctness check, not a timing benchmark; tracing adds substantial overhead.

Measured on an Apple M1 Pro with Godot 4.7.1: three serial before/after pairs, alternating order, each training 1,000 fresh episodes with seed 12345. Both project copies used the same frozen level layout from the start of the change; concurrent editor changes were preserved in the working project. Check-ins were disabled, and normal saves every 100 episodes were included. Timings exclude process startup and final fingerprint generation.

| Median of three runs | Before | After |
| --- | ---: | ---: |
| Time for 1,000 episodes | 33.819 s | 23.135 s |
| Physics steps / second | 13,712 | 20,045 |
| Episodes / second | 29.57 | 43.22 |

That is **46.2% more physics steps per second**, or **31.6% less training time**. Individual times were 33.819 / 33.911 / 29.554 seconds before and 23.135 / 23.327 / 16.858 seconds after, so treat the speedup as a local measurement rather than a hardware-independent guarantee. All six runs performed exactly 463,743 physics steps and 77,793 learning updates, collected 502 orbs, and produced the same behavior fingerprint (including the full Q-table). The separate three-seed trace comparison also matched exactly before/after and between visible/headless runs. Existing physics, Q-learning, persistence, headless-menu and check-in checks passed; ray drawing was inspected grounded and airborne. Raw results, source fingerprints, and trace reference are in `Docs/training-benchmark.json`.

The launcher uses `godot` on PATH or the standard macOS app location. Set `GODOT_BIN` to use another executable. `./train.sh --help` lists the options and full default checkpoint path. Engine logs go to the system temporary directory.

`Tests/check_headless_menu.gd` exercises actual worker launch, continuation, stop/save, menu closure, error reporting, and evaluation from the menu using temporary checkpoints.

`Tests/check_training_checkins.gd` exercises real worker chunks and visible evaluation levels: exact intervals, partial final chunks, continued totals, normal-speed physics, frozen training data, automatic resume after death/orb/timeout, cancellation, and cleanup when the menu closes.

Validation: `Tests/check_headless_training.gd` compares seeded visible/headless training and, optionally, loads a supplied batch checkpoint through the game menu for evaluation. Run with Godot's `--headless --fixed-fps 60 --script res://Tests/check_headless_training.gd`, adding `-- /absolute/checkpoint.json` to test that checkpoint too.

### 3 Implement fixed speed movement

Expose these starting values in the Inspector. They are tuning proposals, not final feel requirements.

| Setting | Starting value | Intended response |
| --- | --- | --- |
| Horizontal speed | 6 units/s | Instant movement, stopping, and reversal |
| Jump speed | 12 units/s | Fixed upward velocity applied once at takeoff |
| Gravity | 40 units/s² | Smooth slowdown to apex and acceleration downward |
| Maximum fall speed | 14 units/s | Reach fall limit about 0.35 s after the apex |

Each physics tick:

1. Set horizontal velocity directly to `move_axis × horizontal_speed`. Neutral input stops immediately and changing direction reverses immediately. Use the same horizontal control in the air, with no acceleration or retained momentum.
2. Accept a jump only when grounded. Set vertical velocity to `−jump_speed` immediately, with no launch timer or upward acceleration.
3. On subsequent airborne ticks, apply gravity and cap downward speed. Gravity naturally slows ascent, crosses zero at the apex, and accelerates falling. In Godot 2D, negative Y is upward.
4. Call `move_and_slide()` with velocity in pixels per second; do not multiply velocity by delta again when passing it to this movement path. Stop velocity into each contacted surface. A ceiling hit stops upward movement. Never preserve hidden momentum into a blocker.

Keep jump height independent of how long Space is held. Start without double jumps, coyote time, jump buffering, bounce, or wall jumps. Add a reset action such as R: return to the spawn marker and clear velocity and pending actions. Refresh grounded contact through the next movement step before accepting another jump.

### 4 Verify phase one

Make one small test level with a floor, wall, low ceiling, raised platform, and a gap. Check:

- Running, stopping, reversing, and air control take effect immediately at the configured fixed speed.
- A jump starts at the configured upward velocity, slows at the apex, then falls at a capped speed. Releasing jump does not shorten it, and airborne jump requests do not restart or queue it.
- The Player lands without sinking, cannot pass through walls or ceilings, and falls after walking off an edge. Ceiling impact stops upward movement without repeated upward pushing.
- Walking and jumping still work while touching the floor; falling still works beside a wall. Test corners and seams between neighboring Blocks.
- Reset removes all motion and pending input. Different render frame rates preserve the same physics behavior.
- Leave one small runnable Godot check that submits a fixed action sequence directly to Player and checks speed caps, landing, and wall blocking. It should exercise the same path used by keyboard control, without synthesizing key presses.

**Phase one is complete when** the human can navigate this test level, Blocks can be placed directly in Godot, and scripted action submission works without changing movement code. Stop here until phase two is requested.

## Phase two Ray sensing and state reporting

### Add eight directional probes

Add eight `RayCast2D` probes in a fixed clockwise order: up, up right, right, down right, down, down left, left, up left. Normalize diagonal directions so every ray uses the same distance scale.

Define range as **two units beyond the player's boundary**. For direction `d`, the distance from the square's center to its edge is `0.5 / max(abs(d.x), abs(d.y))` units. Cast from the center through that edge and another two units. Exclude the Player and detect only World geometry. Keep range configurable at two units or more.

For each ray, report a hit flag and clearance from the player's boundary in units, clamped to 0 through range. No hit means `hit = false` and clearance equal to range. A separate hit flag distinguishes no hit from a hit exactly at maximum range. Contact should report approximately zero clearance, allowing for the physics collision margin.

Sample requested probes after movement, before reading them, so observations describe the completed tick. Reuse each reading until the next movement/reset; the default observation requests all eight probes. Godot documents the per physics frame update behavior and explicit refresh method in [RayCast2D](https://docs.godotengine.org/en/stable/classes/class_raycast2d.html).

### Expose one stable observation

Add `get_state()` returning a fixed schema:

- Physics tick index and the action applied on that tick.
- Position relative to the level origin in units, and velocity in units/s.
- Grounded, wall contact, ceiling contact, and whether jumping is currently allowed.
- Eight ray hit flags and eight clearances in the documented order.

Keep debug drawing optional and separate from observations. If a future model needs normalized distances, divide clearance by ray range; document normalization rather than silently changing units. Reset must clear observation history and refresh sensing before returning a new initial observation.

Verify probes with Blocks at known cardinal and diagonal distances, including contact and no hit. Check that state reflects the latest movement tick. Replay a fixed action sequence from the same reset state and compare results within a small tolerance on the same engine setup; do not assume cross platform bit exact physics.

Eight thin rays are a deliberately limited observation: they can miss geometry between directions and do not represent the Player's full swept body. Physics collisions remain authoritative. Expand sensing only if training shows this limitation matters.

## Deferred work

The custom level editor, level serialization, training algorithms, rewards, goals, episode rules, parallel environments, and external AI bridge are outside these two implementation phases. Reusable Block instances and the shared action entry point provide the starting points for that later work.

The worker also accepts `--mode evaluation --load PATH` for Q-learning evaluation, or `--agent random --mode evaluation`. These modes honor `--episodes` but never write a checkpoint. `Tests/check_run_setup.gd` covers dropdown discovery, human/random settings, visible batch limits, save isolation, and evaluation preservation.
