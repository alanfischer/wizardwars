#!/usr/bin/env bash
set -euo pipefail

# Delete all converted/cached GoldSrc resources (maps, models, sprites, etc.)
# so they get rebuilt fresh on next run.

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERDATA_DIR="$HOME/Library/Application Support/Godot/app_userdata/Wizard Wars"

echo "=== Cleaning cached resources ==="

# 1. Runtime-cached maps (user://maps/)
MAP_DIR="$USERDATA_DIR/maps"
if [ -d "$MAP_DIR" ]; then
    count=$(ls -1 "$MAP_DIR" 2>/dev/null | wc -l | tr -d ' ')
    rm -rf "$MAP_DIR"
    echo "Deleted $MAP_DIR ($count files)"
else
    echo "No runtime map cache found"
fi

# 2. Pre-converted resources (user://resources/ — MDL, SPR, decals, sky, sounds)
RES_DIR="$USERDATA_DIR/resources"
if [ -d "$RES_DIR" ]; then
    count=$(find "$RES_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    rm -rf "$RES_DIR"
    echo "Deleted $RES_DIR ($count files)"
else
    echo "No pre-converted resources found"
fi

# 3. Godot editor import cache (.godot/imported/ — BSP, MDL, SPR, WAD imports)
IMPORT_DIR="$PROJECT_DIR/.godot/imported"
if [ -d "$IMPORT_DIR" ]; then
    # BSP → .scn
    bsp=$(find "$IMPORT_DIR" -name "*.bsp-*" 2>/dev/null | wc -l | tr -d ' ')
    # MDL → .scn
    mdl=$(find "$IMPORT_DIR" -name "*.mdl-*" 2>/dev/null | wc -l | tr -d ' ')
    # SPR → .tres
    spr=$(find "$IMPORT_DIR" -name "*.spr-*" 2>/dev/null | wc -l | tr -d ' ')
    # WAD → .tres + textures
    wad=$(find "$IMPORT_DIR" -name "*.wad-*" 2>/dev/null | wc -l | tr -d ' ')

    find "$IMPORT_DIR" -name "*.bsp-*" -delete
    find "$IMPORT_DIR" -name "*.mdl-*" -delete
    find "$IMPORT_DIR" -name "*.spr-*" -delete
    find "$IMPORT_DIR" -name "*.wad-*" -delete
    echo "Deleted editor imports: $bsp BSP, $mdl MDL, $spr SPR, $wad WAD files"
else
    echo "No editor import cache found"
fi

# 4. Shader cache (can cause stale material issues after BSP changes)
SHADER_DIR="$USERDATA_DIR/shader_cache"
if [ -d "$SHADER_DIR" ]; then
    count=$(find "$SHADER_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    rm -rf "$SHADER_DIR"
    echo "Deleted shader cache ($count files)"
else
    echo "No shader cache found"
fi

# 5. Packaged-build userdata (each build/<target>/ has its own self-contained
#    user:// at build/<target>/userdata/ — separate from the editor's userdata).
shopt -s nullglob
for build_userdata in "$PROJECT_DIR"/build/*/userdata; do
    for sub in maps resources shader_cache; do
        d="$build_userdata/$sub"
        if [ -d "$d" ]; then
            count=$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')
            rm -rf "$d"
            echo "Deleted $d ($count files)"
        fi
    done
done
shopt -u nullglob

echo ""
echo "Done. All caches cleared — resources will be rebuilt on next run."
