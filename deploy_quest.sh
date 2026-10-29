#!/usr/bin/env bash
set -euo pipefail

# Build WizardWars for Meta Quest and deploy via ADB.
# Quest must be connected via USB with developer mode on.
#
# Usage:
#   ./deploy_quest.sh              Build debug APK, kill + install on Quest
#   ./deploy_quest.sh --release    Build release APK instead
#   ./deploy_quest.sh --launch     Also launch the app after install
#   ./deploy_quest.sh --no-build   Skip build, just kill + install existing APK

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APK="$PROJECT_DIR/wizardwars.apk"
PACKAGE="net.spearfisher.wizardwars"
ACTIVITY="com.godot.game.GodotAppLauncher"

BUILD_TYPE="debug"
DO_BUILD=true
DO_LAUNCH=true

for arg in "$@"; do
    case "$arg" in
        --release)  BUILD_TYPE="release" ;;
        --no-build) DO_BUILD=false ;;
        --launch)   DO_LAUNCH=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# ── Java SDK (required by Godot Android exporter) ─────────────────────────────
if [ -z "${JAVA_HOME:-}" ]; then
    JAVA_HOME="$(/usr/libexec/java_home 2>/dev/null || true)"
fi
if [ -z "${JAVA_HOME:-}" ]; then
    echo "Error: JAVA_HOME is not set and /usr/libexec/java_home found nothing." >&2; exit 1
fi
export JAVA_HOME

# ── Locate Godot ──────────────────────────────────────────────────────────────
# Override with GODOT=/path/to/Godot to pin an engine version. Resolved once and
# exported so build.sh (and the --patch export below) use the same editor.
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

# ── Locate adb ────────────────────────────────────────────────────────────────
if command -v adb &>/dev/null; then
    ADB=adb
elif [ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]; then
    ADB="$HOME/Library/Android/sdk/platform-tools/adb"
else
    echo "Error: adb not found. Add Android SDK platform-tools to PATH." >&2; exit 1
fi

# ── Build ─────────────────────────────────────────────────────────────────────
if [[ "$DO_BUILD" == true ]]; then
    echo "=== Building Android APK ($BUILD_TYPE) ==="
    if [[ "$BUILD_TYPE" == "release" ]]; then
        "$GODOT" --headless --path "$PROJECT_DIR" --export-release "Android" "$APK"
    else
        "$GODOT" --headless --path "$PROJECT_DIR" --export-debug "Android" "$APK"
    fi
    echo "Built: $APK ($(du -sh "$APK" | cut -f1))"
fi

if [ ! -f "$APK" ]; then
    echo "Error: APK not found at $APK" >&2; exit 1
fi

# ── Kill ──────────────────────────────────────────────────────────────────────
echo ""
echo "=== Killing $PACKAGE on Quest ==="
"$ADB" shell am force-stop "$PACKAGE" 2>/dev/null || true

# ── Install ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Installing APK ==="
if ! "$ADB" install -r "$APK" 2>&1; then
    echo "Reinstall failed (signature mismatch?) — uninstalling and retrying..."
    "$ADB" uninstall "$PACKAGE" || true
    "$ADB" install "$APK"
fi

# ── Launch ────────────────────────────────────────────────────────────────────
if [[ "$DO_LAUNCH" == true ]]; then
    echo ""
    echo "=== Launching $PACKAGE ==="
    "$ADB" shell am start -n "$PACKAGE/$ACTIVITY"
fi

echo ""
echo "=== Done ==="
