#!/usr/bin/env bash
set -euo pipefail

# Release WizardWars: convert assets, build all targets, package server, upload.
#
# Usage:
#   ./release.sh              Full release (rebuilds only GDExtensions whose source changed)
#   ./release.sh --rebuild-ext  Force-rebuild the GDExtensions even if unchanged
#   ./release.sh --skip-maps    Skip the BSP->.scn pass; still converts models/sprites/sounds
#   ./release.sh --skip-convert Skip asset conversion entirely
#   ./release.sh --all-maps   Convert and ship every BSP, not just the maps in maps/mapcycle.txt
#   ./release.sh --serve      Build clients, then RUN a local server hosting them (no upload).
#                             The local equivalent of a plain ./release.sh — one command.
#                             Pass --map <name> to pick the map (default ww_2fort).
#                             (To just switch maps without rebuilding: ./run.sh --serve-dist --map <name>)
#
# Where to ship comes from release.env (gitignored), so the source never names the server:
#   WW_SERVER_HOST=example.com   baked into the shipped launchers, the client's lobby, the server's run.sh
#   WW_REMOTE=user@example.com   ssh/rsync target
#   WW_SSH_PORT=22
#
# Server-side setup (one time on the release server):
#   ~/wizardwars/dist/   — client downloads (launcher, zips) served by the game server
#   ~/wizardwars/server/ — run: ./run.sh --map <mapname>
#   The game server hosts both game traffic (port 9050) and HTTP (port 8080) in one process.

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
SERVER_DIR="$BUILD_DIR/linux-server"
DIST_DIR="$BUILD_DIR/dist"

# shellcheck source=/dev/null
[[ -f "$PROJECT_DIR/release.env" ]] && source "$PROJECT_DIR/release.env"
# Exported for build.sh (stamps the lobby default) and package.sh (the server's --http-base-url).
export WW_SERVER_HOST="${WW_SERVER_HOST:-}"

REMOTE="${WW_REMOTE:-}"
REMOTE_BASE="$REMOTE:wizardwars"
REMOTE_HOST="${REMOTE%%:*}"
SSH_PORT="${WW_SSH_PORT:-22}"
SSH_RSH="ssh -p $SSH_PORT"
SERVE_PORT="${WW_SERVE_PORT:-8080}"
MAP="${WW_MAP:-ww_2fort}"

SERVE=false
NO_RESTART=false
REBUILD_EXT=false
SKIP_CONVERT=false
ROTATION_ONLY=true
CONVERT_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --serve)       SERVE=true ;;
        --no-restart)  NO_RESTART=true ;;
        --rebuild-ext) REBUILD_EXT=true ;;   # force-rebuild GDExtensions even if unchanged
        # The map pass is the slow half even when every BSP is cached. Skip it when you know the
        # maps are untouched — a client shipped against stale map caches is the thing you lose.
        --skip-maps)   CONVERT_ARGS=(--resources-only) ;;
        --skip-convert) SKIP_CONVERT=true ;;
        # Off-rotation maps are neither converted nor uploaded, and are pruned from the server.
        --all-maps)    ROTATION_ONLY=false ;;
        --map)         shift; MAP="${1:?--map requires a map name}" ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done
if [[ "$SERVE" == false && ( -z "$REMOTE" || -z "$WW_SERVER_HOST" ) ]]; then
    echo "Error: set WW_REMOTE and WW_SERVER_HOST in release.env (see the top of release.sh)." >&2
    exit 1
fi
PACKAGE_ARGS=()
if [[ "$ROTATION_ONLY" == true ]]; then
    CONVERT_ARGS+=(--rotation-only)
    PACKAGE_ARGS+=(--rotation-only)
fi

# ── Locate Godot ──────────────────────────────────────────────────────────────
# Override with GODOT=/path/to/Godot to pin an engine version. Resolved once and
# exported so build.sh uses the same editor.
locate_godot() {
    if [ -n "${GODOT:-}" ]; then echo "$GODOT"
    elif command -v godot &>/dev/null; then echo godot
    elif [ -x "$HOME/Applications/Godot.app/Contents/MacOS/Godot" ]; then echo "$HOME/Applications/Godot.app/Contents/MacOS/Godot"
    elif [ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]; then echo "/Applications/Godot.app/Contents/MacOS/Godot"
    else echo "Error: Godot not found. Set GODOT=/path/to/Godot." >&2; exit 1
    fi
}
export GODOT="$(locate_godot)"
echo "Using Godot: $GODOT"

