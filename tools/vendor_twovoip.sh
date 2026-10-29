#!/bin/bash
# Vendors the TwoVoIP GDExtension (github.com/goatchurchprime/two-voip-godot-4, MIT) into
# addons/twovoip at a release tag. TwoVoIP is Opus + RNNoise + jitter buffering behind the
# TwoVoipMic/TwoVoipSpeaker helper nodes; VoiceChat (src/systems/voice_chat.gd) drives it.
#
#   ./tools/vendor_twovoip.sh          re-vendor the pinned tag
#   ./tools/vendor_twovoip.sh v6.7     move to another release
#
# The release ships ~114 MB of libs for all six Godot platforms. We keep only what build.sh and
# deploy_quest.sh actually export, and strip the pruned platforms out of twovoip.gdextension so
# Godot never looks for a file that isn't there:
#
#   macos            debug + release   (universal; debug is what the editor loads)
#   android arm64    debug + release   (Quest; deploy_quest.sh defaults to a debug APK)
#   windows x86_64   release only
#   linux x86_64     release only
#
# Windows/Linux debug libs are dropped because nobody runs the editor on those here. Add
# 'windows.x86_64' / 'linux.x86_64' to KEEP_KEYS below to get them back.
set -euo pipefail

TAG="${1:-v6.6}"
REPO="goatchurchprime/two-voip-godot-4"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$PROJECT_DIR/addons/twovoip"

# .gdextension keys to keep, in both [dependencies] and [libraries].
KEEP_KEYS='^(macos|macos\.template_release|android\.(template_(debug|release)\.)?arm64|windows\.template_release\.x86_64|linux\.template_release\.x86_64)$'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "=== TwoVoIP $TAG ==="
url="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$TAG" \
    | grep -oE '"browser_download_url": "[^"]*TwoVoIP\.zip"' | sed 's/.*: "//;s/"$//')"
[ -n "$url" ] || { echo "No TwoVoIP.zip asset on $TAG" >&2; exit 1; }
echo "Downloading $url"
curl -fsSL -o "$work/TwoVoIP.zip" "$url"
unzip -q "$work/TwoVoIP.zip" 'project/addons/twovoip/*' -d "$work"
src="$work/project/addons/twovoip"
[ -d "$src" ] || { echo "Unexpected zip layout" >&2; exit 1; }

# Keep only the libs named by a surviving [libraries] key, so the prune list lives in one place.
keep_libs="$(awk -v keep="$KEEP_KEYS" '
    /^\[libraries\]/ { inlibs = 1; next }
    /^\[/           { inlibs = 0 }
    inlibs && /=/ {
        key = $1
        sub(/^[ \t]+/, "", key)
        if (key ~ keep) { path = $0; sub(/^[^"]*"/, "", path); sub(/".*$/, "", path); print path }
    }' "$src/twovoip.gdextension" | sed 's|^libs/||')"
[ -n "$keep_libs" ] || { echo "KEEP_KEYS matched no library" >&2; exit 1; }

mkdir -p "$work/pruned/libs"
while IFS= read -r lib; do
    # A macOS entry names the .framework directory, not the dylib inside it.
    cp -R "$src/libs/${lib%%/*}" "$work/pruned/libs/" 2>/dev/null \
        || { echo "Missing from release: $lib" >&2; exit 1; }
done <<< "$(echo "$keep_libs" | sed 's|\(\.framework\)/.*|\1|' | sort -u)"

# Drop the pruned platforms' entries; both sections key on the same platform strings.
awk -v keep="$KEEP_KEYS" '
    /^\[dependencies\]|^\[libraries\]/ { platforms = 1; print; next }
    /^\[/                                { platforms = 0; print; next }
    platforms && /^[a-z][a-z0-9._]* *=/ {
        key = $1
        if (key ~ keep) print
        next
    }
    { print }' "$src/twovoip.gdextension" > "$work/pruned/twovoip.gdextension"

cp "$src/twovoip.gdextension.uid" "$work/pruned/" 2>/dev/null || true
cp -R "$src/voiphelper" "$work/pruned/"   # TwoVoipMic / TwoVoipSpeaker, the API VoiceChat drives

# The helpers print a line per stream start, per stream end, per JSON marker received and per
# reordered or late frame — several lines into every player's log for each sentence anyone says,
# and more under packet loss, which is when the log matters most. Each print
# statement becomes a `pass` carrying the original as a comment: always valid GDScript, including
# where the print was the only statement in its block, and obvious when read. Drop this step to
# get TwoVoIP's own diagnostics back.
python3 - "$work/pruned/voiphelper" <<'QUIET'
import pathlib, re, sys
quieted = 0
for path in pathlib.Path(sys.argv[1]).glob("*.gd"):
    out = []
    for line in path.read_text().splitlines(keepends=True):
        m = re.match(r"^([ \t]*)(prints?\(.*)$", line)
        if m:
            out.append("%spass  # quieted by tools/vendor_twovoip.sh: %s\n" % (m.group(1), m.group(2).strip()))
            quieted += 1
        else:
            out.append(line)
    path.write_text("".join(out))
if quieted == 0:
    sys.exit("No print statements matched — check whether the helpers still have any")
print("Quieted %d helper print statements" % quieted)
QUIET
cp "$PROJECT_DIR/addons/twovoip/LICENSE" "$work/pruned/" 2>/dev/null || \
    curl -fsSL -o "$work/pruned/LICENSE" "https://raw.githubusercontent.com/$REPO/$TAG/LICENSE"
echo "$TAG" > "$work/pruned/VENDORED_TAG"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$work/pruned/." "$DEST/"
echo
echo "Vendored into addons/twovoip ($(du -sh "$DEST" | cut -f1)):"
(cd "$DEST" && ls libs)
