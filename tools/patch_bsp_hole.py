#!/usr/bin/env python3
"""Put back a world face the map compiler dropped.

hlbsp occasionally loses a face where two brushes meet at a shallow angle, leaving the
neighbours as zero-area slivers and a see-through hole in a wall. ww_chasm has one in the
rock above the blue side, at goldsrc (1775 -2062 211).

The hole is found from the BSP itself, not from eyeballed coordinates: a winding on the
face's plane is clipped down the world tree twice, once offset into the empty side and
once into the solid side, and their intersection is the surface that must be drawn there.
Subtracting the faces already on that plane leaves exactly what is missing. Every piece
comes out convex, which is what the renderer's triangle fan needs.

The patch faces borrow the texinfo of a neighbour on the same plane, so texture alignment
carries across the seam, and get a flat lightmap averaged from that neighbour — a face
with no lightmap renders fullbright, which on a dark rock wall is worse than the hole.

    python3 tools/patch_bsp_hole.py maps/ww_chasm.bsp --near 1775 -2062 211
    python3 tools/patch_bsp_hole.py maps/ww_chasm.bsp --near 1775 -2062 211 --apply

The one convention worth knowing before writing a face: GoldSrc winds a polygon AGAINST the
normal it renders with, and Godot culls by winding, so a face wound the intuitive way is
inserted, parsed, drawn nowhere, and looks exactly like the hole you set out to fix.

Check the result by eye — tools/map_shot.gd renders a map from a goldsrc viewpoint:

    MAP=ww_chasm TARGET="1753 -2052 233" EYE="1908 -2052 327" SHOT=/tmp/wall.png \
        Godot --path . --resolution 1280x720 --quit-after 3000 res://tools/map_shot.tscn

A hand-edited .bsp needs its scene rebuilt before any of this is visible:
`Godot --headless --path . --import` notices the changed source. A .bsp converted at runtime
instead (one dropped beside a dedicated server) caches on the converter's CACHE_VERSION.
"""

import argparse
import math
import struct

from bsp import Bsp, CONTENTS_EMPTY, CONTENTS_SOLID, dot

ON_EPSILON = 1e-4


def sub(a, b): return (a[0]-b[0], a[1]-b[1], a[2]-b[2])
def add(a, b): return (a[0]+b[0], a[1]+b[1], a[2]+b[2])
def mul(a, s): return (a[0]*s, a[1]*s, a[2]*s)
def cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def length(a): return math.sqrt(dot(a, a))


# --- windings ---------------------------------------------------------------

def split(poly, pn, pd):
    """Front (>= plane) and back halves of a winding; either may be None."""
    ds = [dot(p, pn) - pd for p in poly]
    if all(d > -ON_EPSILON for d in ds): return poly, None
    if all(d < ON_EPSILON for d in ds): return None, poly
    front, back = [], []
    for i, p in enumerate(poly):
        q = poly[(i + 1) % len(poly)]
        dp, dq = ds[i], ds[(i + 1) % len(poly)]
        if dp >= -ON_EPSILON: front.append(p)
        if dp <= ON_EPSILON: back.append(p)
        if (dp > ON_EPSILON and dq < -ON_EPSILON) or (dp < -ON_EPSILON and dq > ON_EPSILON):
            m = add(p, mul(sub(q, p), dp / (dp - dq)))
            front.append(m); back.append(m)
    return (front if len(front) >= 3 else None), (back if len(back) >= 3 else None)


def clip_to_tree(bsp, poly, head):
    out, stack = [], [(poly, head)]
    while stack:
        w, n = stack.pop()
        if n < 0:
            out.append((w, bsp.leafs[~n][0]))
            continue
        nd = bsp.nodes[n]
        pl = bsp.planes[nd[0]]
        f, b = split(w, pl[:3], pl[3])
        if f: stack.append((f, nd[1]))
        if b: stack.append((b, nd[2]))
    return out