restart_server() {
    if [[ "$NO_RESTART" == true ]]; then
        echo "=== Skipped server restart ==="
        echo "To restart manually: ssh -p $SSH_PORT $REMOTE_HOST 'pkill -f [W]izardWars.x86_64; cd wizardwars/server && nohup ./run.sh --map $MAP < /dev/null > ~/wizardwars/server.log 2>&1 &'"
        return
    fi
    echo "=== Restarting server on $REMOTE_HOST (map: $MAP) ==="
    # shellcheck disable=SC2029  # MAP expands intentionally on the local side
    ssh -p "$SSH_PORT" "$REMOTE_HOST" "
        pkill -f '[W]izardWars.x86_64' || true
        sleep 1
        nohup bash -l -c 'cd ~/wizardwars/server && ./run.sh --map $MAP' < /dev/null > ~/wizardwars/server.log 2>&1 &
        disown
        echo \"Server started (PID \$!), log: ~/wizardwars/server.log\"
    "
}

# Newest / oldest file mtime (epoch seconds) among the given `find` predicates, or empty.
newest_mtime() { find "$@" -exec stat -f '%m' {} + 2>/dev/null | sort -n | tail -1; }
oldest_mtime() { find "$@" -exec stat -f '%m' {} + 2>/dev/null | sort -n | head -1; }

# Platforms whose release libs this script's export actually ships (see the build.sh
# --windows/--linux-* invocation below). build.sh builds ALL platforms at once, so a partial
# local build (e.g. macOS-only) must NOT be mistaken for "up to date" — the export would then
# fail copying a platform lib that was never built. (macOS = dev runs only; Android/Quest = a
# separate, NDK-gated build — neither ships from here, so they aren't required.) Only x86_64 is
# exported: a leftover linux arm64 lib would otherwise read as stale forever.
EXPORT_PLATFORMS=(windows linux)
EXPORT_ARCH=x86_64

# Does an extension need a (re)build? True (0) when a release lib for any shipped platform is
# missing, or when the built libs are older than a build input: C++ source, CMake config, or the
# godot-cpp checkout (extension_api.json's mtime tracks submodule version bumps).
#   extension_stale <repo-dir> <bin-dir-under-repo>
extension_stale() {
    local repo="$1" bindir="$2" src_m lib_m p
    local lib_dir="$PROJECT_DIR/$repo/$bindir"
    # Match ONLY the shipped-platform libs. macOS is a dev-only platform rebuilt out of band (plain
    # build.sh macos during local playtesting); a fresh macOS dylib must NOT count toward freshness,
    # or it masks an out-of-date windows/linux release lib and the export ships a stale one.
    local -a name_pred=()
    for p in "${EXPORT_PLATFORMS[@]}"; do
        # A missing per-platform release lib means the export can't copy it — force a (full) rebuild.
        [[ -n "$(newest_mtime "$lib_dir" -name "*.${p}.template_release.${EXPORT_ARCH}.*")" ]] || return 0
        name_pred+=( -o -name "*.${p}.template_release.${EXPORT_ARCH}.*" )
    done
    # Compare source against the OLDEST shipped-platform lib (drop the leading -o), so a stale lib
    # for ANY shipped platform triggers a rebuild — not just when the newest one happens to be old.
    lib_m=$(oldest_mtime "$lib_dir" \( "${name_pred[@]:1}" \))
    # The header-only cores an extension vendors (extern/hop, extern/goldnet) compile into it too.
    local -a vendored=()
    for p in "$PROJECT_DIR/$repo"/extern/*/include; do
        if [[ -d "$p" && "$p" != */godot-cpp/include ]]; then vendored+=( "$p" ); fi
    done
    src_m=$(newest_mtime \
        "$PROJECT_DIR/$repo/src" \
        "$PROJECT_DIR/$repo/CMakeLists.txt" \
        "$PROJECT_DIR/$repo/extern/godot-cpp/gdextension/extension_api.json" \
        ${vendored[@]+"${vendored[@]}"} \
        -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' -o -name 'CMakeLists.txt' -o -name 'extension_api.json' \))
    [[ -n "$src_m" ]] && (( src_m > lib_m ))
}

# ── Build GDExtensions — only the ones whose source changed ───────────────────
# Must run BEFORE convert.sh: asset conversion (e.g. BSP light-grid bake) runs
# inside libgoldsrc, so a stale lib would bake stale caches that convert.sh then
# skips as "up to date". --rebuild-ext forces a rebuild even when nothing changed.
echo ""
for pair in "extern/goldsrc-godot addons/goldsrc/bin" "extern/hop-godot addons/hop-physics/bin" "extern/goldnet-godot addons/goldnet/bin"; do
    read -r repo bindir <<< "$pair"
    name=$(basename "$repo")
    if [[ "$REBUILD_EXT" == true ]] || extension_stale "$repo" "$bindir"; then
        echo "=== Building GDExtension: $name ==="
        "$PROJECT_DIR/$repo/build.sh"
    else
        echo "=== GDExtension up to date, skipping: $name ==="
    fi
done

# ── Convert assets ────────────────────────────────────────────────────────────
# Runs after the GDExtension build (so it bakes with current libgoldsrc) but
# before the export/build below, so Godot's import step finds everything cached.
echo ""
if [[ "$SKIP_CONVERT" == true ]]; then
    echo "=== Skipping asset conversion (--skip-convert) ==="
