#!/usr/bin/env python3
"""Pose a GoldSrc model and write it for 3D printing: a binary STL, or a textured OBJ.

  mdl_print.py MODEL [-o OUT.stl|OUT.obj] [options]
  mdl_print.py MODEL --list           sequences, bodyparts and skins

  --seq NAME|INDEX    sequence to pose from (default: idle if the model has one, else rest)
  --frame N           frame of that sequence (default 0)
  --pitch DEG         where an aim sequence looks, blended between its two poses as the game
                      does: 0 is level, +45 fully up, -45 fully down (default 0)
  --rest              the bind pose, ignoring --seq
  --body PART=SUB     submodel to use per bodypart, by index (default 0 for every part)
  --skin N            skin family; on the player models 0 is the plain skin, then blue, red,
                      yellow and green (default 0)
  --attach MDL        bone-merge another model onto this one, as the game draws a staff
                      (models/staves/*.mdl) on a player; may repeat
  --scale MM          millimetres per game unit (default 1: a player stands ~72 mm)
  --height MM         scale so the model stands this tall instead
  --base [MM]         add a round base of this diameter under the feet (default: fit footprint)

The format follows the output's extension (default MODEL.stl). An OBJ comes with an .mtl and
one PNG per skin texture beside it, each material also carrying the texture's average colour
as Kd for slicers that read colours but not textures.

The model is set down on z=0 with its feet centred on the origin, Z up. GoldSrc winds faces against their
normal, so every triangle is flipped; the signed volume is checked afterwards and the whole
mesh flipped back if it came out inside-out. Open edges are counted and reported: game meshes
are often not closed, and slicers repair small holes but not missing surfaces.
"""
import argparse
import math
import os
import re
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mdl  # noqa: E402

BASE_COLOUR = (0.35, 0.35, 0.35)


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
    frame = min(args.frame, seq["numframes"] - 1)
    pos, rot = m.frames(seq)
    pos, rot = pos[frame], rot[frame]
    what = "%s frame %d" % (seq["label"], frame)
    if seq["numblends"] > 1:
        o = m.seqindex + seq["index"] * 176
        start, end = struct.unpack_from("<f", m.data, o + 136)[0], struct.unpack_from("<f", m.data, o + 144)[0]
        t = min(1.0, max(0.0, (args.pitch - start) / (end - start)))
        pos1, rot1 = m.frames(dict(seq, animindex=seq["animindex"] + m.numbones * 12))
        pos = [[a + (b - a) * t for a, b in zip(p0, p1)] for p0, p1 in zip(pos, pos1[frame])]
        rot = [slerp(quat(*r0), quat(*r1), t) for r0, r1 in zip(rot, rot1[frame])]
        what += " pitch %g" % args.pitch
        return quat_world(m, pos, rot), what
    return m.bone_world(pos, rot), what


def quat(x, y, z):
    """GoldSrc XYZ euler -> (x, y, z, w), the HL SDK's AngleQuaternion."""
    cx, sx = math.cos(x * 0.5), math.sin(x * 0.5)
    cy, sy = math.cos(y * 0.5), math.sin(y * 0.5)
    cz, sz = math.cos(z * 0.5), math.sin(z * 0.5)
    return (sx * cy * cz - cx * sy * sz, cx * sy * cz + sx * cy * sz,
            cx * cy * sz - sx * sy * cz, cx * cy * cz + sx * sy * sz)


def slerp(p, q, t):
    """The HL SDK's QuaternionSlerp: shortest arc, linear when nearly aligned."""
    dot = sum(a * b for a, b in zip(p, q))
    if dot < 0:
        q, dot = tuple(-c for c in q), -dot
    if dot > 0.999999:
        out = tuple(a + (b - a) * t for a, b in zip(p, q))
    else:
        omega = math.acos(dot)
        sa, sb = math.sin((1 - t) * omega), math.sin(t * omega)
        out = tuple((a * sa + b * sb) / math.sin(omega) for a, b in zip(p, q))
    n = math.sqrt(sum(c * c for c in out))
    return tuple(c / n for c in out)


