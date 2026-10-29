#!/usr/bin/env bash
set -euo pipefail

# Export WizardWars client and server binaries.
# Does NOT rebuild the BSP plugin or convert assets — run those separately.
#
# Usage:
#   ./build.sh                      macOS client only
#   ./build.sh --windows            + Windows client
#   ./build.sh --linux-client       + Linux client
#   ./build.sh --linux-server       + Linux server binary (for ./package.sh)
#   ./build.sh --zip                Zip all outputs

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
SERVER_DIR="$BUILD_DIR/linux-server"
# One directory per client export: Godot drops each platform's GDExtension libs beside the binary,
# so the export dir IS the package. Sharing build/ let the two platforms clobber each other's .pck.
WINDOWS_DIR="$BUILD_DIR/windows"
LINUX_DIR="$BUILD_DIR/linux"
APP_NAME="WizardWars"
# The macOS code-signing identifier, which TCC keys a permission grant to — it has to match the
# preset's application/bundle_identifier, or the signature and the Info.plist disagree about which
# app this is.
BUNDLE_ID="net.spearfischer.wizardwars"

BUILD_WINDOWS=false
BUILD_LINUX_CLIENT=false
BUILD_LINUX_SERVER=false
BUILD_ZIP=false
for arg in "$@"; do
    case "$arg" in
        --windows)      BUILD_WINDOWS=true ;;
        --linux-client) BUILD_LINUX_CLIENT=true ;;
        --linux-server) BUILD_LINUX_SERVER=true ;;
        --zip)          BUILD_ZIP=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# ── Locate Godot ──────────────────────────────────────────────────────────────
# Override with GODOT=/path/to/Godot (e.g. to pin a specific engine version).
# release.sh exports GODOT so this is resolved once for the whole release.
if [ -z "${GODOT:-}" ]; then
    if command -v godot &>/dev/null; then
        GODOT=godot
    elif [ -x "$HOME/Applications/Godot.app/Contents/MacOS/Godot" ]; then
        GODOT="$HOME/Applications/Godot.app/Contents/MacOS/Godot"
    elif [ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]; then
        GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
    else
        echo "Error: Godot not found. Set GODOT=/path/to/Godot." >&2; exit 1
    fi
fi
echo "Using Godot: $GODOT"
mkdir -p "$BUILD_DIR"

# ── Stamp the build ───────────────────────────────────────────────────────────
# The commit being exported, bundled into the .pck as res://build_id.txt and shown in the lobby
# and at /status.json. It is what turns "it crashed" into "it crashed on 1ae53e54". Generated,
# never committed; running from source finds no file and reports "dev" instead.
# The semantic version beside it lives in project.godot (application/config/version).
# -dirty means the export included uncommitted work and the sha alone will not reproduce it.
BUILD_ID="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)" ]; then
    BUILD_ID="$BUILD_ID-dirty"
fi
echo "$BUILD_ID" > "$PROJECT_DIR/build_id.txt"
echo "Build id: $BUILD_ID"

# The lobby's default join address, res://default_server.txt. release.sh sets WW_SERVER_HOST from
# the gitignored release.env, so the server is named in the builds we ship but never in the source.
if [ -n "${WW_SERVER_HOST:-}" ]; then
    echo "$WW_SERVER_HOST" > "$PROJECT_DIR/default_server.txt"
    echo "Default server: $WW_SERVER_HOST"
else
    rm -f "$PROJECT_DIR/default_server.txt"
fi

# Client exports run WINDOWED, not --headless: the export-time shader baker needs a real
# rendering device, and under --headless it silently no-ops — no warning, no error, just an
# export with nothing baked. Baking is what keeps a first launch on a cold shader cache from
# stalling long enough for ENet to drop the join (15-21s unbaked vs 1.8-4.0s baked). It only
# has anything to bake on an RD renderer, so this is inert while rendering_method.pc is
# gl_compatibility. Grep the export output for "baking_shaders" to confirm it ran.
# Set WW_HEADLESS_EXPORT=1 to force headless anyway (CI or ssh with no display) — exports
# still succeed, they just ship no baked pipelines. The server export stays headless: it
# renders nothing, so there is nothing to bake.
CLIENT_EXPORT_ARGS=()
if [[ -n "${WW_HEADLESS_EXPORT:-}" ]]; then
    CLIENT_EXPORT_ARGS=(--headless)