else
    echo "=== Converting assets ${CONVERT_ARGS[*]-} ==="
    "$PROJECT_DIR/convert.sh" ${CONVERT_ARGS[@]+"${CONVERT_ARGS[@]}"}
fi

# ── Build all targets ─────────────────────────────────────────────────────────
# --zip lets build.sh own the client zip layout; we just relocate them below.
echo ""
echo "=== Building ==="
if [[ "$SERVE" == true ]]; then
    "$PROJECT_DIR/build.sh" --windows --linux-client --zip
else
    "$PROJECT_DIR/build.sh" --windows --linux-client --linux-server --zip
fi

# ── Package server ────────────────────────────────────────────────────────────
if [[ "$SERVE" == false ]]; then
    echo ""
    "$PROJECT_DIR/package.sh" ${PACKAGE_ARGS[@]+"${PACKAGE_ARGS[@]}"}
fi

# ── Package client dist ───────────────────────────────────────────────────────
echo ""
echo "=== Packaging client distribution ==="
mkdir -p "$DIST_DIR"

VERSION="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)-$(date +%Y%m%d%H%M%S)"
echo "$VERSION" > "$DIST_DIR/version.txt"
echo "Version: $VERSION"

# Legacy: patch releases are gone, but a client that took one still holds a patch.pck.
# An empty patch.txt is what tells the launcher to drop it (rsync never deletes).
: > "$DIST_DIR/patch.txt"
rm -f "$DIST_DIR/patch.pck"

# Relocate the zips build.sh --zip just produced (single source of zip layout).
for z in mac windows linux; do
    src="$BUILD_DIR/WizardWars-$z.zip"
    [[ -f "$src" ]] || { echo "Error: expected $src from build.sh --zip" >&2; exit 1; }
    mv -f "$src" "$DIST_DIR/WizardWars-$z.zip"
    echo "Packaged: WizardWars-$z.zip ($(du -sh "$DIST_DIR/WizardWars-$z.zip" | cut -f1))"
done

# The source launchers name no server; the shipped copies point at ours. A --serve bundle stays
# blank: its players pass WW_UPDATE_SERVER, which run.sh prints.
BAKED_URL=""
[[ "$SERVE" == false ]] && BAKED_URL="http://$WW_SERVER_HOST:8080"
sed "s|^DEFAULT_SERVER_URL=\"\"|DEFAULT_SERVER_URL=\"$BAKED_URL\"|" "$PROJECT_DIR/launcher.sh" > "$DIST_DIR/launcher.sh"
sed "s|^set DEFAULT_SERVER_URL=|set DEFAULT_SERVER_URL=$BAKED_URL|" "$PROJECT_DIR/launcher.bat" > "$DIST_DIR/launcher.bat"
chmod +x "$DIST_DIR/launcher.sh"

echo ""
ls -lh "$DIST_DIR/"

# ── Serve (LAN) or Upload ─────────────────────────────────────────────────────
# LAN serve mode: hand off to the local server, which serves the bundle we just built
# (build/dist) on port 8080 and hosts the game on 9050. run.sh prints the launcher line
# players need. exec so Ctrl-C stops the server cleanly. This is the local mirror of the
# upload+restart the non-serve path does to the wave server.
if [[ "$SERVE" == true ]]; then
    echo ""
    echo "=== Starting local server (map: $MAP), serving build/dist on port $SERVE_PORT ==="
    exec "$PROJECT_DIR/run.sh" --serve-dist "$DIST_DIR" --map "$MAP"
fi

echo ""
echo "=== Uploading to $REMOTE ==="
echo "  dist/ -> $REMOTE_BASE/dist/"
rsync -avz --progress -e "$SSH_RSH" "$DIST_DIR/" "$REMOTE_BASE/dist/"

echo ""
echo "  server/ -> $REMOTE_BASE/server/"
rsync -avz --progress -e "$SSH_RSH" "$SERVER_DIR/" "$REMOTE_BASE/server/"
# The server rebuilds its manifest from whatever sits here, so stale copies would reach every peer.
echo "  pruning $REMOTE_BASE/server/userdata/resources/ to the package (maps aside)"
rsync -avz --delete --exclude='/maps/' -e "$SSH_RSH" "$SERVER_DIR/userdata/resources/" "$REMOTE_BASE/server/userdata/resources/"
if [[ "$ROTATION_ONLY" == true ]]; then
    echo "  pruning off-rotation maps from $REMOTE_BASE/server/userdata/resources/maps/"
    rsync -avz --delete -e "$SSH_RSH" "$SERVER_DIR/userdata/resources/maps/" "$REMOTE_BASE/server/userdata/resources/maps/"
fi

# Same for the copies on the server (the empty patch.txt uploaded above stays).
ssh -p "$SSH_PORT" "$REMOTE_HOST" 'rm -f ~/wizardwars/dist/patch.pck ~/wizardwars/server/patch.pck' || true

echo ""
restart_server
echo "=== Release complete ==="
echo "The server hosts game traffic on port 9050 and HTTP on port 8080."
