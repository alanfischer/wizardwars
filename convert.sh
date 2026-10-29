#!/usr/bin/env bash
set -euo pipefail

# Convert all GoldSrc resources (BSP maps, MDL models, SPR sprites, WAD textures,
# skyboxes, sounds) to native Godot formats. Requires the BSP plugin to be built.
#
# Output: ~/Library/Application Support/Godot/app_userdata/Wizard Wars/
#   maps/       BSP → .scn
#   resources/  MDL/SPR/WAD/sky/sounds
#
# Usage:
#   ./convert.sh                    Skip already cached
#   ./convert.sh --force            Force reconvert all
#   ./convert.sh --maps-only        Only convert BSP maps
#   ./convert.sh --resources-only   Only convert models/sprites/etc.

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

if command -v godot &>/dev/null; then
    GODOT=godot
elif [ -x "$HOME/Applications/Godot.app/Contents/MacOS/Godot" ]; then
    GODOT="$HOME/Applications/Godot.app/Contents/MacOS/Godot"
elif [ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]; then
    GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
else
    echo "Error: Godot not found." >&2; exit 1
fi

echo "Using Godot: $GODOT"
"$GODOT" --headless --path "$PROJECT_DIR" --script res://tools/convert_all.gd -- "$@"
