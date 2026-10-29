#!/usr/bin/env bash
# Live host+client verification: boots a headless dedicated server and a headless client that
# actually joins it, then asserts what arrived. This is the harness for the things the unit suite
# structurally cannot reach — run_tests.tscn never installs goldnet, never opens a socket, and
# never spawns across a peer boundary.
#
# What it proves (and what it is for):
#   * the client connects and completes the join handshake
#   * MultiplayerSpawner replication works end to end -- the path capture_spawners() exists to arm
#   * goldnet's snapshot stream is flowing (client-side `[goldnet] recv ... changed=N`)
#   * --loss 100 actually suppresses that stream while the reliable join still succeeds, which is
#     the end-to-end check on GOLDNET_LOSS / the /sim_loss knob that had never been exercised
#
# Measured baselines on ww_2fort / 3 bots / 20-25s, for reading a run at a glance:
#   --loss 0     client registered ~385 of ~390 owned; seq advances ~60/s; max_changed ~2
#   --loss 50    STILL converges to ~385; max_changed jumps to ~22 -- that is the ack-delta
#                signature, not a fault: dropped snapshots stall the ack, so the next survivor
#                re-carries everything since the last acked baseline. Bigger deltas, same answer.
#   --loss 100   registered=0, recv_lines=0, yet the client still joins and appears in the
#                roster -- loss hits only the unreliable stream, never the reliable @rpc path.
#
# Note `changed` alone is PVS-dependent: a client parked in a quiet corner legitimately reads 0.
# That is why the client runs with --auto-walk and why liveness is asserted off seq advance and
# the registry count rather than off changed.
#
# Usage:
#   tools/net_verify.sh                          # ww_2fort, 3 bots, no loss, 25s
#   tools/net_verify.sh --loss 100               # prove loss suppresses the snapshot stream
#   tools/net_verify.sh --map ww_hunt --bots 5 --seconds 40
#   tools/net_verify.sh --keep                   # leave the logs for inspection
set -uo pipefail

MAP=ww_2fort
BOTS=3
LOSS=0
SECONDS_RUN=25
KEEP=0
FIRE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --map)     MAP="$2"; shift ;;
        --bots)    BOTS="$2"; shift ;;
        --loss)    LOSS="$2"; shift ;;
        --seconds) SECONDS_RUN="$2"; shift ;;
        --keep)    KEEP=1 ;;
        --fire)    FIRE=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
    for c in "/Applications/Godot.app/Contents/MacOS/Godot" "$HOME/Applications/Godot.app/Contents/MacOS/Godot"; do
        [ -x "$c" ] && GODOT="$c" && break
    done
fi
[ -x "${GODOT:-}" ] || { echo "Godot not found. Set GODOT=/path/to/Godot" >&2; exit 127; }

OUT="$(mktemp -d "${TMPDIR:-/tmp}/ww-netverify.XXXXXX")"
USERDATA="$HOME/Library/Application Support/Godot/app_userdata/Wizard Wars"
CLIENT_NAME=NetVerify
SRV_PID=""

cleanup() {
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null
    # run.sh execs Godot, so the usual "res://src/main" pattern matches nothing (see the dev notes).
    pkill -f "Godot.*--server" 2>/dev/null
    if [ "$KEEP" = 1 ]; then echo "logs kept in: $OUT"; else rm -rf "$OUT"; fi
}
trap cleanup EXIT

