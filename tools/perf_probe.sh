#!/usr/bin/env bash
# WizardWars remote perf probe — run this ON the slow machine, send back the tarball.
#
# Needs nothing installed: it drives an already-installed WizardWars.app with the game's own
# --perf-log/--auto-walk hooks and samples it with macOS's built-in /usr/bin/sample.
#
# Usage (on the slow Mac):
#   bash perf_probe.sh                       # default map, all three renderers
#   bash perf_probe.sh --map ww_hiddenforest --bots 8
#   bash perf_probe.sh --app /path/to/WizardWars.app
#   bash perf_probe.sh --renderers gl_compatibility   # just the shipped one
#   bash perf_probe.sh --connect 192.168.1.5          # profile as a client on a real server
#   bash perf_probe.sh --maps ~/wizardwars/maps        # feed maps from a source checkout
#
# Writes ww-perf-<host>-<stamp>.tgz next to itself. Send that file back.
set -uo pipefail

MAP="ww_hiddenforest"
BOTS=8
SECONDS_PER_RUN=45
RES="1280x720"
GRACE=900             # extra wall-clock seconds allowed for map/resource download before giving up.
                      # A first-ever join fetches the map plus ~1400 resource files one at a time,
                      # so this is minutes on a WAN, not seconds.
RENDERERS="gl_compatibility mobile forward_plus"
APP=""
CONNECT=""            # --connect <ip>: profile as a pure client instead of a listen host
MAPS_DIR=""           # --maps <dir>: a wizardwars checkout's maps/, for a client that ships none

while [ $# -gt 0 ]; do
    case "$1" in
        --map)       MAP="$2"; shift ;;
        --bots)      BOTS="$2"; shift ;;
        --seconds)   SECONDS_PER_RUN="$2"; shift ;;
        --renderers) RENDERERS="$2"; shift ;;
        --resolution) RES="$2"; shift ;;
        --grace)     GRACE="$2"; shift ;;
        --app)       APP="$2"; shift ;;
        --connect)   CONNECT="$2"; shift ;;
        --maps)      MAPS_DIR="$2"; shift ;;
        -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

# ── Locate the game ───────────────────────────────────────────────────────────
if [ -z "$APP" ]; then
    for candidate in \
        "/Applications/WizardWars.app" \
        "/Applications/Wizard Wars.app" \
        "$HOME/Applications/WizardWars.app" \
        "$HOME/WizardWars/WizardWars.app" \
        "$(dirname "$0")/WizardWars/WizardWars.app" \
        "$(dirname "$0")/WizardWars.app"; do
        if [ -d "$candidate" ]; then APP="$candidate"; break; fi
    done
fi
if [ -z "$APP" ]; then
    APP="$(find "$HOME" -maxdepth 5 \( -name "WizardWars.app" -o -name "Wizard Wars.app" \) -type d 2>/dev/null | head -1)"
fi
# The bundle is WizardWars.app but the executable inside is named after the project
# ("Wizard Wars"), so read it rather than guessing.
BIN=""
if [ -d "$APP" ]; then
    EXE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist" 2>/dev/null || true)"
    [ -n "$EXE" ] && [ -x "$APP/Contents/MacOS/$EXE" ] && BIN="$APP/Contents/MacOS/$EXE"
    [ -z "$BIN" ] && BIN="$(find "$APP/Contents/MacOS" -maxdepth 1 -type f -perm -111 2>/dev/null | head -1)"
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "Couldn't find the WizardWars app bundle. Pass it: bash $0 --app /path/to/WizardWars.app" >&2
    exit 1
fi

# Sample the middle of the run: the first seconds are map load and shader warm-up, which are a
# different question from steady-state frame cost.
SAMPLE_AT=$(( SECONDS_PER_RUN / 3 ))
SAMPLE_FOR=$(( SECONDS_PER_RUN / 3 ))
[ "$SAMPLE_FOR" -lt 5 ] && SAMPLE_FOR=5

# ── Supply the map ────────────────────────────────────────────────────────────
# The client ships no .bsp (they are excluded from the .pck and normally arrive as a download
# from the server you join), so a --host run on a fresh install has nothing to load. The game
# resolves maps/<name>.bsp beside its own executable before res://, so a source checkout on this
# machine can feed it one. Removed again on exit — the converted .scn is cached in user:// and
# later runs of the same map need none of this.
STAGED=""
cleanup_staged() { [ -n "$STAGED" ] && rm -rf "$STAGED"; }
trap cleanup_staged EXIT

