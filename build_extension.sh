#!/usr/bin/env bash
set -euo pipefail
# Build every GDExtension the game uses. Thin wrapper over each extension's own
# build.sh (which own all the per-platform CMake/Zig logic). Use this to rebuild
# all extensions manually (e.g. after a godot-cpp bump); release.sh rebuilds only
# the changed extensions on its own.
#
# Usage:
#   ./build_extension.sh                  # all extensions, default platforms
#   ./build_extension.sh macos            # all extensions, only these platform(s)
#   ./build_extension.sh linux windows

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

EXTENSIONS=(
    "$PROJECT_DIR/extern/goldsrc-godot/build.sh"
    "$PROJECT_DIR/extern/hop-godot/build.sh"
    "$PROJECT_DIR/extern/goldnet-godot/build.sh"
)

for build in "${EXTENSIONS[@]}"; do
    echo ""
    echo "======================================================================"
    echo "== $(basename "$(dirname "$build")")"
    echo "======================================================================"
    bash "$build" "$@"
done

echo ""
echo "=== All extensions built ==="