fi

# Assert an export bundled every GDExtension for a platform, in its OPTIMIZED (template_release)
# form and never the debug one. --export-release already selects the .template_release. gdextension
# entry, so this guards against a missing lib silently shipping (or an entry repointed at a debug
# build, as we do temporarily when profiling).
#
# Missing is the dangerous case, because nothing about it is loud: the libs live BESIDE the binary,
# not inside the .pck, so a package that drops them still launches and still connects. It then
# falls back — stock SceneMultiplayer instead of goldnet (which replaces state replication, so no
# other players and none of their models ever appear), Godot Physics instead of hop, PVS off — and
# says so only in a push_warning nobody sees. That is exactly what the Linux and Windows zips
# shipped while they carried only the binary and the .pck.
#
# Args: <dir to search> <platform tag: macos|windows|linux> [find maxdepth, default 99].
# Client exports drop their libs right beside the binary, so a depth of 1 is enough for those;
# the macOS .app keeps them in Contents/Frameworks and needs the default.
verify_export_libs() {
    local dir="$1" plat="$2" depth="${3:-99}" lib
    for lib in libgoldsrc libhop-physics libgoldnet; do
        if find "$dir" -maxdepth "$depth" -iname "${lib}.${plat}.template_debug*" 2>/dev/null | grep -q .; then
            echo "Error: $dir bundled a DEBUG $lib ($plat) lib — release must ship template_release." >&2
            exit 1
        fi
        if ! find "$dir" -maxdepth "$depth" -iname "${lib}.${plat}.template_release*" 2>/dev/null | grep -q .; then
            echo "Error: $dir has no RELEASE $lib ($plat) lib — export did not bundle it." >&2
            exit 1
        fi
    done
}

# Zip a whole client export directory, contents at the archive root — the binary, the .pck and the
# GDExtension libs the export put beside it. Zipping a file list instead is what lost the libs.
# Args: <export dir> <zip basename>
zip_export_dir() {
    local dir="$1" zip_name="$2"
    rm -f "$BUILD_DIR/$zip_name"
    (cd "$dir" && zip -qr "$BUILD_DIR/$zip_name" .)
    echo "Zipped: $BUILD_DIR/$zip_name ($(du -sh "$BUILD_DIR/$zip_name" | cut -f1))"
}

# Clients used to export straight into build/, which left their libs loose at its root and had the
# two platforms overwrite each other's WizardWars.pck. Sweep that layout so nothing stale there can
# be mistaken for a current build.
rm -f "$BUILD_DIR/$APP_NAME.exe" "$BUILD_DIR/$APP_NAME.x86_64" "$BUILD_DIR/$APP_NAME.pck" \
      "$BUILD_DIR"/lib*.so "$BUILD_DIR"/lib*.dll

# ── macOS client ──────────────────────────────────────────────────────────────
echo ""
echo "=== Building macOS client ==="
rm -rf "$BUILD_DIR/$APP_NAME.app"
"$GODOT" ${CLIENT_EXPORT_ARGS[@]+"${CLIENT_EXPORT_ARGS[@]}"} --path "$PROJECT_DIR" --export-release "macOS" "$BUILD_DIR/$APP_NAME.app"
verify_export_libs "$BUILD_DIR/$APP_NAME.app" macos