def quat_world(m, pos, rot):
    world = [None] * m.numbones
    for b in m.bones:
        x, y, z, w = rot[b["index"]]
        local = ((
            (1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)),
            (2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)),
            (2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)),
        ), tuple(pos[b["index"]]))
        if b["parent"] < 0:
            world[b["index"]] = local
        else:
            p = world[b["parent"]]
            world[b["index"]] = (mdl.mat_mul(p[0], local[0]), mdl.xform(p, local[1]))
    return world


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


def skin_table(m, family):
    """skinref -> texture index for one skin family."""
    numskinref, numfamilies, skinindex = struct.unpack_from("<3i", m.data, 192)
    family = min(family, numfamilies - 1)
    return struct.unpack_from("<%dh" % numskinref, m.data, skinindex + family * numskinref * 2)


def triangles(m, world, body, skin, materials):
    """Each triangle as (corners, uvs, material index), wound outward. Textures are added to
    `materials` as they are first used."""
    textures = m.textures()
    table = skin_table(m, skin)
    used = {}
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
            tex = table[mesh["skinref"]]
            if tex not in used:
                used[tex] = len(materials)
                materials.append(textures[tex])
            _name, _flags, w, h, _rgb = textures[tex]
            for a, b, c in m.tris(mesh):
                corners = (a, c, b)
                out.append((tuple(verts[k[0]] for k in corners),
                            tuple((k[2] / w, 1.0 - k[3] / h) for k in corners), used[tex]))
    return out


def cylinder(cx, cy, z0, z1, r, mat, n=96):
    ring = [(cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n))
            for i in range(n)]
    faces = []
    for i in range(n):
        (x0, y0), (x1, y1) = ring[i], ring[(i + 1) % n]
        faces.append(((cx, cy, z1), (x0, y0, z1), (x1, y1, z1)))
        faces.append(((cx, cy, z0), (x1, y1, z0), (x0, y0, z0)))
        faces.append(((x0, y0, z0), (x1, y1, z0), (x1, y1, z1)))
        faces.append(((x0, y0, z0), (x1, y1, z1), (x0, y0, z1)))
    return [(f, None, mat) for f in faces]


def signed_volume(tris):
    return sum(a[0] * (b[1] * c[2] - b[2] * c[1]) + a[1] * (b[2] * c[0] - b[0] * c[2])
               + a[2] * (b[0] * c[1] - b[1] * c[0]) for (a, b, c), _uv, _m in tris) / 6.0


def open_edges(tris):
    key = lambda p: tuple(round(x, 4) for x in p)  # noqa: E731
    count = {}
    for t, _uv, _m in tris:
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
        for t, _uv, _m in tris:
            f.write(struct.pack("<12fH", *normal(*t), *t[0], *t[1], *t[2], 0))


def write_png(path, w, h, rgb):
    raw = b"".join(b"\0" + bytes(rgb[y * w * 3:(y + 1) * w * 3]) for y in range(h))

    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def write_obj(path, name, tris, materials):
    stem = os.path.splitext(path)[0]
    folder, base = os.path.dirname(path), os.path.basename(stem)
    with open(stem + ".mtl", "w") as f:
        for i, mat in enumerate(materials):
            f.write("newmtl m%d\n" % i)
            if mat is None:
                f.write("Kd %.4f %.4f %.4f\n\n" % BASE_COLOUR)
                continue
            tex_name, _flags, w, h, rgb = mat
            png = "%s_%s.png" % (base, re.sub(r"[^A-Za-z0-9_-]", "_", os.path.splitext(tex_name)[0]))
            write_png(os.path.join(folder, png), w, h, rgb)
            n = w * h
            avg = [sum(rgb[c::3]) / (255.0 * n) for c in range(3)]
            f.write("Kd %.4f %.4f %.4f\nmap_Kd %s\n\n" % (*avg, png))
    verts, uvs = {}, {}
    lines = []

    def index(table, key):
        if key not in table:
            table[key] = len(table) + 1
        return table[key]

    current = None
    for corners, corner_uvs, mat in tris:
        if mat != current:
            lines.append("usemtl m%d" % mat)
            current = mat
        vi = [index(verts, p) for p in corners]
        if corner_uvs is None:
            lines.append("f %d %d %d" % tuple(vi))
        else:
            ti = [index(uvs, uv) for uv in corner_uvs]
            lines.append("f " + " ".join("%d/%d" % pair for pair in zip(vi, ti)))
    with open(path, "w") as f:
        f.write("# %s\nmtllib %s.mtl\n" % (name, base))
        f.writelines("v %.4f %.4f %.4f\n" % p for p in verts)
        f.writelines("vt %.6f %.6f\n" % uv for uv in uvs)
        f.write("\n".join(lines) + "\n")