CACHED="$HOME/Library/Application Support/Godot/app_userdata/Wizard Wars/resources/maps/$MAP.scn"
if [ -z "$CONNECT" ] && [ ! -f "$CACHED" ]; then
    if [ -z "$MAPS_DIR" ]; then
        for candidate in \
            "$HOME/wizardwars/maps" \
            "$HOME/src/wizardwars/maps" \
            "$HOME/Projects/wizardwars/maps" \
            "$(dirname "$0")/../maps"; do
            if [ -f "$candidate/$MAP.bsp" ]; then MAPS_DIR="$candidate"; break; fi
        done
    fi
    if [ -z "$MAPS_DIR" ] || [ ! -f "$MAPS_DIR/$MAP.bsp" ]; then
        echo "No $MAP.bsp available and none cached." >&2
        echo "Point at a checkout:  bash $0 --maps /path/to/wizardwars/maps" >&2
        echo "or profile as a client against a real server:  bash $0 --connect <server-ip>" >&2
        exit 1
    fi
    STAGED="$APP/Contents/MacOS/maps"
    mkdir -p "$STAGED"
    cp "$MAPS_DIR/$MAP.bsp" "$STAGED/"
    for side in "$MAP.txt" "$MAP.ww" "${MAP}_readme.txt"; do
        [ -f "$MAPS_DIR/$side" ] && cp "$MAPS_DIR/$side" "$STAGED/"
    done
    echo "Staged $MAP.bsp from $MAPS_DIR."
    # Convert it once now, discarding the result. Conversion happens before the map is playable,
    # so leaving it inside a timed run would have the sampler profiling the BSP importer.
    echo "Converting (once per map — minutes on older hardware)..."
    CONVLOG="$(dirname "$0")/ww-convert-$MAP.log"
    "$BIN" --rendering-method gl_compatibility --resolution "$RES" -- \
        --host --map "$MAP" --team red --class fire --renderer-applied --perf-log 5 --perf-quit 3 > "$CONVLOG" 2>&1 &
    CPID=$!
    CWAIT=0
    while kill -0 "$CPID" 2>/dev/null && [ "$CWAIT" -lt 1800 ]; do
        sleep 10; CWAIT=$(( CWAIT + 10 ))
        echo "  [${CWAIT}s] $(grep -E "MapConverter:|Loaded .* WADs|^Renderer:" "$CONVLOG" 2>/dev/null | tail -1)"
    done
    kill "$CPID" 2>/dev/null
    if [ ! -f "$CACHED" ]; then
        echo "--- conversion log ---" >&2
        tail -20 "$CONVLOG" >&2
        echo "Conversion did not produce $CACHED — see if the game opens this map by hand." >&2
        exit 1
    fi
    echo ""
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$(cd "$(dirname "$0")" && pwd)/ww-perf-$(hostname -s)-$STAMP"
mkdir -p "$OUT"
echo "WizardWars perf probe"
echo "  game:   $BIN"
echo "  map:    $MAP   bots: $BOTS   ${SECONDS_PER_RUN}s per renderer at $RES"
echo "  out:    $OUT"
echo ""

# ── Machine identity ──────────────────────────────────────────────────────────
{
    sw_vers
    echo ""
    system_profiler SPHardwareDataType SPDisplaysDataType 2>/dev/null
    echo ""
    echo "== game build =="
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null
    cat "$(dirname "$APP")/version.txt" 2>/dev/null
    ls -la "$APP/Contents/MacOS" 2>/dev/null
} > "$OUT/machine.txt" 2>&1
echo "Machine:"
grep -E "Model Identifier|Chipset Model|VRAM|Resolution|ProductVersion" "$OUT/machine.txt" | sed 's/^/  /'
echo ""