def area_normal(poly):
    a = (0.0, 0.0, 0.0)
    for i in range(1, len(poly) - 1):
        a = add(a, cross(sub(poly[i], poly[0]), sub(poly[i + 1], poly[0])))
    return a


def edge_planes(poly, n):
    """Outward planes of a convex winding, for clipping against it. A face wound against
    the plane normal (side 1, or simply the compiler's choice) would otherwise hand back
    inward planes, and every subtraction would come out inside out."""
    if dot(area_normal(poly), n) < 0:
        poly = list(reversed(poly))
    out = []
    for i, p in enumerate(poly):
        q = poly[(i + 1) % len(poly)]
        d = sub(q, p)
        if length(d) < 1e-6: continue
        pn = cross(d, n)
        l = length(pn)
        if l < 1e-6: continue
        pn = mul(pn, 1.0 / l)
        out.append((pn, dot(pn, p)))
    return out


def intersect(a, b, n):
    w = a
    for pn, pd in edge_planes(b, n):
        if w is None: return None
        _, w = split(w, pn, pd)
    return w


def subtract(a, b, n):
    """The parts of winding a outside convex winding b, as convex pieces."""
    out, rem = [], a
    for pn, pd in edge_planes(b, n):
        if rem is None: break
        f, rem = split(rem, pn, pd)
        if f: out.append(f)
    return out if rem is not None else [a]


def area(poly):
    return 0.5 * length(area_normal(poly))


def inradius(poly, n):
    """Rough thickness gauge: how far the winding's centre sits from its nearest edge."""
    c = mul([sum(p[k] for p in poly) for k in range(3)], 1.0 / len(poly))
    c = (c[0], c[1], c[2])
    return min(abs(dot(c, pn) - pd) for pn, pd in edge_planes(poly, n))


def centre(poly):
    return tuple(sum(p[k] for p in poly) / len(poly) for k in range(3))


# --- finding what is missing ------------------------------------------------

def coplanar_faces(bsp, planenum, model=0):
    pl = bsp.planes[planenum]
    m = bsp.models[model]
    out = []
    for i in range(m[14], m[14] + m[15]):
        q = bsp.planes[bsp.faces[i][0]]
        if dot(pl[:3], q[:3]) > 0.999 and abs(q[3] - pl[3]) <= 2.5:
            out.append(i)
    return out


def open_space(bsp, p, head, min_size=8.0):
    """True when the leaf at p is somewhere you could stand and look, not a sealed crack
    between two brushes. A hole only matters where there is room to see it from."""
    leaf = bsp.leafs[bsp.leaf_index(p, head)]
    return min(leaf[5 + k] - leaf[2 + k] for k in range(3)) >= min_size


