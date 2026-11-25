#!/usr/bin/env bash
# Watch a headless bot match as live ASCII in this terminal. Ctrl-C to stop.
#
#   tools/ascii_view/watch.sh                          # ww_2fort, 8 bots
#   tools/ascii_view/watch.sh --map ww_chasm --bots 4  # game flags replace the defaults
#   ASCII_FOLLOW=Bot_3 ASCII_COLS=160 ASCII_ROWS=50 tools/ascii_view/watch.sh
#
# The game runs as a dedicated server, so it needs UDP 9050 and TCP 8080 free.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
[ -x "$GODOT" ] || GODOT="$HOME/Applications/Godot.app/Contents/MacOS/Godot"

args=("$@")
[ ${#args[@]} -gt 0 ] || args=(--map ww_2fort --bots 8)

frame="$(mktemp -t ascii_view)"
log="$(mktemp -t ascii_view_log)"
ASCII_OUT="$frame" ASCII_COLOR="${ASCII_COLOR:-1}" \
	"$GODOT" --headless --path "$PROJECT_DIR" res://tools/ascii_view/ascii_view.tscn -- \
	--server "${args[@]}" >"$log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; rm -f "$frame" "$frame.tmp"; printf "\033[?25h\n"; echo "game log: $log"' EXIT
printf '\033[2J\033[?25l'
while kill -0 "$pid" 2>/dev/null; do
	if [ -s "$frame" ]; then
		printf '\033[H'
		cat "$frame" 2>/dev/null
	fi
	sleep 0.1
done
wait "$pid"