# ── Re-sign the bundle ────────────────────────────────────────────────────────
# The preset exports with codesign/codesign=0, which leaves the export TEMPLATE's own Developer ID
# signature in place over a bundle Godot has since inserted the pck and the GDExtension dylibs
# into. The result does not verify ("code has no resources but signature indicates they must be
# present"), and macOS will not hold a permission grant — the microphone's, in our case — for a
# bundle whose code identity it cannot check: voice chat re-asked for the microphone on machines
# where the grant could not stick. An ad-hoc signature over the FINISHED bundle verifies and gives
# TCC a stable identifier to key that grant to.
#
# --deep because the inserted dylibs and frameworks are nested code the outer seal covers. Ad-hoc
# ("-") needs no Apple account, and its requirement is pinned to the build hash, so each released
# build asks once more. To stop that too, sign with a Developer ID instead: set
# codesign/codesign=2, codesign/identity and codesign/apple_team_id in the macOS preset, point
# codesign/entitlements/custom_file at macos.entitlements, and drop this block.
echo "Signing: $BUNDLE_ID (ad-hoc)"
codesign --force --deep --sign - \
    --identifier "$BUNDLE_ID" \
    --entitlements "$PROJECT_DIR/macos.entitlements" \
    "$BUILD_DIR/$APP_NAME.app"
# Verified rather than assumed: an unverifiable bundle is the bug this block exists to fix, and it
# fails quietly — the app still launches, it just cannot keep a permission.
codesign --verify --deep --strict "$BUILD_DIR/$APP_NAME.app"

echo "Built: $BUILD_DIR/$APP_NAME.app ($(du -sh "$BUILD_DIR/$APP_NAME.app" | cut -f1))"
if [[ "$BUILD_ZIP" == true ]]; then
    rm -f "$BUILD_DIR/$APP_NAME-mac.zip"
    (cd "$BUILD_DIR" && zip -qr "$APP_NAME-mac.zip" "$APP_NAME.app")
    echo "Zipped: $BUILD_DIR/$APP_NAME-mac.zip"
fi

# ── Windows client ────────────────────────────────────────────────────────────
if [[ "$BUILD_WINDOWS" == true ]]; then
    echo ""
    echo "=== Building Windows client ==="
    rm -rf "$WINDOWS_DIR"
    mkdir -p "$WINDOWS_DIR"
    "$GODOT" ${CLIENT_EXPORT_ARGS[@]+"${CLIENT_EXPORT_ARGS[@]}"} --path "$PROJECT_DIR" --export-release "Windows" "$WINDOWS_DIR/$APP_NAME.exe"
    verify_export_libs "$WINDOWS_DIR" windows 1
    echo "Built: $WINDOWS_DIR/ ($(du -sh "$WINDOWS_DIR" | cut -f1))"
    if [[ "$BUILD_ZIP" == true ]]; then
        zip_export_dir "$WINDOWS_DIR" "$APP_NAME-windows.zip"
    fi
fi

# ── Linux client ──────────────────────────────────────────────────────────────
if [[ "$BUILD_LINUX_CLIENT" == true ]]; then
    echo ""
    echo "=== Building Linux client ==="
    rm -rf "$LINUX_DIR"
    mkdir -p "$LINUX_DIR"
    "$GODOT" ${CLIENT_EXPORT_ARGS[@]+"${CLIENT_EXPORT_ARGS[@]}"} --path "$PROJECT_DIR" --export-release "Linux" "$LINUX_DIR/$APP_NAME.x86_64"
    chmod +x "$LINUX_DIR/$APP_NAME.x86_64"
    verify_export_libs "$LINUX_DIR" linux 1
    echo "Built: $LINUX_DIR/ ($(du -sh "$LINUX_DIR" | cut -f1))"
    if [[ "$BUILD_ZIP" == true ]]; then
        zip_export_dir "$LINUX_DIR" "$APP_NAME-linux.zip"
    fi
fi

# ── Linux server binary ───────────────────────────────────────────────────────
if [[ "$BUILD_LINUX_SERVER" == true ]]; then
    echo ""
    echo "=== Building Linux server binary ==="
    rm -rf "$SERVER_DIR"
    mkdir -p "$SERVER_DIR"
    "$GODOT" --headless --path "$PROJECT_DIR" --export-release "Linux Server" "$SERVER_DIR/$APP_NAME.x86_64"
    chmod +x "$SERVER_DIR/$APP_NAME.x86_64"
    verify_export_libs "$SERVER_DIR" linux
    echo "Built: $SERVER_DIR/$APP_NAME.x86_64 ($(du -sh "$SERVER_DIR/$APP_NAME.x86_64" | cut -f1))"
fi
