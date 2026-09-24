# Godot minimal platformer implementation plan

Build a small human controlled platformer first, with a movement API that a future machine learning agent can call directly. Add ray sensing and state reporting in a separate second phase. This document is a plan only; it does not implement the game, editor, or AI.

## Scope and conventions

- Use Godot 4 and GDScript in a **2D side view**. “Cubes” are axis aligned squares, with no rotation.
- One gameplay unit is the player's width and height. Start with a 32 × 32 pixel player, so one unit equals 32 pixels.
- There are only two gameplay pieces: Player and Block. Duplicate Blocks in Godot's existing scene editor to make floors, walls, ceilings, and platforms.
- Use a fixed 60 Hz physics tick. Express tuning in gameplay units, converting to pixels for Godot movement.
- Collision stops movement **into the contacted surface**: floors stop falling, ceilings stop rising, and walls stop horizontal travel. Motion along an unblocked axis remains possible, so touching a floor does not prevent walking or jumping.

## Phase one Human controlled base

### 1 Create the smallest scene structure

Create these scenes and scripts:

| File | Responsibility |
| --- | --- |
| `Player.tscn` | `CharacterBody2D`, square visual, and matching `CollisionShape2D` with a rectangle shape |
| `Player.gd` | Action submission, movement, collision response, and reset |
| `Block.tscn` | `StaticBody2D`, square visual, and matching rectangle collision shape; no script needed |
| `Level.tscn` | `Node2D` containing one Player, placed Block instances, and a spawn marker |
| `Level.gd` | Read keyboard actions each physics tick and submit them before advancing the Player |

Use contrasting solid colors and a fixed view that fits the test level. Place Blocks on a 32 pixel grid; build larger structures by duplication. Keep the Player and physics shapes unscaled. Put Blocks on a World collision layer and the Player on a Player layer, with the Player detecting World.

Godot's [CharacterBody2D](https://docs.godotengine.org/en/stable/classes/class_characterbody2d.html) provides scripted character movement and surface detection. Use its grounded mode and `move_and_slide()` for solid collision handling.

### 2 Separate actions from movement

Expose two small methods on Player:

- `set_action(move_axis, jump_pressed)`: accept a finite horizontal value clamped to −1 through +1 and a boolean jump request. Reject invalid values. A jump request is consumed once and discarded if airborne; it is not queued until landing.
- `physics_step(delta)`: consume this tick's action, update velocity, and resolve movement exactly once. Clear the submitted action afterward, so a missing submission means neutral input.

Level's `_physics_process(delta)` reads input, calls `set_action`, then calls `physics_step`. Player must not also advance itself in its own physics callback. Keep keyboard polling out of Player's movement logic.

Map A or Left Arrow to −1, D or Right Arrow to +1, and Space to a just pressed jump request. Both horizontal directions together produce zero. Holding Space must not cause repeated jumps.

A future AI replaces the keyboard action producer and uses the same methods, timing, limits, and collision rules. No controller framework, AI dependency, or external communication layer is needed now.

### 3 Implement quick smooth motion

Expose these starting values in the Inspector. They are tuning proposals, not final feel requirements.

| Setting | Starting value | Intended response |
| --- | --- | --- |
| Maximum horizontal speed | 6 units/s | Clear speed limit |
| Horizontal acceleration | 60 units/s² | Full speed from rest in 0.10 s |
| Braking and reversal acceleration | 90 units/s² | Stop in about 0.07 s; full reversal in about 0.13 s |
| Maximum upward launch speed | 12 units/s | Quick jump takeoff |
| Upward launch acceleration | 240 units/s² | Reach launch speed in about 0.05 s |
| Gravity | 40 units/s² | Smooth slowdown to apex and acceleration downward |
| Maximum fall speed | 14 units/s | Reach fall limit about 0.35 s after the apex |

Each physics tick:

