#!/usr/bin/env python3
"""Pose a GoldSrc model and write it as a binary STL for 3D printing.

  mdl_stl.py MODEL [-o OUT.stl] [options]
  mdl_stl.py MODEL --list            sequences, bodyparts and size

  --seq NAME|INDEX    sequence to pose from (default: idle if the model has one, else rest)
  --frame N           frame of that sequence (default 0)
  --blend N           blend of a two-blend aim sequence (0 looks down, 1 up; default 0)
  --rest              the bind pose, ignoring --seq
  --body PART=SUB     submodel to use per bodypart, by index (default 0 for every part)
  --attach MDL        bone-merge another model onto this one, as the game draws a staff
                      (models/staves/*.mdl) on a player; may repeat
  --scale MM          millimetres per game unit (default 1: a player stands ~72 mm)
  --height MM         scale so the model stands this tall instead
  --base [MM]         add a round base of this diameter under the feet (default: fit footprint)

The model is set down on z=0 and centred in x/y, Z up. GoldSrc winds faces against their
normal, so every triangle is flipped; the signed volume is checked afterwards and the whole
mesh flipped back if it came out inside-out. Open edges are counted and reported: game meshes
are often not closed, and slicers repair small holes but not missing surfaces.
"""
import argparse
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mdl  # noqa: E402


def pose(m, args):
    if args.rest:
        return m.rest_world(), "rest"
    seqs = m.sequences()
    seq = None
    if args.seq is None:
        seq = next((s for s in seqs if s["label"] == "idle"), None)
        if seq is None:
            return m.rest_world(), "rest"
    elif args.seq.isdigit():
        seq = seqs[int(args.seq)]
    else:
        seq = next((s for s in seqs if s["label"] == args.seq), None)
        if seq is None:
            sys.exit("no sequence %r in %s (see --list)" % (args.seq, m.path))
    if seq["seqgroup"] != 0:
        sys.exit("sequence %s lives in an external seqgroup file; not supported" % seq["label"])
    blend = min(args.blend, seq["numblends"] - 1)
    seq = dict(seq, animindex=seq["animindex"] + blend * m.numbones * 12)
    frame = min(args.frame, seq["numframes"] - 1)
    pos, rot = m.frames(seq)
    return m.bone_world(pos[frame], rot[frame]), "%s frame %d blend %d" % (seq["label"], frame, blend)


def merged_world(att, host, host_world):
    """HL's bone merge: a bone named like one of the host's takes the host's transform; the
    rest hang off their parent at their own rest offset."""
    by_name = {b["name"]: i for i, b in enumerate(host.bones)}
    world = [None] * att.numbones
    for b in att.bones:
        i = b["index"]
        if b["name"] in by_name:
            world[i] = host_world[by_name[b["name"]]]
            continue
        local = (mdl._mat_from_euler(*b["value"][3:]), tuple(b["value"][:3]))
        if b["parent"] < 0:
            world[i] = local
        else:
            p = world[b["parent"]]
            world[i] = (mdl.mat_mul(p[0], local[0]), mdl.xform(p, local[1]))
    return world


def triangles(m, world, body):
    out = []
    for bi, bp in enumerate(m.bodyparts):
        sub = body.get(bi, 0)
        if sub >= len(bp["models"]):
            sys.exit("bodypart %d (%s) has no submodel %d" % (bi, bp["name"], sub))
        sm = bp["models"][sub]
        if sm["numverts"] == 0:
            continue
        bones = m.vert_bone(sm)
        verts = [mdl.xform(world[bones[i]], v) for i, v in enumerate(m.verts(sm))]
        for mesh in m.meshes(sm):
            for a, b, c in m.tris(mesh):
                out.append((verts[a[0]], verts[c[0]], verts[b[0]]))
    return out


def cylinder(cx, cy, z0, z1, r, n=96):
    ring = [(cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n))
            for i in range(n)]
    out = []
    for i in range(n):
        (x0, y0), (x1, y1) = ring[i], ring[(i + 1) % n]
        out.append(((cx, cy, z1), (x0, y0, z1), (x1, y1, z1)))
        out.append(((cx, cy, z0), (x1, y1, z0), (x0, y0, z0)))
        out.append(((x0, y0, z0), (x1, y1, z0), (x1, y1, z1)))
        out.append(((x0, y0, z0), (x1, y1, z1), (x0, y0, z1)))
    return out


