# Episode recording and live paths

In setup, **Record every** is `0` by default. `1` records all episodes; `X` records episodes X, 2X, 3X relative to this session, including when continuing an existing policy. Both training and evaluation can be recorded. **Folder** opens `user://recordings/`; each session gets a unique `.mlpaths` file separate from policy checkpoints. Recordings currently supply data for future playback; no replay viewer is included yet.

**Show live path trails** is enabled by default in visible agent sessions and works with recording off. The current path is bright cyan. The previous 50 complete paths are muted and fade by episode age. Endpoint colors indicate success (green), death (red), or timeout (amber). Straight trail segments are simplified for drawing; disk recordings retain every physics tick. Headless training skips trail allocation and drawing. Historical trails are not retained after leaving the level or switching between training and evaluation.

Sampling spans headless training chunks: for example, recording every 3 episodes and watching every 2 records episode 3 in the second worker, rather than restarting the sampling interval. Each worker chunk creates a separate file. Evaluation check-ins are excluded from that training recording. A chunk with no sampled episodes contains only its header.

Only completed episodes are written. Manual restarts, switching modes, and leaving midway through an episode discard the partial recording. Completed episodes flush at their boundaries. A recording write error stops the session and is reported in the HUD or headless status. Existing destinations are refused, never appended to or overwritten. For visible mode switches, recording ordinals continue increasing within the file and each episode identifies whether it was training or evaluation.

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

This preserves paths without requiring physics resimulation. It is not a snapshot of the changing Q-table at each decision. Checkpoints remain the way to save learned policies. A future reader must check the magic/version, validate lengths against the remaining file, and ignore an incomplete final record after an unexpected interruption.

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
