#!/usr/bin/env bash
set -euo pipefail

# Bundle the Linux server package from pre-converted assets.
#
# Prerequisites:
#   ./convert.sh             (assets converted to ~/Library/.../Wizard Wars)
#   ./build.sh --linux-server  (binary built at build/linux-server/)
#
# Usage:
#   ./package.sh        Bundle assets into build/linux-server/userdata/
#   ./package.sh --zip  Also zip the server package
#   ./package.sh --rotation-only  Bundle only the maps listed in maps/mapcycle.txt

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
SERVER_DIR="$BUILD_DIR/linux-server"
APP_NAME="WizardWars"

GODOT_USERDATA="$HOME/Library/Application Support/Godot/app_userdata/Wizard Wars"

BUILD_ZIP=false
ROTATION_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --zip) BUILD_ZIP=true ;;
        --rotation-only) ROTATION_ONLY=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if [ ! -f "$SERVER_DIR/$APP_NAME.x86_64" ]; then
    echo "Error: $SERVER_DIR/$APP_NAME.x86_64 not found." >&2
    echo "  Run ./build.sh --linux-server first." >&2
    exit 1
fi

if [ ! -d "$GODOT_USERDATA/resources" ]; then
    echo "Error: No converted assets found at: $GODOT_USERDATA" >&2
    echo "  Run ./convert.sh first." >&2
    exit 1
fi

# ── Bundle assets ─────────────────────────────────────────────────────────────
echo "=== Bundling assets ==="
USERDATA_DIR="$SERVER_DIR/userdata"
rm -rf "$USERDATA_DIR"
mkdir -p "$USERDATA_DIR"

if [ -d "$GODOT_USERDATA/resources" ]; then
    # Only what the pck lacks: the manifest's files (converted copies of packed assets are left out).
    { echo manifest.json; jq -r 'keys[]' "$GODOT_USERDATA/resources/manifest.json"; } \
        | rsync -a --files-from=- "$GODOT_USERDATA/resources/" "$USERDATA_DIR/resources/"
    if [[ "$ROTATION_ONLY" == true ]]; then
        # Off-rotation maps stay in the local cache; the server never lists what it doesn't have.
        mkdir -p "$USERDATA_DIR/resources/maps"
        for map in $(sed 's/#.*//' "$PROJECT_DIR/maps/mapcycle.txt"); do
            for f in "$GODOT_USERDATA/resources/maps/$map".{scn,hash}; do
                [[ -f "$f" ]] || { echo "Error: rotation map not converted: $f" >&2; exit 1; }
                cp "$f" "$USERDATA_DIR/resources/maps/"
            done
        done
    else
        cp -r "$GODOT_USERDATA/resources/maps" "$USERDATA_DIR/resources/maps"
    fi
    MAP_COUNT=$(find "$USERDATA_DIR/resources/maps" -name "*.scn" 2>/dev/null | wc -l | tr -d ' ')
    echo "  resources/maps/  $MAP_COUNT .scn files"
    echo "  resources/       $(du -sh "$USERDATA_DIR/resources" | cut -f1)"
fi

# ── Write run.sh ──────────────────────────────────────────────────────────────
# The public URL clients fetch maps from (WW_SERVER_HOST, set by release.sh); without it the
# server auto-detects one.
BASE_URL_ARG=""
if [[ -n "${WW_SERVER_HOST:-}" ]]; then
    BASE_URL_ARG="    --http-base-url \"http://$WW_SERVER_HOST:8080\" \\"$'\n'
fi
{ cat << 'EOF'
#!/usr/bin/env bash
# Run the WizardWars dedicated server.
# Usage: ./run.sh --map <mapname> [other options]
DIR="$(cd "$(dirname "$0")" && pwd)"
GODOT_USER_BASE="$HOME/.local/share/godot/app_userdata"
mkdir -p "$GODOT_USER_BASE"
ln -sfn "$DIR/userdata" "$GODOT_USER_BASE/Wizard Wars"
# dist/ (sibling of server/) is served at / on port 8080 for launcher + client downloads
exec "$DIR/WizardWars.x86_64" --headless -- --server \
    --http-downloads-dir "$(realpath "$DIR/../dist")" \
EOF
printf '%s' "$BASE_URL_ARG"
echo '    "$@"'
} > "$SERVER_DIR/run.sh"
chmod +x "$SERVER_DIR/run.sh"

echo ""
echo "=== Package ready: $SERVER_DIR/ ==="
echo "  $(du -sh "$SERVER_DIR/$APP_NAME.x86_64" | cut -f1)  $APP_NAME.x86_64"
echo "  $(du -sh "$SERVER_DIR/userdata" | cut -f1)  userdata/"
echo ""
echo "Deploy: rsync -a build/linux-server/ user@host:/opt/wizardwars/"
echo "Run:    ./run.sh --map <mapname>"

if [[ "$BUILD_ZIP" == true ]]; then
    ZIP_PATH="$BUILD_DIR/$APP_NAME-linux-server.zip"
    rm -f "$ZIP_PATH"
    (cd "$BUILD_DIR" && zip -qr "$APP_NAME-linux-server.zip" linux-server/)
    echo ""
    echo "Zipped: $ZIP_PATH ($(du -sh "$ZIP_PATH" | cut -f1))"
fi
