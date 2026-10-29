#!/bin/bash
# Launch a dedicated server + N clients for quick network testing.
# Usage: ./test_network.sh [map_name] [latency] [loss] [spike] [clients]
#   map_name  defaults to ww_2fort
#   latency   simulated per-leg send latency in ms; "12,30" for variable (optional)
#   loss      simulated packet loss percentage, e.g. "2" for 2% (optional)
#   spike     WiFi spike params: "ms,interval_s,duration_s" (optional)
#             e.g. "150,10,0.2" = 150ms spike every ~10s lasting 200ms (~12 cmds)
#   clients   number of client windows to open (default 2, max 8)
#             clients 3+ are background bots (640x480, offscreen at -10000)
#
# The sim lives in goldnet now, not in main.gd, so these reach each client as
# GOLDNET_LATENCY / GOLDNET_LOSS / GOLDNET_SPIKE env vars (the same knobs the
# /sim_latency, /sim_loss and /sim_spike chat commands write at runtime). They
# apply to that endpoint's SEND leg; set them on the server too if you want the
# downstream shaped as well. GOLDNET_SIM_SEED=<n> makes a run reproducible.
#
# The old 6th argument, DTIM packet reorder, is gone: goldnet has no reorder knob
# (the seq-number ordering guard it was written to exercise is now unconditional).
#
# SCENARIO PRESETS (matching known real-world conditions):
#
#   Normal LAN (Gus, baseline):
#     ./test_network.sh ww_2fort 12,30
#
#   LAN with WiFi spikes (reproduces the "never jumps high enough" bug):
#     ./test_network.sh ww_2fort 12,30 0 150,10,0.2
#     Explanation: mostly 12-30ms ping but every ~10s a 150ms spike lasting 200ms.
#     At 60Hz this queues ~12 commands. Before the time-budget fix this caused
#     4 move_and_slide calls/frame → corrections every frame → camera stutter.
#
#   Cross-state internet, OK conditions (~3 states, 8 players):
#     ./test_network.sh ww_2fort 50,90 1 "" 8
#     Explanation: 50-90ms RTT (Chicago→Denver→Seattle range), 1% loss.
#     Representative of home broadband on a mid-tier ISP with light congestion.
#
#   High latency + loss (poor internet / overseas):
#     ./test_network.sh ww_2fort 80,150 3
#
#   Stress test (barely playable):
#     ./test_network.sh ww_2fort 150,250 5 200,5,0.3

pkill -9 "Wizard Wars"
pkill -9 "WizardWars"
pkill -9 "Godot"

MAP="${1:-ww_2fort}"
LATENCY="${2:-}"
LOSS="${3:-}"
SPIKE="${4:-}"
NUM_CLIENTS="${5:-2}"
MAP="${MAP%.bsp}"  # strip .bsp extension if provided
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

# Two visible clients side by side; extras are small and offscreen (load only)
VISIBLE_W=1280
VISIBLE_H=960
BOT_W=320
BOT_H=240

echo "Starting server (map: $MAP)..."
"$GODOT" --path "$PROJECT_DIR" --headless -- --server --map "$MAP" &
SERVER_PID=$!

# Wait for server to start listening (and BSP conversion if needed)
sleep 3

# goldnet reads its sim config from the environment at construction, so these are exported
# into each client process rather than passed as flags.
NET_ENV=()
if [ -n "$LATENCY" ]; then
    NET_ENV+=("GOLDNET_LATENCY=$LATENCY")
    echo "Simulated send latency: ${LATENCY}ms (per leg)"
fi
if [ -n "$LOSS" ]; then
    NET_ENV+=("GOLDNET_LOSS=$LOSS")
    echo "Simulated packet loss: ${LOSS}%"
fi
if [ -n "$SPIKE" ]; then
    NET_ENV+=("GOLDNET_SPIKE=$SPIKE")
    echo "Simulated WiFi spikes: ${SPIKE} (ms,interval_s,duration_s)"
fi

CLASSES=(fire ice earth wind lightning)
CLIENT_PIDS=()

for i in $(seq 1 "$NUM_CLIENTS"); do
    CLASS="${CLASSES[$(( (i-1) % ${#CLASSES[@]} ))]}"

    if [ "$i" -le 2 ]; then
        # First two clients: visible side by side
        POS_X=$(( (i-1) * VISIBLE_W ))
        RES="${VISIBLE_W}x${VISIBLE_H}"
        POS="${POS_X},0"
        echo "Starting client $i (${CLASS}, visible at ${POS})..."
    else
        # Extra clients: tiny windows stacked offscreen — they connect and load
        # the map, exercising server movement/sync code for all N players.
        POS_X=$(( (i-3) * BOT_W ))
        RES="${BOT_W}x${BOT_H}"
        POS="-10000,${POS_X}"
        echo "Starting client $i (${CLASS}, background)..."
    fi

    env ${NET_ENV[@]+"${NET_ENV[@]}"} \
        "$GODOT" --path "$PROJECT_DIR" --resolution "$RES" --position "$POS" \
        -- --connect 127.0.0.1 --team 1 --class "$CLASS" &
    CLIENT_PIDS+=($!)
    sleep 0.5
done

echo ""
echo "Server PID: $SERVER_PID"
echo "Client PIDs: ${CLIENT_PIDS[*]}"
echo "Press Ctrl+C to kill all"

cleanup() {
    echo "Shutting down..."
    kill "${CLIENT_PIDS[@]}" $SERVER_PID 2>/dev/null
    wait
}
trap cleanup EXIT INT TERM

wait
