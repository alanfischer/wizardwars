#!/usr/bin/env python3
"""Print every candidate hop's six-axis hull_push_out considers, and which wins.

Mirrors hull_inside_distance/hull_push_out in hop_bsp_traceable.h exactly, including
the `extent` the call site passes (the FULL box size per axis, not the half-extent).

Usage: tools/sixaxis.py <bsp> --classname func_golem_body --hull 3 --feet X Y Z
"""
import argparse
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from bsp_hull_oracle import (BSP, CONTENTS_SOLID, DIST_EPSILON, hull_sweep,
                             point_contents)

HULL_SIZES = {
    1: ((-16, -16, -36), (16, 16, 36)),
    2: ((-32, -32, -32), (32, 32, 32)),
    3: ((-16, -16, -18), (16, 16, 18)),
}
AXES = ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1))
NAMES = ("+x", "-x", "+y", "-y", "+z(up)", "-z(down)")


def inside_distance(bsp, root, p, d, limit):
    away = [p[i] + d[i] * limit for i in range(3)]
    if point_contents(bsp, root, away) == CONTENTS_SOLID:
        return -1.0, "away point is itself solid"
    tr = hull_sweep(bsp, root, away, p)
    if not tr["hit"]:
        return -1.0, "sweep back found no surface (allsolid=%s)" % tr["allsolid"]
    dist = limit * (1.0 - tr["fraction"]) - DIST_EPSILON
    return (dist if dist > 0.0 else 0.0), "fraction=%.5f" % tr["fraction"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bsp")
    ap.add_argument("--classname", default="func_golem_body")
    ap.add_argument("--hull", type=int, default=3, choices=(1, 2, 3))
    ap.add_argument("--feet", type=float, nargs=3, required=True,
                    metavar=("X", "Y", "Z"), help="body-local GoldSrc feet position")
    a = ap.parse_args()

    bsp = BSP(a.bsp)
    root = bsp.models[bsp.model_of(a.classname)]["headnode"][a.hull]
    mins, maxs = HULL_SIZES[a.hull]
    # The mover's box has its origin at the feet, so mins = (-16,-16,0): the trace
    # point is feet - HULL_SIZES.mins in z, i.e. feet + half the hull height.
    p = [a.feet[0], a.feet[1], a.feet[2] - mins[2]]
    extent = [maxs[i] - mins[i] for i in range(3)]

    print("hull %d  feet %s  trace point %s" % (a.hull, tuple(a.feet), tuple(p)))
    print("extent (full box size, as the call site passes it) = %s" % (tuple(extent),))
    print("point contents: %s\n" % (
        "SOLID" if point_contents(bsp, root, p) == CONTENTS_SOLID else "empty"))

    best, best_i = 0.0, -1
    for i, ax in enumerate(AXES):
        d, why = inside_distance(bsp, root, p, ax, extent[i // 2])
        if d >= 0.0 and (best_i < 0 or d < best):
            best, best_i = d, i
        print("  %-9s limit %5.1f -> %-9s  %s" % (
            NAMES[i], extent[i // 2], ("REJECT" if d < 0 else "%.4f" % d), why))
    print("\nwinner: %s  depth %.4f" % (
        NAMES[best_i] if best_i >= 0 else "(none — falls back to nearest leaf plane)",
        best))


main()