say()  { printf '%s\n' "$*"; }
pass=0; fail=0
check() { # check <label> <0|1>
    if [ "$2" = 0 ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
    else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

say "=== net_verify: map=$MAP bots=$BOTS loss=${LOSS}% run=${SECONDS_RUN}s fire=$FIRE ==="

# A survivor holds UDP 9050 and still answers status.json, so a stale process makes this whole run
# report the OLD server's state. Clear it and confirm the port is actually free.
pkill -f "Godot.*--server" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
    lsof -nP -iUDP:9050 >/dev/null 2>&1 || break
    sleep 1
done
if lsof -nP -iUDP:9050 >/dev/null 2>&1; then
    say "ERROR: UDP 9050 still held; refusing to run (status.json would read the stale server)"
    exit 1
fi

say "-- starting server"
GOLDNET_DEBUG=1 GOLDNET_LOSS="$LOSS" \
    "$GODOT" --path "$PROJECT_DIR" --headless -- \
    --server --map "$MAP" --bots "$BOTS" >"$OUT/server.stdout" 2>&1 &
SRV_PID=$!

ready=1
for _ in $(seq 1 60); do
    if curl -sf --max-time 2 http://127.0.0.1:8080/status.json 2>/dev/null | grep -q "\"map\""; then ready=0; break; fi
    kill -0 "$SRV_PID" 2>/dev/null || { say "ERROR: server exited early"; tail -25 "$OUT/server.stdout"; exit 1; }
    sleep 1
done
check "server up and serving status.json" "$ready"
[ "$ready" = 0 ] || exit 1
curl -sf http://127.0.0.1:8080/status.json > "$OUT/status.before.json" 2>/dev/null

say "-- starting client (joins, plays ${SECONDS_RUN}s, exits via --perf-quit)"
# --perf-quit, deliberately without --perf-log: --perf-log would repoint file logging at perf.log
# and we want client.log. --interp-diag arms the entity-stream instrumentation from frame one.
FIRE_ARGS=()
[ "$FIRE" = 1 ] && FIRE_ARGS=(--auto-fire --auto-fire-slot 1)
GOLDNET_DEBUG=1 \
    "$GODOT" --path "$PROJECT_DIR" --headless -- \
    --connect 127.0.0.1 --team 1 --class fire --name "$CLIENT_NAME" \
    --auto-walk ${FIRE_ARGS[@]+"${FIRE_ARGS[@]}"} \
    --interp-diag --perf-quit "$SECONDS_RUN" >"$OUT/client.stdout" 2>&1 &
CLIENT_PID=$!

# Sample the roster WHILE the client is alive. Reading it after the client exits is a race: the
# server may already have processed the disconnect, dropping the name we are looking for — which
# showed up as an intermittent failure on an otherwise good run. Keep the first snapshot that
# actually contains the client.
: > "$OUT/status.during.json"
while kill -0 "$CLIENT_PID" 2>/dev/null; do
    if ! grep -q "\"$CLIENT_NAME\"" "$OUT/status.during.json" 2>/dev/null; then
        curl -sf --max-time 2 http://127.0.0.1:8080/status.json > "$OUT/status.during.json.tmp" 2>/dev/null \
            && mv "$OUT/status.during.json.tmp" "$OUT/status.during.json"
    fi
    sleep 1
done
wait "$CLIENT_PID"; CLIENT_RC=$?

cp "$OUT/status.during.json" "$OUT/status.after.json" 2>/dev/null
cp "$USERDATA/server.log" "$OUT/server.log" 2>/dev/null
cp "$USERDATA/client.log" "$OUT/client.log" 2>/dev/null

CS="$OUT/client.stdout"; SS="$OUT/server.stdout"

say ""
say "-- results"
grep -q "Peer connected" "$SS"; check "server saw the peer connect" $?
grep -qE "Assigned spawn by host|Joined team" "$CS"; check "client completed the join handshake" $?

# The spawner path: the server's bots are MultiplayerSpawner spawns, so a client that registers
# puppets proves spawn replication -- which is what capture_spawners() arms.
registered=$(grep -oE 'registered=[0-9]+' "$CS" 2>/dev/null | cut -d= -f2 | sort -rn | head -1)
registered=${registered:-0}
recv_lines=$(grep -c '\[goldnet\] recv' "$CS" 2>/dev/null || true)
changed_max=$(grep -oE 'changed=[0-9]+' "$CS" 2>/dev/null | cut -d= -f2 | sort -rn | head -1)
changed_max=${changed_max:-0}
interp=$(grep -c '\[InterpDiag\] tracking' "$CS" 2>/dev/null || true)
# Sequence numbers come off the snapshot header, so first != last proves a CONTINUOUS unreliable
# stream, not just one packet. `changed` alone is PVS-dependent and reads 0 on a quiet corner of
# the map, which is correct behaviour and therefore useless as a liveness signal.
seq_first=$(grep -oE 'recv seq=[0-9]+' "$CS" 2>/dev/null | cut -d= -f2 | head -1)
seq_last=$(grep -oE 'recv seq=[0-9]+' "$CS" 2>/dev/null | cut -d= -f2 | tail -1)
seq_first=${seq_first:-0}; seq_last=${seq_last:-0}
owned=$(grep -oE 'send owned=[0-9]+' "$SS" 2>/dev/null | cut -d= -f2 | sort -rn | head -1)
owned=${owned:-0}

say "     server owned=$owned   client registered=$registered"
say "     client stream: recv_lines=$recv_lines  seq ${seq_first}..${seq_last}  max_changed=$changed_max  interp_tracked=$interp"
say "     server roster:         $(tr -d '\n' < "$OUT/status.after.json" 2>/dev/null | head -c 300)"

grep -q "\"$CLIENT_NAME\"" "$OUT/status.after.json" 2>/dev/null
check "client appears in the server roster" $?

if [ "$LOSS" -ge 100 ]; then
    # Spawns ride reliable RPC, so the join still works; the unreliable snapshot stream must not.
    [ "$recv_lines" = 0 ]; check "loss=100 suppressed the snapshot stream (recv_lines=0)" $?
else
    [ "$recv_lines" -gt 0 ]; check "snapshot stream flowing (client received snapshots)" $?
    [ "$seq_last" -gt "$seq_first" ]; check "stream is continuous (snapshot seq advanced)" $?
    # The registry is what MultiplayerSpawner/synchronizer replication builds, so a non-zero count
    # here is the end-to-end proof that spawner capture worked -- what capture_spawners() arms.
    [ "$registered" -gt 0 ]; check "entities registered on the client (spawner capture worked)" $?
    [ "$owned" -gt 0 ] && [ "$registered" -ge $((owned * 90 / 100)) ]
    check "client registry within 10% of the server's ($registered vs $owned)" $?
    # REPORTED, not asserted. Whether an entity delta lands depends on something in THIS client's
    # PVS changing during one of goldnet's 2-second debug samples — with a random spawn and a short
    # walk that is luck, not a property of the code under test. It flaked 2 runs in 3 as a check.
    # The registry comparison above is the load-bearing evidence: it proves spawn replication
    # end to end, which is what this harness exists to guard.
    if [ "$interp" -gt 0 ] || [ "$changed_max" -gt 0 ]; then
        say "     note: entity state deltas observed (interp tracked=$interp, max changed=$changed_max)"
    else
        say "     note: no entity deltas sampled this run — expected when nothing in the client's"
        say "           PVS moved during a debug sample; not a failure (see --loss 50 for deltas)"
    fi
fi

if [ "$FIRE" = 1 ]; then
    # Owner-directed syncs (send_to_owner): mana spend on every shot, damage/frost when a bot
    # answers. Reported rather than asserted — whether a bot shoots back inside the window is
    # not deterministic — but a run with zero mana traffic means the path never executed.
    mana=$(grep -cE 'sync_mana|_on_sync_mana' "$CS" 2>/dev/null || true)
    say "     owner-directed sync traffic seen on client: mana/HUD lines=$mana"
fi

[ "$CLIENT_RC" = 0 ]; check "client exited cleanly (rc=$CLIENT_RC)" $?
grep -q "SCRIPT ERROR" "$CS"; rc=$?; [ "$rc" != 0 ]; check "no SCRIPT ERROR on the client" $?
grep -q "SCRIPT ERROR" "$SS"; rc=$?; [ "$rc" != 0 ]; check "no SCRIPT ERROR on the server" $?

say ""
say "=== $pass passed, $fail failed ==="
[ "$fail" = 0 ] || { say "(re-run with --keep to inspect the logs)"; exit 1; }
exit 0