1. Move horizontal velocity toward `move_axis × maximum_speed`, using acceleration × delta. Use the stronger braking value when releasing or reversing direction. Use the same horizontal control in the air.
2. Accept a jump only when grounded. Begin a short launch: ramp upward speed from zero to its limit over approximately three ticks, then end launch. Apply gravity after launch, not during it. This deliberately provides the requested quick upward ramp rather than an instantaneous jump impulse.
3. Outside launch, apply gravity while airborne and cap downward speed. Gravity naturally slows ascent, crosses zero at the apex, and accelerates falling. In Godot 2D, negative Y is upward.
4. Call `move_and_slide()` with velocity in pixels per second; do not multiply velocity by delta again when passing it to this movement path. Stop velocity into each contacted surface. A ceiling hit cancels launch immediately; landing clears launch state. Never preserve hidden momentum into a blocker.

Keep launch independent of how long Space is held. Start without double jumps, coyote time, jump buffering, bounce, or wall jumps. Add a reset action such as R: return to the spawn marker and clear velocity, pending actions, and launch state. Refresh grounded contact through the next movement step before accepting another jump.

### 4 Verify phase one

Make one small test level with a floor, wall, low ceiling, raised platform, and a gap. Check:

- Running, braking, reversing, and air control approach the configured limits without exceeding them.
- A jump ramps up quickly, slows at the apex, then falls at a capped speed. Holding jump does not repeat it.
- The Player lands without sinking, cannot pass through walls or ceilings, and falls after walking off an edge. Ceiling impact cancels launch without repeated upward pushing.
- Walking and jumping still work while touching the floor; falling still works beside a wall. Test corners and seams between neighboring Blocks.
- Reset removes all motion and pending input. Different render frame rates preserve the same physics behavior.
- Leave one small runnable Godot check that submits a fixed action sequence directly to Player and checks speed caps, landing, and wall blocking. It should exercise the same path used by keyboard control, without synthesizing key presses.

**Phase one is complete when** the human can navigate this test level, Blocks can be placed directly in Godot, and scripted action submission works without changing movement code. Stop here until phase two is requested.

## Phase two Ray sensing and state reporting

### Add eight directional probes

Add eight `RayCast2D` probes in a fixed clockwise order: up, up right, right, down right, down, down left, left, up left. Normalize diagonal directions so every ray uses the same distance scale.

Define range as **two units beyond the player's boundary**. For direction `d`, the distance from the square's center to its edge is `0.5 / max(abs(d.x), abs(d.y))` units. Cast from the center through that edge and another two units. Exclude the Player and detect only World geometry. Keep range configurable at two units or more.

For each ray, report a hit flag and clearance from the player's boundary in units, clamped to 0 through range. No hit means `hit = false` and clearance equal to range. A separate hit flag distinguishes no hit from a hit exactly at maximum range. Contact should report approximately zero clearance, allowing for the physics collision margin.

Sample after movement and refresh all probes before reading them so observations describe the completed tick. Godot documents the per physics frame update behavior and explicit refresh method in [RayCast2D](https://docs.godotengine.org/en/stable/classes/class_raycast2d.html).

### Expose one stable observation

Add `get_state()` returning a fixed schema:

- Physics tick index and the action applied on that tick.
- Position relative to the level origin in units, and velocity in units/s.
- Grounded, wall contact, ceiling contact, and whether jumping is currently allowed.
- Launch active and remaining launch time, because this affects the next movement step.
- Eight ray hit flags and eight clearances in the documented order.

Keep debug drawing optional and separate from observations. If a future model needs normalized distances, divide clearance by ray range; document normalization rather than silently changing units. Reset must clear observation history and refresh sensing before returning a new initial observation.

Verify probes with Blocks at known cardinal and diagonal distances, including contact and no hit. Check that state reflects the latest movement tick. Replay a fixed action sequence from the same reset state and compare results within a small tolerance on the same engine setup; do not assume cross platform bit exact physics.

Eight thin rays are a deliberately limited observation: they can miss geometry between directions and do not represent the Player's full swept body. Physics collisions remain authoritative. Expand sensing only if training shows this limitation matters.

## Deferred work

The custom level editor, level serialization, training algorithms, rewards, goals, episode rules, parallel environments, and external AI bridge are outside these two implementation phases. Reusable Block instances and the shared action entry point provide the starting points for that later work.