def signed_volume(tris):
    return sum(a[0] * (b[1] * c[2] - b[2] * c[1]) + a[1] * (b[2] * c[0] - b[0] * c[2])
               + a[2] * (b[0] * c[1] - b[1] * c[0]) for a, b, c in tris) / 6.0


def open_edges(tris):
    key = lambda p: tuple(round(x, 4) for x in p)  # noqa: E731
    count = {}
    for t in tris:
        k = [key(p) for p in t]
        for i in range(3):
            e = (k[i], k[(i + 1) % 3])
            count[e] = count.get(e, 0) + 1
    return sum(1 for (a, b), n in count.items() if count.get((b, a), 0) != n)


def normal(a, b, c):
    u = [b[i] - a[i] for i in range(3)]
    v = [c[i] - a[i] for i in range(3)]
    n = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
    length = math.sqrt(sum(x * x for x in n)) or 1.0
    return tuple(x / length for x in n)


def write_stl(path, name, tris):
    with open(path, "wb") as f:
        f.write(name.encode("latin1")[:80].ljust(80, b"\0"))
        f.write(struct.pack("<I", len(tris)))
        for t in tris:
            f.write(struct.pack("<12fH", *normal(*t), *t[0], *t[1], *t[2], 0))


def bounds(tris):
    pts = [p for t in tris for p in t]
    return ([min(p[i] for p in pts) for i in range(3)], [max(p[i] for p in pts) for i in range(3)])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("model")
    ap.add_argument("-o", "--out")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--seq")
    ap.add_argument("--frame", type=int, default=0)
    ap.add_argument("--blend", type=int, default=0)
    ap.add_argument("--rest", action="store_true")
    ap.add_argument("--body", action="append", default=[])
    ap.add_argument("--attach", action="append", default=[])
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--height", type=float)
    ap.add_argument("--base", nargs="?", type=float, const=0.0)
    args = ap.parse_args()

    m = mdl.Mdl(args.model)
    if args.list:
        for bi, bp in enumerate(m.bodyparts):
            print("bodypart %d %s: %s" % (bi, bp["name"], ", ".join(
                "%d=%s" % (i, sm["name"]) for i, sm in enumerate(bp["models"]))))
        for s in m.sequences():
            print("seq %3d %-32s %3d frames%s" % (s["index"], s["label"], s["numframes"],
                                                 ", %d blends" % s["numblends"] if s["numblends"] > 1 else ""))
        return

    body = {}
    for spec in args.body:
        part, sub = spec.split("=")
        body[int(part)] = int(sub)
    world, what = pose(m, args)
    tris = triangles(m, world, body)
    for path in args.attach:
        att = mdl.Mdl(path)
        tris += triangles(att, merged_world(att, m, world), {})
    if not tris:
        sys.exit("%s has no geometry in that body selection" % args.model)

    lo, hi = bounds(tris)
    cx, cy = (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2
    scale = args.height / (hi[2] - lo[2]) if args.height else args.scale
    tris = [tuple(((p[0] - cx) * scale, (p[1] - cy) * scale, (p[2] - lo[2]) * scale) for p in t)
            for t in tris]
    if signed_volume(tris) < 0:
        tris = [(a, c, b) for a, b, c in tris]
    holes = open_edges(tris)

    if args.base is not None:
        lo, hi = bounds(tris)
        feet = [p for t in tris for p in t if p[2] < (hi[2] - lo[2]) * 0.05]
        radius = args.base / 2 if args.base else max(math.hypot(p[0], p[1]) for p in feet) + 3.0
        thick = max(2.0, radius * 0.12)
        tris = [tuple((p[0], p[1], p[2] + thick - 0.5) for p in t) for t in tris]
        tris += cylinder(0.0, 0.0, 0.0, thick, radius)

    out = args.out or os.path.splitext(os.path.basename(args.model))[0] + ".stl"
    write_stl(out, "%s %s" % (os.path.basename(args.model), what), tris)
    lo, hi = bounds(tris)
    print("%s: %s, %d triangles, %.1f x %.1f x %.1f mm, %d open edges" % (
        out, what, len(tris), hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2], holes))


if __name__ == "__main__":
    main()