def bounds(tris):
    pts = [p for t, _uv, _m in tris for p in t]
    return ([min(p[i] for p in pts) for i in range(3)], [max(p[i] for p in pts) for i in range(3)])


def moved(tris, fn):
    return [(tuple(fn(p) for p in t), uv, mat) for t, uv, mat in tris]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("model")
    ap.add_argument("-o", "--out")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--seq")
    ap.add_argument("--frame", type=int, default=0)
    ap.add_argument("--pitch", type=float, default=0.0)
    ap.add_argument("--rest", action="store_true")
    ap.add_argument("--body", action="append", default=[])
    ap.add_argument("--skin", type=int, default=0)
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
        numfamilies = struct.unpack_from("<i", m.data, 196)[0]
        textures = m.textures()
        for fam in range(numfamilies):
            print("skin %d: %s" % (fam, ", ".join(sorted({textures[t][0] for t in skin_table(m, fam)}))))
        for s in m.sequences():
            print("seq %3d %-32s %3d frames%s" % (s["index"], s["label"], s["numframes"],
                                                 ", %d blends" % s["numblends"] if s["numblends"] > 1 else ""))
        return

    body = {}
    for spec in args.body:
        part, sub = spec.split("=")
        body[int(part)] = int(sub)
    materials = []
    world, what = pose(m, args)
    tris = triangles(m, world, body, args.skin, materials)
    for path in args.attach:
        att = mdl.Mdl(path)
        tris += triangles(att, merged_world(att, m, world), {}, 0, materials)
    if not tris:
        sys.exit("%s has no geometry in that body selection" % args.model)

    lo, hi = bounds(tris)
    feet = [p for t, _uv, _m in tris for p in t if p[2] < lo[2] + (hi[2] - lo[2]) * 0.05]
    cx = (min(p[0] for p in feet) + max(p[0] for p in feet)) / 2
    cy = (min(p[1] for p in feet) + max(p[1] for p in feet)) / 2
    scale = args.height / (hi[2] - lo[2]) if args.height else args.scale
    tris = moved(tris, lambda p: ((p[0] - cx) * scale, (p[1] - cy) * scale, (p[2] - lo[2]) * scale))
    if signed_volume(tris) < 0:
        tris = [((a, c, b), uv and (uv[0], uv[2], uv[1]), mat) for (a, b, c), uv, mat in tris]
    holes = open_edges(tris)

    if args.base is not None:
        lo, hi = bounds(tris)
        feet = [p for t, _uv, _m in tris for p in t if p[2] < (hi[2] - lo[2]) * 0.05]
        radius = args.base / 2 if args.base else max(math.hypot(p[0], p[1]) for p in feet) + 3.0
        thick = max(2.0, radius * 0.12)
        tris = moved(tris, lambda p: (p[0], p[1], p[2] + thick - 0.5))
        tris += cylinder(0.0, 0.0, 0.0, thick, radius, len(materials))
        materials.append(None)

    out = args.out or os.path.splitext(os.path.basename(args.model))[0] + ".stl"
    name = "%s %s" % (os.path.basename(args.model), what)
    if out.lower().endswith(".obj"):
        write_obj(out, name, tris, materials)
    else:
        write_stl(out, name, tris)
    lo, hi = bounds(tris)
    print("%s: %s, %d triangles, %.1f x %.1f x %.1f mm, %d open edges" % (
        out, what, len(tris), hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2], holes))


if __name__ == "__main__":
    main()
