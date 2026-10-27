# Episode recording and live paths

In setup, **Record every** is `0` by default. `1` records all episodes; `X` records episodes X, 2X, 3X relative to this session, including when continuing an existing policy. Both training and evaluation can be recorded. **Folder** opens `user://recordings/`; each session gets a unique `.mlpaths` file separate from policy checkpoints. Use **Playback recordings** to view these files.

**Show live path trails** is enabled by default in visible agent sessions and works with recording off. The current path is bright cyan. The previous 50 complete paths are muted and fade by episode age. Endpoint colors indicate success (green), death (red), or timeout (amber). Straight trail segments are simplified for drawing; disk recordings retain every physics tick. Headless training skips trail allocation and drawing. Historical trails are not retained after leaving the level or switching between training and evaluation.

Sampling spans headless training chunks: for example, recording every 3 episodes and watching every 2 records episode 3 in the second worker, rather than restarting the sampling interval. Each worker chunk creates a separate file. Evaluation check-ins are excluded from that training recording. A chunk with no sampled episodes contains only its header.

Only completed episodes are written. Manual restarts, switching modes, and leaving midway through an episode discard the partial recording. Completed episodes flush at their boundaries. A recording write error stops the session and is reported in the HUD or headless status. Existing destinations are refused, never appended to or overwritten. For visible mode switches, recording ordinals continue increasing within the file and each episode identifies whether it was training or evaluation.

## Playback

Choose **Playback recordings** from setup, then **Open recordings…**. Select one or more `.mlpaths` files; multi-selection lets you include all chunks from a headless session. The picker starts in the recording folder. Files play in creation order, with episode offsets ordering chunks created in the same second.

- **Sequential** plays one recorded episode at a time, keeping its completed path as the next ghost starts.
- **Simultaneous groups** starts up to the selected **Bots** count together (default 20, maximum 100). Each ghost disappears at its own recorded endpoint. Its path and outcome marker persist while the remaining ghosts continue. The next group starts when the longest episode finishes; the final group can contain fewer bots.
- **Show every** further samples the saved episodes: `1` shows all, `X` shows saved entries X, 2X, 3X across the chosen files. For example, if a recording contains original episodes 10, 20, 30, 40, setting this to `2` plays original episodes 20 and 40. Ghost labels retain original episode numbers.
- **Speed** ranges from 0.25× to 8×. **Pause** / Space freezes recorded time. **Restart** / R rewinds the selected playlist and clears its trails. Changing mode, interval, or group size also restarts. **Menu** / Esc returns to setup.
- **Show persistent paths** toggles paths without hiding ghosts. Active ghosts have colored paths; one shared history retains the last 50 completed paths with the same fading and outcome colors as live training.

Ghosts interpolate recorded positions using each file's physics tick rate. Playback never instantiates physics bodies, agent policies, sensors, or learning updates into the running scene, and never writes to recordings or checkpoints. File indexing retains episode metadata and byte offsets; only the active group's position arrays are decoded, then released as its ghosts finish. Trail geometry is simplified separately from the recorded samples.

The course is drawn from the current level's visuals. If its saved fingerprint differs, the viewer warns that paths may no longer align with the current course. Complete episodes preceding an interrupted final write remain playable with a warning. Invalid formats, lengths, metadata, or non-finite samples produce a visible error rather than rendering invalid data. Older version 1 recordings are supported unchanged.

## Heat map

Enable **Show heat map** in the live level's HUD or the playback viewer. The overlay defaults off but keeps collecting while hidden, so enabling it includes the session's earlier attempts. It works independently of path trails and disk recording. Headless training does not allocate or update a heat map.

The grid measures **the percentage of episodes visiting each 16-pixel cell**, using the character's center at each physics sample. Each episode counts at most once per cell: standing still, repeated jumps in one place, and revisiting a cell add no extra heat. Blue/cyan marks less common areas, yellow/red more common areas. The legend always spans 0–100%, and unvisited cells remain transparent. Active attempts contribute the path visited so far; the denominator is completed episodes plus active episodes, shown below the legend.

Live heat covers all observed episodes in the current level, regardless of the recording interval. Restarting an unfinished attempt removes that attempt's cells while preserving completed heat. Switching training/evaluation or starting a new level clears the population. The aggregate does not fade or stop at the trail history's 50-episode limit.

