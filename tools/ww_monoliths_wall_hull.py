#!/usr/bin/env python3
"""Patch ww_monoliths' clip hulls so the red room's west wall stops a player at its face.

The wall at goldsrc x=3264, y -1056..-704, z 0..352 (Godot x=-81.6, z -26.4..-17.6) draws
and traces correctly in hull 0, but eight of its faces name plane 9990 (x=3248) instead of
9962 (x=3264), and the compiler expanded the clip hulls from that plane. So hulls 1-3 put
the wall 16 units back from where it is drawn and a player sinks 0.4 m into it. The
original game shipped with the same indent; the clipnodes are untouched since import.

hull 0 is solid through the whole slab x 3248..3264 over that y/z range, so the right
answer in hull h is the slab grown by that hull's half-extents. The patch puts a box test
in front of each clip hull's head node: inside the box is SOLID, outside falls through
to the original tree.

    python3 tools/ww_monoliths_wall_hull.py           # dry run
    python3 tools/ww_monoliths_wall_hull.py --apply
"""

import argparse
import os

from bsp import Bsp, CONTENTS_SOLID

BSP = os.path.join(os.path.dirname(__file__), "..", "maps", "ww_monoliths.bsp")

SLAB_MINS = (3248.0, -1056.0, 0.0)
SLAB_MAXS = (3264.0, -704.0, 352.0)

HULL_HALF = {1: (16, 16, 36), 2: (32, 32, 32), 3: (16, 16, 18)}

# A point that is inside the indent in hull 1 before the patch, and solid after.
PROBE = (3272.0, -950.0, 36.0)


def axial_plane(bsp, axis, dist):
    for i, p in enumerate(bsp.planes):
        if p[4] == axis and p[3] == dist and p[axis] == 1.0:
            return i
    n = [0.0, 0.0, 0.0]
    n[axis] = 1.0
    bsp.planes.append(n + [dist, axis])
    return len(bsp.planes) - 1


def box_guard(bsp, mins, maxs, outside):
    """Clipnode chain: SOLID inside [mins, maxs], `outside` everywhere else."""
    inside = CONTENTS_SOLID
    for axis in (2, 1, 0):
        hi = axial_plane(bsp, axis, maxs[axis])
        bsp.clipnodes.append([hi, outside, inside])
        inside = len(bsp.clipnodes) - 1
        lo = axial_plane(bsp, axis, mins[axis])
        bsp.clipnodes.append([lo, inside, outside])
        inside = len(bsp.clipnodes) - 1
    return inside


def hull_contents(bsp, head, p):
    n = head
    while n >= 0:
        cn = bsp.clipnodes[n]
        pl = bsp.planes[cn[0]]
        d = pl[0] * p[0] + pl[1] * p[1] + pl[2] * p[2] - pl[3]
        n = cn[1] if d >= 0 else cn[2]
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bsp", default=BSP)
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    bsp = Bsp(a.bsp)
    model = bsp.models[0]
    if hull_contents(bsp, model[10], PROBE) == CONTENTS_SOLID:
        print("already patched: hull 1 is solid at %s" % (PROBE,))
        return
    for h, half in HULL_HALF.items():
        mins = tuple(SLAB_MINS[i] - half[i] for i in range(3))
        maxs = tuple(SLAB_MAXS[i] + half[i] for i in range(3))
        old = model[9 + h]
        model[9 + h] = box_guard(bsp, mins, maxs, old)
        print("hull %d: head %d -> %d, solid box %s..%s" % (h, old, model[9 + h], mins, maxs))
    if len(bsp.clipnodes) > 32767:
        raise SystemExit("clipnode children are int16; %d nodes will not fit" % len(bsp.clipnodes))
    bsp.save_repack(dry=not a.apply)


if __name__ == "__main__":
    main()
