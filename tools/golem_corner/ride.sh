#!/usr/bin/env bash
# The corner repro, as one command: a rider in ww_golem's back-right corner holding back
# and strafing into the side wall while the golem turns left. Prints GOOD or BAD.
#
#   tools/golem_corner/ride.sh [extra probe env, e.g. Y=-70]
#
# Everything it writes goes to $OUT (default /tmp/golem_corner).
set -u
WW="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${OUT:-/tmp/golem_corner}"; mkdir -p "$OUT"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
[ -x "$GODOT" ] || { echo "set GODOT=/path/to/Godot" >&2; exit 2; }
log="$OUT/ride_$(git -C "$WW/extern/hop-godot" rev-parse --short HEAD).txt"
env X=-14 Y=-77 BACK=1 STRAFE=-1 TURN=1 FOLLOW=1 TICKS=300 "$@" \
    "$GODOT" --headless --path "$WW" res://tools/probe_golem_real.tscn > "$log" 2>&1
"$WW/tools/golem_corner/verdict.sh" "$log"
