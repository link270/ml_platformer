#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
godot_bin=${GODOT_BIN:-godot}
if ! command -v "$godot_bin" >/dev/null 2>&1; then
    godot_bin=/Applications/Godot.app/Contents/MacOS/Godot
fi
exec "$godot_bin" --headless --path "$project_dir" --fixed-fps 60 \
    --disable-render-loop --log-file "${TMPDIR:-/tmp}/ml-platformer-training-$$.log" --script res://Training/train.gd -- "$@"
