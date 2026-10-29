#!/usr/bin/env bash
# Generate bot-navigation waypoint graphs for maps that ship no hand-authored .HPB_wpt file.
#
# For each such map this runs the engine headless in --bake-waypoints mode (see
# src/bot/waypoint_bake.gd): it loads the map, samples a walkable node/edge graph from the
# collision world with WaypointBaker, and writes maps/waypoints/<map>.gen_wpt. Bots then get
# real A* pathing on those maps instead of the reactive whisker fallback that traps them.
#
# One map per engine process — map load/unload is only clean per-process. Override the engine
# with GODOT=/path/to/Godot.
#
# Usage:
#   ./tools/bake_waypoints.sh                 # bake every map missing a waypoint file
#   ./tools/bake_waypoints.sh ww_castle ...   # bake only the named maps (force re-bake)
#   FORCE=1 ./tools/bake_waypoints.sh         # re-bake all, even maps that already have a file
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# Resolve the Godot binary the same way run.sh / run_tests.sh do.
GODOT="${GODOT:-}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
    for candidate in \
        "/Applications/Godot.app/Contents/MacOS/Godot" \
        "$HOME/Applications/Godot.app/Contents/MacOS/Godot"; do
        if [ -x "$candidate" ]; then GODOT="$candidate"; break; fi
    done
fi
if [ ! -x "${GODOT:-}" ]; then
    echo "Godot binary not found. Set GODOT=/path/to/Godot" >&2
    exit 127
fi

FORCE="${FORCE:-0}"

# Build the map list: explicit args, else every maps/*.bsp / *.glb that has no .gen_wpt yet
# (FORCE re-bakes everything).
#
# This used to skip any map carrying a hand-authored .HPB_wpt, back when the hand file won at
# load time. It does not any more — WaypointGraph tries load_generated FIRST and falls back to
# the hand file — and the skip was never updated to match, so ten maps that ship an .HPB_wpt
# were silently never baked. They ran on 5-10m hand routes while everything else had a 1m grid;
# baking ww_keep took monsters crossing it from 0/10 to 6/10.
maps=()
if [ "$#" -gt 0 ]; then
    maps=("$@")
else
    for src in maps/*.bsp maps/*.glb; do
        [ -e "$src" ] || continue
        name="$(basename "$src")"; name="${name%.*}"
        if [ "$FORCE" != 1 ] && [ -f "maps/waypoints/${name}.gen_wpt" ]; then
            continue   # already baked
        fi
        maps+=("$name")
    done
fi

if [ "${#maps[@]}" -eq 0 ]; then
    echo "No maps to bake (all have hand-authored waypoints; use FORCE=1 to override)."
    exit 0
fi

echo "Baking waypoints for ${#maps[@]} map(s): ${maps[*]}"
echo "  godot: $GODOT"
echo ""

fail=0
for name in "${maps[@]}"; do
    echo "===== $name ====="
    if "$GODOT" --path "$PROJECT_DIR" --headless -- --bake-waypoints --map "$name" 2>&1 \
            | grep -iE "\[Bake\]|\[Waypoints\]|error|warning" ; then :; fi
    if [ -f "maps/waypoints/${name}.gen_wpt" ]; then
        echo "  -> maps/waypoints/${name}.gen_wpt ($(wc -c < "maps/waypoints/${name}.gen_wpt") bytes)"
    else
        echo "  !! no output produced for $name" >&2
        fail=1
    fi
    echo ""
done

exit "$fail"
