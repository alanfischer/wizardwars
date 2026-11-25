#!/usr/bin/env bash
# Play a listen-host match in this terminal. Ctrl-C quits.
#
#   tools/ascii_view/play.sh                                     # ww_2fort, 4 bots, blue fire
#   tools/ascii_view/play.sh --map ww_chasm --bots 6 --team 2 --class ice
#
#   w/s      run forward/back (latched: press again to stop)    a/d   strafe
#   arrows   look (tap nudges, hold turns)                       space jump   c crouch
#   f        fire   g alt fire   x satchel   e use   1-9 spells   q last spell   r next spell
#
# A small borderless game window sits in the bottom-right corner. It never takes focus; the
# game needs a real window for its captured-mouse controls. It hosts, so UDP 9050 and TCP 8080
# must be free.
set -uo pipefail

[ -t 0 ] || { echo "play.sh needs a terminal" >&2; exit 1; }

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
[ -x "$GODOT" ] || GODOT="$HOME/Applications/Godot.app/Contents/MacOS/Godot"

args=("$@")
[ ${#args[@]} -gt 0 ] || args=(--map ww_2fort --bots 4 --team 1 --class fire)

# Fill the terminal, within what the ray budget can draw at a playable rate.
term_cols=$(tput cols)
term_rows=$(tput lines)
cols="${ASCII_COLS:-$(( term_cols < 140 ? term_cols : 140 ))}"
rows="${ASCII_ROWS:-$(( term_rows - 2 < 45 ? term_rows - 2 : 45 ))}"

# The OS key repeat decides how long a key counts as held (both in 15 ms ticks).
initial=$(defaults read -g InitialKeyRepeat 2>/dev/null || echo 25)
repeat=$(defaults read -g KeyRepeat 2>/dev/null || echo 6)

dir="$(mktemp -d -t ascii_play)"
frame="$dir/frame"
keys="$dir/keys"
log="$dir/game.log"
: >"$keys"

saved_tty="$(stty -g)"
game=""
reader=""
cleanup() {
	{
		[ -n "$reader" ] && kill "$reader" && wait "$reader"
		[ -n "$game" ] && kill "$game" && wait "$game"
	} 2>/dev/null
	stty "$saved_tty"
	printf '\033[0m\033[?25h\033[2J\033[H'
	echo "game log: $log"
}
trap cleanup EXIT

ASCII_OUT="$frame" ASCII_KEYS="$keys" ASCII_COLOR="${ASCII_COLOR:-1}" ASCII_START=0 \
	ASCII_EVERY="${ASCII_EVERY:-0.066}" ASCII_COLS="$cols" ASCII_ROWS="$rows" \
	ASCII_REPEAT_DELAY="$(echo "$initial * 0.015" | bc)" \
	ASCII_REPEAT_INTERVAL="$(echo "$repeat * 0.015" | bc)" \
	"$GODOT" --path "$PROJECT_DIR" res://tools/ascii_view/ascii_view.tscn -- \
	--host "${args[@]}" >"$log" 2>&1 </dev/null &
game=$!

# Launching an app can still bring it to the front; hand focus straight back.
if [ -n "${__CFBundleIdentifier:-}" ]; then
	(for t in 0.5 1 1.5 3; do
		sleep "$t"
		osascript -e "tell application id \"$__CFBundleIdentifier\" to activate" >/dev/null 2>&1
	done) &
fi

stty -icanon -echo -isig -ixon min 1 time 0
printf '\033[2J\033[?25l'
cat -u </dev/tty >>"$keys" &
reader=$!

while kill -0 "$game" 2>/dev/null; do
	printf '\033[H'
	if [ -s "$frame" ]; then
		cat "$frame" 2>/dev/null
	else
		echo "Starting Wizard Wars..."
	fi
	sleep 0.03
done