# ── One timed run per renderer ────────────────────────────────────────────────
for RENDERER in $RENDERERS; do
    echo "── $RENDERER ─────────────────────────────────────────"
    LOG="$OUT/$RENDERER.stdout.txt"
    # Engine args go before the --, game args after it.
    # A listen host measures client+server in one process. --connect profiles the client alone,
    # which is what a player joining someone else's server actually pays.
    if [ -n "$CONNECT" ]; then
        ROLE=(--connect "$CONNECT")
    else
        ROLE=(--host --map "$MAP" --bots "$BOTS")
    fi
    # --renderer-applied stops main.gd relaunching us into a saved lobby preference: this script
    # picks the renderer deliberately, one per run.
    echo "  $ $(basename "$BIN") --rendering-method $RENDERER --resolution $RES -- ${ROLE[*]} --team red --class fire --auto-walk --auto-fire --perf-log 5 --perf-quit $SECONDS_PER_RUN"
    "$BIN" --rendering-method "$RENDERER" --resolution "$RES" --position 0,0 -- \
        "${ROLE[@]}" --team red --class fire --renderer-applied \
        --auto-walk --auto-fire --perf-log 5 --perf-quit "$SECONDS_PER_RUN" \
        > "$LOG" 2>&1 &
    PID=$!

    # What the engine says in its first seconds settles most failures: whether the args were seen
    # at all, which renderer initialised, and whether the map started converting.
    sleep 8
    echo "  --- first seconds ---"
    grep -E "^Renderer:|MapConverter:|Received map info|Connecting|Godot Engine|ERROR|Failed|Unrecognized|Invalid" "$LOG" 2>/dev/null | head -8 | sed 's/^/  | /'

    # Sample the native call graph mid-run: this is what says whether the cost is the GL driver,
    # skinning, or GDScript. Skipped if the process already died (that IS the result for a
    # renderer this machine can't initialise).
    ( sleep "$SAMPLE_AT"
      if kill -0 "$PID" 2>/dev/null; then
          sample "$PID" "$SAMPLE_FOR" -f "$OUT/$RENDERER.sample.txt" >/dev/null 2>&1
      fi ) &
    SAMPLER=$!

    # --perf-quit only counts down once the map is playable, so a client stuck connecting,
    # downloading, or on a renderer it cannot initialise never exits on its own. Wall-clock
    # watchdog, and say what stage it reached rather than sitting there silently.
    DEADLINE=$(( SECONDS_PER_RUN + GRACE ))
    ELAPSED=0
    LAST_STAGE=""
    while kill -0 "$PID" 2>/dev/null && [ "$ELAPSED" -lt "$DEADLINE" ]; do
        sleep 3; ELAPSED=$(( ELAPSED + 3 ))
        STAGE="$(grep -E "Received map info|Map cache|Downloading .* resources|Resource HTTP download complete|All resources cached|Player spawned|Failed to join|Connection failed" "$LOG" 2>/dev/null | tail -1)"
        if [ -n "$STAGE" ] && [ "$STAGE" != "$LAST_STAGE" ]; then
            echo "  [${ELAPSED}s] $STAGE"
            LAST_STAGE="$STAGE"
        fi
    done
    if kill -0 "$PID" 2>/dev/null; then
        echo "  STUCK: no playable frame after ${DEADLINE}s — killing it"
        kill "$PID" 2>/dev/null; sleep 3; kill -9 "$PID" 2>/dev/null
        RC="timeout"
    else
        wait "$PID"; RC=$?
    fi
    wait "$SAMPLER" 2>/dev/null

    echo "  exit code: $RC" | tee -a "$LOG"
    grep -m1 "^Renderer:" "$LOG" | sed 's/^/  /'
    if grep -q "ClientPerf" "$LOG"; then
        grep "ClientPerf" "$LOG" | tail -3 | sed 's/^/  /'
    else
        echo "  no ClientPerf lines — this renderer did not get to a playable frame"
        tail -12 "$LOG" | sed 's/^/  ! /'
        echo ""
        echo "  Stopping here: the other renderers will fail the same way. Send the tarball."
        break
    fi
    echo ""
done

# ── The game's own log files ──────────────────────────────────────────────────
USERDIR="$HOME/Library/Application Support/Godot/app_userdata/Wizard Wars"
[ -d "$USERDIR" ] && cp "$USERDIR"/*.log "$OUT/" 2>/dev/null
cp "$HOME/Library/Logs/DiagnosticReports/"*izard*.ips "$OUT/" 2>/dev/null

TGZ="$OUT.tgz"
tar -czf "$TGZ" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo "Done. Send this file back:"
echo "  $TGZ"