Playback heat covers only the selected episodes, as they play; it does not preview future paths. **Show every** therefore limits which episodes contribute. All recorded physics samples are consumed even at high playback speed. Sequential and simultaneous playback produce the same completed grid for the same selection. Pause adds no heat; restart, changing mode, changing group size, changing the interval, or loading files clears it before playback begins again.

Storage is one count per visited on-screen cell plus one small visited-cell set per active episode. Completed episode paths are not retained by the heat map, and offscreen positions do not grow its grid. Heat data is derived from the existing position samples, so the recording file format and disk usage are unchanged.

## Command line

```sh
godot --headless --path . --fixed-fps 60 --disable-render-loop \
  --script res://Training/train.gd -- --episodes 10000 --record-every 10
```

Optional `--record-to PATH.mlpaths` selects a new file. `--record-offset N` is used by chunked workers so sampling follows the overall session ordinal. Off (`--record-every 0`) creates no recording file or sample buffer. These options do not affect agent random numbers or learning.

## Version 1 binary format

All integer and float fields are little-endian. No compression is used. JSON lengths are UTF-8 byte counts.

The stream starts with 8 ASCII bytes `MLPATH01`, then a uint32 header length and that many JSON bytes. The header identifies the format, physics tick rate, decision interval, coordinate units, experiment preset, engine version, source fingerprints, checkpoint path, sampling interval, and session offset.

Each complete episode follows with:

| Field | Representation |
| --- | --- |
| Metadata length | uint32 |
| Sample count | uint32 |
| Metadata | UTF-8 JSON: episode ordinal, training/evaluation flag, outcome, tick count, return; Q-learning also stores completed training count before the episode, starting epsilon, and starting RNG state as a decimal string |
| Samples | Sample count × 13 bytes |

Each sample is float32 X, float32 Y, float32 tick reward, then one flags byte. Coordinates are level-local pixels. Flags bits 0–2 hold action IDs from `Agents/Agent.gd`; bit 3 marks a randomly exploratory action. The initial spawn sample has reward/action/flags zero; remaining samples occur after each physics step, including the terminal step. Sample time is its zero-based index divided by the recorded physics tick rate. Rewards use float32 in samples; episode return is retained in JSON.

This preserves paths without requiring physics resimulation. It is not a snapshot of the changing Q-table at each decision. Checkpoints remain the way to save learned policies. `Training/EpisodeRecording.gd` checks the magic/version, validates lengths against the remaining file, and ignores an incomplete final record after an unexpected interruption.

## Repeatable performance benchmark

```sh
python Training/benchmark_recording.py --godot /path/to/godot --episodes 1000 --repeats 3
```

The harness runs the actual training worker with seed 12345, a warmup, and three rotating-order repetitions of recording off, every episode, and every tenth episode. Usual checkpoint saves remain enabled. It checks identical behavior fingerprints, selected episode counts, and actual file sizes. Temporary recordings and checkpoints are cleaned up afterward; results are written to `Docs/recording-benchmark.json`.

Timings include recording initialization, training, disk writes, flushes and close, but exclude process startup and final fingerprint generation. This measures recording overhead during headless training; it does not measure GPU cost for visible trails. See the saved JSON for environment, individual measurements, medians, and source fingerprints.

Measured on Windows with Godot 4.7.2, 1,000 fresh episodes per run and three repetitions:

| Recording interval | Recorded episodes | File size (decimal MB) | Median training time | Median episodes/second |
| --- | ---: | ---: | ---: | ---: |
| Off | 0 | 0 | 26.231 s | 38.12 |
| Every episode | 1,000 | 11.640 | 25.410 s | 39.35 |
| Every tenth | 100 | 1.150 | 26.140 s | 38.26 |

All nine runs have identical behavior fingerprints, physics step counts, learned tables, learning counters, and final random-number state. The observed recording timings are slightly faster than off; this does **not** establish a speed improvement. Individual timings range from 21.856 to 26.659 seconds, so a small recording cost is unresolved within the variation of this benchmark. No slowdown was measurable here. These timings include normal checkpoint saving, which all treatments perform equally.

At this episode mix, recording all 10,000 episodes would scale to about 116 MB; later training may have a different episode duration. At the current 20-second cap, each full-length path needs 15,613 bytes of samples, plus episode metadata (roughly 159 MB for 10,000 such episodes). Sample buffers hold only one selected episode; visible path history stays bounded independently of the disk recording.
