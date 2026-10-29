#!/usr/bin/env bash
# Start the WizardWars dedicated server from source on macOS — the dev equivalent of the
# Linux package's run.sh (which runs the shipped WizardWars.x86_64 binary headless).
#
# Usage:
#   ./run.sh                                  # default map (ww_2fort)
#   ./run.sh --map ww_hunt                    # pick a map
#   ./run.sh --map ww_hunt --serve-dist       # also serve launcher + client downloads (LAN)
#   ./run.sh --serve-dist build/dist          # serve a specific dist directory
#
# --serve-dist [dir] points the server's built-in HTTP server (port 8080) at the launcher
# bundle so friends can install/update over LAN with launcher.sh. Build that bundle first
# with `./release.sh --serve` (writes build/dist/: version.txt, WizardWars-*.zip, launcher.*).
# The server already serves /resources and /maps for in-game downloads, and auto-advertises
# its LAN IP, so clients fetch maps from this box without any extra flags.
#
# Any other --server flag main.gd understands is forwarded (--name, --team, --class,
# --admin-password, --http-base-url, ...). Override the engine with GODOT=/path/to/Godot.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve the Godot binary: $GODOT override, then the common macOS install paths
# (same resolution as run_tests.sh).
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

# Pull our own flags out of the arg list; everything else is forwarded to the engine.
SERVE=0
SERVE_DIST=""
FORWARD=()
while [ $# -gt 0 ]; do
    case "$1" in
        --serve-dist)
            SERVE=1
            # Optional value: consume the next token only if it isn't another flag.
            if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then SERVE_DIST="$2"; shift; fi
            ;;
        *) FORWARD+=("$1") ;;
    esac
    shift
done

# Membership test that stays safe on bash 3.2 (macOS) when the array is empty under set -u.
forward_has() {
    local needle="$1" x
    for x in ${FORWARD[@]+"${FORWARD[@]}"}; do [ "$x" = "$needle" ] && return 0; done
    return 1
}

if [ "$SERVE" = 1 ]; then
    [ -n "$SERVE_DIST" ] || SERVE_DIST="$PROJECT_DIR/build/dist"
    SERVE_DIST="$(cd "$SERVE_DIST" 2>/dev/null && pwd || true)"
    if [ -z "$SERVE_DIST" ] || [ ! -f "$SERVE_DIST/version.txt" ]; then
        echo "No launcher bundle found (expected <dist>/version.txt)." >&2
        echo "Build it first:  ./release.sh --serve" >&2
        exit 1
    fi
    forward_has --http-downloads-dir || FORWARD+=(--http-downloads-dir "$SERVE_DIST")
    LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
    [ -n "$LAN_IP" ] || LAN_IP="<your-lan-ip>"
    echo "Serving launcher + client downloads from: $SERVE_DIST"
    echo "Tell players (LAN):"
    echo "  WW_UPDATE_SERVER=http://$LAN_IP:8080 ./launcher.sh"
    echo ""
fi

# The headless server needs a map to load — default one when the caller didn't pass --map.
forward_has --map || FORWARD+=(--map ww_2fort)

echo "Starting WizardWars dedicated server on UDP 9050 (HTTP 8080)..."
echo "  godot: $GODOT"
echo "  args:  --server ${FORWARD[*]}"
exec "$GODOT" --path "$PROJECT_DIR" --headless -- --server ${FORWARD[@]+"${FORWARD[@]}"}
