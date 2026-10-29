#!/usr/bin/env python3
"""Re-map the grey cone under the life staff's chrome loops (models/hands/life.mdl).

The cone is a six-sided frustum the artist mapped with one planar projection from the front.
That put the emblem on a corner, folded across two faces, smeared one texel column across the
two faces parallel to the projection, and ran one corner (and the cap) into the black/wood
seam at u=52.

Here each face gets its own slice of the plate: the emblem centered on the face toward the
camera and on the one opposite, the four sides plain plate. Only s changes; t (and so the rim
bands) is untouched. The cone is three strips whose shared entries force UV continuity
across every edge, so the two seams this needs are hidden on plain faces' diagonals.

Usage: ww_life_staff_cone.py [--dry]
"""
import os
import struct
import sys

from mdl import Mdl

PATH = os.path.join(os.path.dirname(__file__), "..", "models", "hands", "life.mdl")
STAFF_MESH = 1

# Per strip: the (vertex, s, t) entries as shipped, and the new s for each.
STRIPS = [
    ([(321, 122, 0), (316, 122, 0), (290, 103, 51), (317, 87, 0), (288, 87, 51), (286, 70, 51)],
     [122, 113, 102, 71, 82, 64]),
    ([(290, 103, 51), (280, 103, 51), (321, 122, 0), (281, 87, 51), (318, 87, 0), (319, 52, 0)],
     [76, 64, 58, 82, 71, 113]),
    ([(317, 87, 0), (320, 52, 0), (286, 70, 51), (319, 52, 0), (284, 70, 51), (281, 87, 51)],
     [110, 122, 112, 113, 102, 82]),
    # The cap: same planar slice, moved off the black column into plain plate.
    ([(316, 64, 41), (318, 53, 33), (317, 68, 33), (319, 56, 26), (320, 64, 26)],
     [70, 59, 74, 62, 70]),
    ([(321, 56, 41), (318, 53, 33), (316, 64, 41)],
     [62, 59, 70]),
]


def strips(m, mesh):
    o = mesh["triindex"]
    while True:
        cmd = struct.unpack_from("<h", m.data, o)[0]
        o += 2
        if cmd == 0:
            return
        yield o, [struct.unpack_from("<4h", m.data, o + 8 * k) for k in range(abs(cmd))]
        o += 8 * abs(cmd)


def main():
    m = Mdl(PATH)
    mesh = m.meshes(m.bodyparts[0]["models"][0])[STAFF_MESH]
    found = {}
    for o, run in strips(m, mesh):
        key = [(vi, s, t) for vi, _ni, s, t in run]
        for i, (old, new) in enumerate(STRIPS):
            if key == old:
                found[i] = o
            elif [(vi, t) for vi, _s, t in key] == [(vi, t) for vi, _s, t in old] and \
                    [s for _vi, s, _t in key] == new:
                sys.exit("already patched")
    if len(found) != len(STRIPS):
        sys.exit("cone strips not found; model changed?")
    for i, o in found.items():
        for k, s in enumerate(STRIPS[i][1]):
            struct.pack_into("<h", m.data, o + 8 * k + 4, s)
    if "--dry" not in sys.argv:
        m.save()
    print("patched %d strips" % len(found))


if __name__ == "__main__":
    main()