def missing_pieces(bsp, planenum, near, radius=150.0, extent=400.0, offset=0.1,
                   min_area=4.0, min_width=0.75, model=0):
    """Surface on this plane that bounds solid but carries no face, as convex windings.

    Returns (winding, side) pairs: a wall faces whichever way the empty space is on, so both
    sides of the plane are searched. ww_chasm's hole is side 0.
    """
    pl = bsp.planes[planenum]
    n = pl[:3]
    up = (0, 0, 1) if abs(n[2]) < 0.9 else (1, 0, 0)
    u = cross(n, up); u = mul(u, 1.0 / length(u))
    v = cross(n, u)
    c = add(near, mul(n, pl[3] - dot(near, n)))
    quad = [add(add(c, mul(u, su * extent)), mul(v, sv * extent))
            for su, sv in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    head = bsp.models[model][9]

    def fragments(off, want):
        out = []
        for frag, contents in clip_to_tree(bsp, [add(p, mul(n, off)) for p in quad], head):
            if contents == want:
                out.append([sub(p, mul(n, off)) for p in frag])
        return out

    out = []
    for face_side in (0, 1):
        towards = offset if face_side == 0 else -offset
        surface = []
        for e in fragments(towards, CONTENTS_EMPTY):
            for s in fragments(-towards, CONTENTS_SOLID):
                w = intersect(e, s, n)
                if w and area(w) > min_area:
                    surface.append(w)
        pieces = surface
        for fi in coplanar_faces(bsp, planenum, model):
            if bsp.faces[fi][1] != face_side: continue
            fw = bsp.face_verts(fi)
            nxt = []
            for w in pieces:
                nxt.extend(p for p in subtract(w, fw, n) if area(p) > min_area * 0.25)
            pieces = nxt
        for w in pieces:
            if area(w) < min_area or inradius(w, n) < min_width: continue
            if length(sub(centre(w), near)) > radius: continue
            if not open_space(bsp, add(centre(w), mul(n, towards * 5)), head): continue
            out.append((w, face_side))
    return out


def candidate_planes(bsp, near, radius, model=0):
    """Planes carrying a face near the point — the walls a hole there could be in."""
    out = {}
    m = bsp.models[model]
    for i in range(m[14], m[14] + m[15]):
        vs = bsp.face_verts(i)
        if min(length(sub(v, near)) for v in vs) <= radius:
            out[bsp.faces[i][0]] = True
    return sorted(out)


# --- building the patch -----------------------------------------------------

def lightmap_size(bsp, poly, texinfo):
    ti = bsp.texinfo[texinfo]
    ss = [dot(p, ti[0:3]) + ti[3] for p in poly]
    ts = [dot(p, ti[4:7]) + ti[7] for p in poly]
    w = int(math.ceil(max(ss) / 16.0)) - int(math.floor(min(ss) / 16.0)) + 1
    h = int(math.ceil(max(ts) / 16.0)) - int(math.floor(min(ts) / 16.0)) + 1
    return w, h


def donor_light(bsp, fi):
    """Average colour of each of a face's lightmap style layers."""
    f = bsp.faces[fi]
    if f[9] < 0: return None
    w, h = lightmap_size(bsp, bsp.face_verts(fi), f[4])
    px = w * h
    out = []
    for s in range(4):
        if f[5 + s] == 255: break
        base = f[9] + s * px * 3
        if base + px * 3 > len(bsp.lighting): return None
        block = bsp.lighting[base:base + px * 3]
        out.append(tuple(sum(block[i::3]) // px for i in range(3)))
    return out


def vertex_index(bsp, p, cache):
    key = struct.pack("<3f", *p)
    if key in cache: return cache[key]
    bsp.verts.append(struct.unpack("<3f", key))
    cache[key] = len(bsp.verts) - 1
    return cache[key]


def add_faces(bsp, pieces, planenum, donor, model=0):
    """Insert patch faces after `donor`, keeping every face index in the file honest."""
    n = bsp.planes[planenum][:3]
    df = bsp.faces[donor]
    styles = list(df[5:9])
    light = donor_light(bsp, donor)
    node = next(i for i, nd in enumerate(bsp.nodes) if nd[9] <= donor < nd[9] + nd[10])
    at = bsp.nodes[node][9] + bsp.nodes[node][10]
    head = bsp.models[model][9]

    cache = {struct.pack("<3f", *v): i for i, v in enumerate(bsp.verts)}
    new_faces, leaf_for = [], []
    for w, face_side in pieces:
        # GoldSrc winds a face against the normal it renders with — every face in a stock map
        # has area_normal . facing < 0 — and the renderer culls by winding, so a patch wound
        # the intuitive way is inserted, parsed, and then never drawn.
        facing = mul(n, -1.0) if face_side else n
        poly = w if dot(area_normal(w), facing) < 0 else list(reversed(w))
        firstedge = len(bsp.surfedges)
        for i, p in enumerate(poly):
            q = poly[(i + 1) % len(poly)]
            bsp.edges.append((vertex_index(bsp, p, cache), vertex_index(bsp, q, cache)))
            bsp.surfedges.append(len(bsp.edges) - 1)
        lightofs = -1
        if light:
            lw, lh = lightmap_size(bsp, poly, df[4])
            lightofs = len(bsp.lighting)
            for colour in light:
                bsp.lighting += bytes(colour) * (lw * lh)
        new_faces.append([planenum, face_side, firstedge, len(poly), df[4],
                          styles[0], styles[1], styles[2], styles[3], lightofs])
        leaf_for.append(bsp.leaf_index(add(centre(poly), mul(facing, 0.5)), head))

    count = len(new_faces)
    bsp.faces[at:at] = new_faces
    bsp.nodes[node][10] += count
    for nd in bsp.nodes:
        if nd[9] >= at and not (nd[9] == at and nd is bsp.nodes[node]):
            nd[9] += count
    for m in bsp.models:
        if m[14] > at: m[14] += count
        elif m[14] <= at < m[14] + m[15]: m[15] += count
    bsp.marks = [m + count if m >= at else m for m in bsp.marks]

    # Leaves list the faces they can see; GoldSrc itself draws nothing that is in no leaf.
    for i, leaf in enumerate(leaf_for):
        pos = bsp.leafs[leaf][8] + bsp.leafs[leaf][9]
        bsp.marks.insert(pos, at + i)
        bsp.leafs[leaf][9] += 1
        for l in bsp.leafs:
            if l[8] > pos: l[8] += 1
    return at, count


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bsp")
    ap.add_argument("--near", nargs=3, type=float, required=True, metavar=("X", "Y", "Z"))
    ap.add_argument("--plane", type=int, default=-1, help="plane index (default: the nearest face's)")
    ap.add_argument("--radius", type=float, default=150.0)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    bsp = Bsp(args.bsp)
    near = tuple(args.near)
    if args.plane >= 0:
        found = [(args.plane, missing_pieces(bsp, args.plane, near, radius=args.radius))]
    else:
        # Two brushes meeting at a shallow angle leave near-coincident planes, and the hole
        # belongs to whichever of them lost the most surface: patch that one and the wedge
        # behind it is covered too.
        found = [(pn, missing_pieces(bsp, pn, near, radius=args.radius))
                 for pn in candidate_planes(bsp, near, args.radius)]
        found = sorted((f for f in found if f[1]),
                       key=lambda f: -sum(area(w) for w, _ in f[1]))
        for pn, ps in found[1:]:
            print("also missing on plane %d: %.1f square units (not patched)"
                  % (pn, sum(area(w) for w, _ in ps)))
        found = found[:1]
    if not found or not found[0][1]:
        print("no missing surface found near (%.0f %.0f %.0f)" % near)
        return
    planenum, pieces = found[0]
    pl = bsp.planes[planenum]
    print("%s: plane %d n=(%.3f %.3f %.3f) d=%.2f" % (args.bsp, planenum, pl[0], pl[1], pl[2], pl[3]))
    total = sum(area(w) for w, _ in pieces)
    print("%d missing piece(s), %.1f square units:" % (len(pieces), total))
    for w, face_side in pieces:
        print("   area %8.1f  centre (%.1f %.1f %.1f)  %d verts  side %d"
              % (area(w), *centre(w), len(w), face_side))
    if not args.apply:
        print("(dry run — pass --apply to write)")
        return

    # The donor must sit on this exact plane, not merely a near-coincident one: its node is
    # where the patch faces go, and GoldSrc hangs a face off the node carrying its own plane.
    donor = max((i for i in coplanar_faces(bsp, planenum) if bsp.faces[i][0] == planenum),
                key=lambda i: area(bsp.face_verts(i)) if bsp.faces[i][9] >= 0 else -1)
    at, count = add_faces(bsp, pieces, planenum, donor)
    out = args.out or args.bsp
    bsp.save_repack(out)
    print("inserted %d faces at index %d (texinfo/lightmap donor f%d) -> %s" % (count, at, donor, out))


if __name__ == "__main__":
    main()
