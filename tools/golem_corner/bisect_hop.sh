#!/usr/bin/env bash
# `git bisect run` test for extern/hop-godot, over the corner repro in ride.sh.
#
#   cd extern/hop-godot
#   git bisect start <bad> <good>
#   git bisect run ../../tools/golem_corner/bisect_hop.sh
#
# NO_CLEARANCE=1 strips 013606a's resting-gap floor wherever a candidate has it, which is
# how the SECOND cause was found once the first was known. Builds only the macOS arm64
# release slice, which is what the editor binary loads (see the .gdextension).
set -u
WW="$(cd "$(dirname "$0")/../.." && pwd)"
H="$WW/extern/hop-godot"
OUT="${OUT:-/tmp/golem_corner}"; mkdir -p "$OUT"
sha=$(git -C "$H" rev-parse --short HEAD)
git -C "$H" submodule update --init --recursive >/dev/null 2>&1
git -C "$H" checkout -- src/ 2>/dev/null
if [ "${NO_CLEARANCE:-0}" = 1 ]; then
    perl -0pi -e 's/\n\ttouch_eps = std::max\(touch_eps, \(float\)bsp_surface_clearance\);//' \
        "$H/src/hop_physics_server.cpp"
fi
cmake -S "$H" -B "$H/build-macos-arm64-release" -DCMAKE_BUILD_TYPE=Release \
    -DGODOTCPP_TARGET=template_release \
    -DCMAKE_TOOLCHAIN_FILE="$H/cmake/toolchain-macos-arm64.cmake" \
    > "$OUT/cfg_$sha.log" 2>&1 || exit 125   # 125 = untestable, bisect skips it
# Bounded: two full godot-cpp builds at once OOM-kill each other on this box.
cmake --build "$H/build-macos-arm64-release" --parallel 6 > "$OUT/build_$sha.log" 2>&1 || exit 125
git -C "$H" checkout -- src/
OUT="$OUT" "$WW/tools/golem_corner/ride.sh"
