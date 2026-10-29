#!/usr/bin/env python3
"""An independent oracle for hop's GoldSrc hull trace, read straight off the .bsp.

hop's BSP traceable is the only thing in the engine that can answer "is this point
inside the hull", so a bug in it has nothing to check it against. This is a second
implementation of the same three primitives — hull_point_contents, SV_RecursiveHullCheck
and hull_push_out — in Python, over the raw map file, so hop's answers can be
disagreed with. It has no dependencies and never loads Godot.

Deliberately does NOT use tools/bsp.py: a second opinion that shares its parsing with the
thing it is checking is not a second opinion. Leave the duplication here alone.

Coordinates are the brush model's own GoldSrc frame (Z-up, inches), which for a brush
entity is what you get from the entity node's inverse transform:
    local = node.global_transform.affine_inverse() * world
    gs    = Vector3(-local.x / 0.025, local.z / 0.025, local.y / 0.025)

A standing player traces hull 1 as a POINT at (feet + 36) in that frame; a crouched
one traces hull 3 at (feet + 18). See HULL_SIZES.

    python3 tools/bsp_hull_oracle.py maps/ww_golem.bsp --model 41 --point -24 0 -76
    python3 tools/bsp_hull_oracle.py maps/ww_golem.bsp --model 41 --span -56 -84 -93
    python3 tools/bsp_hull_oracle.py maps/ww_golem.bsp --model 41 --poses /tmp/poses.txt
    python3 tools/bsp_hull_oracle.py maps/ww_golem.bsp --model 41 --survey
"""

import argparse
import random
import re
import struct

LUMP_ENTITIES, LUMP_PLANES = 0, 1
LUMP_NODES, LUMP_CLIPNODES, LUMP_LEAFS, LUMP_MODELS = 5, 9, 10, 14

CONTENTS_EMPTY, CONTENTS_SOLID = -1, -2
DIST_EPSILON = 0.03125

# The engine-baked expansions. A mover is reduced to the point the hull was built
# around, so the trace point is (origin + mins - HULL_SIZES[h].mins).
HULL_SIZES = {
    0: ((0, 0, 0), (0, 0, 0)),
    1: ((-16, -16, -36), (16, 16, 36)),
    2: ((-32, -32, -32), (32, 32, 32)),
    3: ((-16, -16, -18), (16, 16, 18)),
}


class BSP:
    def __init__(self, path):
        d = open(path, "rb").read()
        self.d = d
        (ver,) = struct.unpack_from("<i", d, 0)
        if ver not in (29, 30):
            raise ValueError("not a Quake/GoldSrc BSP (version %d)" % ver)
        self.lumps = [struct.unpack_from("<ii", d, 4 + 8 * i) for i in range(15)]
        self.ents = self._ents()
        self.planes = self._planes()
        self.clipnodes = self._clipnodes()
        self.models = self._models()

    def _lump(self, i):
        o, l = self.lumps[i]
        return self.d[o:o + l]

    def _ents(self):
        txt = self._lump(LUMP_ENTITIES).split(b"\0")[0].decode("latin-1")
        return [dict(re.findall(r'"([^"]*)"\s+"([^"]*)"', blk))
                for blk in re.findall(r"\{(.*?)\}", txt, re.S)]

    def _planes(self):
        b = self._lump(LUMP_PLANES)
        return [struct.unpack_from("<ffffi", b, i * 20) for i in range(len(b) // 20)]

    def _clipnodes(self):
        b = self._lump(LUMP_CLIPNODES)
        return [struct.unpack_from("<ihh", b, i * 8) for i in range(len(b) // 8)]

    def _models(self):
        b = self._lump(LUMP_MODELS)
        out = []
        for i in range(len(b) // 64):
            v = struct.unpack_from("<9f4ii", b, i * 64)
            out.append({"mins": v[0:3], "maxs": v[3:6], "origin": v[6:9], "headnode": v[9:13]})
        return out

    def model_of(self, classname):
        """Model index of the first brush entity with this classname ("*N" -> N)."""
        for e in self.ents:
            if e.get("classname") == classname and e.get("model", "").startswith("*"):
                return int(e["model"][1:])
        return None


def plane_dist(pl, p, margin=0.0):
    nx, ny, nz, dist, typ = pl
    d = p[typ] - dist if typ < 3 else nx * p[0] + ny * p[1] + nz * p[2] - dist
    return d - margin


def point_contents(bsp, num, p, margin=0.0):
    """Clipnode descent (hulls 1..3): a child < 0 IS the contents value."""
    while num >= 0:
        pl = bsp.planes[bsp.clipnodes[num][0]]
        d = plane_dist(pl, p, margin)
        num = bsp.clipnodes[num][1 + (1 if d < 0 else 0)]
    return num


def descent_planes(bsp, num, p, margin=0.0):
    """Every plane the descent to p's leaf crosses, as (|d|, planenum, outward_normal).

    Each one bounds the leaf, so the set is the leaf's faces — which is what makes
    "nearest bounding plane" a tempting, and wrong, depenetration direction.
    """
    out = []
    while num >= 0:
        pn = bsp.clipnodes[num][0]
        pl = bsp.planes[pn]
        d = plane_dist(pl, p, margin)
        s = 1.0 if d < 0 else -1.0
        out.append((abs(d), pn, [pl[0] * s, pl[1] * s, pl[2] * s]))
        num = bsp.clipnodes[num][1 + (1 if d < 0 else 0)]
    return out, num


def hull_push_out(bsp, root, p, margin=0.0):
    """hop's hull_push_out: the NEAREST bounding plane, as (normal, depth).

    None when p isn't in blocking contents. Note this is the buggy rule, reproduced
    faithfully — use escape_exits() to ask whether its answer actually gets you out.
    """
    cand, leaf = descent_planes(bsp, root, p, margin)
    if leaf != CONTENTS_SOLID or not cand:
        return None
    mag, _, n = min(cand, key=lambda c: c[0])
    return n, mag


def escape_exits(bsp, root, p, normal, depth, eps=0.05):
    """Does pushing p out along `normal` by `depth` actually leave the solid?"""
    esc = [p[i] + normal[i] * (depth + eps) for i in range(3)]
    return point_contents(bsp, root, esc) != CONTENTS_SOLID


def best_escape(bsp, root, p, margin=0.0):
    """The nearest bounding plane whose push-out ACTUALLY exits the solid.

    This is the proposed fix for hull_push_out, as an oracle: sort the leaf's faces
    by distance and take the first that leaves blocking contents.
    """
    cand, leaf = descent_planes(bsp, root, p, margin)
    if leaf != CONTENTS_SOLID:
        return None
    for mag, _, n in sorted(cand, key=lambda c: c[0]):
        if escape_exits(bsp, root, p, n, mag):
            return n, mag
    return None


def hull_sweep(bsp, root, p1, p2, margin=0.0):
    """Quake SV_RecursiveHullCheck. `allsolid` means the whole path was inside solid,
    in which case `hit` is False and the caller must NOT read that as a clear path."""
    tr = {"fraction": 1.0, "endpos": list(p2), "normal": [0, 0, 0],
          "allsolid": True, "hit": False}

    def rec(num, p1f, p2f, a, bb):
        if num < 0:
            if num != CONTENTS_SOLID:
                tr["allsolid"] = False
            return True
        pl = bsp.planes[bsp.clipnodes[num][0]]
        t1, t2 = plane_dist(pl, a, margin), plane_dist(pl, bb, margin)
        if t1 >= 0 and t2 >= 0:
            return rec(bsp.clipnodes[num][1], p1f, p2f, a, bb)
        if t1 < 0 and t2 < 0:
            return rec(bsp.clipnodes[num][2], p1f, p2f, a, bb)
        frac = (t1 + DIST_EPSILON) / (t1 - t2) if t1 < 0 else (t1 - DIST_EPSILON) / (t1 - t2)
        frac = min(1.0, max(0.0, frac))
        midf = p1f + (p2f - p1f) * frac
        mid = [a[i] + frac * (bb[i] - a[i]) for i in range(3)]
        side = 1 if t1 < 0 else 0
        if not rec(bsp.clipnodes[num][1 + side], p1f, midf, a, mid):
            return False
        if point_contents(bsp, bsp.clipnodes[num][1 + (side ^ 1)], mid, margin) != CONTENTS_SOLID:
            return rec(bsp.clipnodes[num][1 + (side ^ 1)], midf, p2f, mid, bb)
        if tr["allsolid"]:
            return False
        tr["normal"] = [pl[0], pl[1], pl[2]] if side == 0 else [-pl[0], -pl[1], -pl[2]]
        tr["hit"] = True
        while point_contents(bsp, root, mid, margin) == CONTENTS_SOLID:
            frac -= 0.1
            if frac < 0:
                tr["fraction"], tr["endpos"] = midf, list(mid)
                return False
            midf = p1f + (p2f - p1f) * frac
            mid = [a[i] + frac * (bb[i] - a[i]) for i in range(3)]
        tr["fraction"], tr["endpos"] = midf, list(mid)
        return False

    rec(root, 0.0, 1.0, list(p1), list(p2))
    return tr


def gs_dir_to_godot(n):
    """GoldSrc direction -> Godot, matching hop's gs_dir_to_godot."""
    return (-n[0], n[2], n[1])


AXES = ("x", "y", "z")


def axis_span(bsp, root, p, axis, limit=256.0, margin=0.0, step=0.25, res=1.0e-4):
    """The interval along `axis` through p over which the contents do not change.

    Returns (lo, hi, solid, lo_open, hi_open): offsets in GoldSrc units either side of p,
    whether p itself is in solid, and whether that side ran to `limit` without changing.
    A sign change is found by marching and then bisected, because contents along a ray is
    piecewise constant with no closed form here — the planes a leaf is bounded by are not
    the only ones the descent crosses.
    """
    def solid_at(t):
        q = list(p)
        q[axis] += t
        return point_contents(bsp, root, q, margin) == CONTENTS_SOLID

    here = solid_at(0.0)

    def edge(sign):
        t = 0.0
        while t < limit:
            nxt = min(t + step, limit)
            if solid_at(sign * nxt) != here:
                lo, hi = t, nxt           # lo keeps `here`, hi has changed
                while hi - lo > res:
                    mid = 0.5 * (lo + hi)
                    if solid_at(sign * mid) == here:
                        lo = mid
                    else:
                        hi = mid
                return sign * lo, False
            t = nxt
        return sign * limit, True

    lo, lo_open = edge(-1.0)
    hi, hi_open = edge(1.0)
    return lo, hi, here, lo_open, hi_open


def span_line(bsp, root, p, axis, limit=256.0, margin=0.0):
    """One axis's span as a line of text, from p's own point of view."""
    lo, hi, solid, lo_open, hi_open = axis_span(bsp, root, p, axis, limit, margin)
    mark = lambda v, open_: ("%+9.3f" % v) + ("+" if open_ else " ")
    if solid:
        return "%s: SOLID  exit %s / %s  (thickness %7.3f)" % (
            AXES[axis], mark(lo, lo_open), mark(hi, hi_open), hi - lo)
    return "%s: free %s .. %s  (span %7.3f)" % (
        AXES[axis], mark(lo, lo_open), mark(hi, hi_open), hi - lo)


def report_span(bsp, root, p, limit=256.0, margin=0.0):
    print("trace point %s" % (tuple(round(v, 3) for v in p),))
    for axis in range(3):
        print("  " + span_line(bsp, root, p, axis, limit, margin))
    po = hull_push_out(bsp, root, p, margin)
    if po is None:
        print("  push_out: none (not in blocking contents)")
        return
    n, d = po
    be = best_escape(bsp, root, p, margin)
    print("  push_out: %s depth %.3f -> %s" % (
        tuple(round(v, 2) for v in n), d,
        "EXITS" if escape_exits(bsp, root, p, n, d) else "still SOLID"))
    if be is not None and (be[0] != n or abs(be[1] - d) > 1e-6):
        print("  nearest exit that works: %s depth %.3f" % (
            tuple(round(v, 2) for v in be[0]), be[1]))


POSE_RE = re.compile(r"\bt\s*(-?\d+)\b.*?hull\s*=?\s*(\d).*?"
                     r"(-?\d+\.?\d*)\s+(-?\d+\.?\d*)\s+(-?\d+\.?\d*)")


def report_poses(bsp, models, idx, path, limit=256.0, margin=0.0):
    """A span table for a file of dumped trace points, one per tick.

    The probe (tools/probe_golem_real.gd) prints these; the point is already in the
    brush model's own frame, so the mover's yaw never enters into it. The hull in the
    line picks the clipnode root, so a tick spent crouched is read against hull 3.
    """
    print("%-5s %-4s %-26s %s" % ("tick", "hull", "trace point (model GS)", "per-axis interval, GoldSrc units"))
    for raw in open(path):
        m = POSE_RE.search(raw)
        if not m:
            continue
        tick, hull = int(m.group(1)), int(m.group(2))
        p = [float(m.group(3)), float(m.group(4)), float(m.group(5))]
        root = models[idx]["headnode"][hull]
        cells = []
        for axis in range(3):
            lo, hi, solid, lo_open, hi_open = axis_span(bsp, root, p, axis, limit, margin)
            cells.append("%s%s%+8.2f%s,%+8.2f%s]" % (
                AXES[axis], "*[" if solid else " [",
                lo, "+" if lo_open else "", hi, "+" if hi_open else ""))
        po = hull_push_out(bsp, root, p, margin)
        tail = ""
        if po is not None:
            n, d = po
            tail = "  push %s d=%.2f %s" % (
                tuple(round(v, 2) for v in n), d,
                "exits" if escape_exits(bsp, root, p, n, d) else "STILL SOLID")
        print("%-5d %-4d (%8.2f,%8.2f,%8.2f)  %s%s" % (
            tick, hull, p[0], p[1], p[2], "  ".join(cells), tail))
    print("\n* = the point itself is in SOLID, so the interval is the solid's thickness")
    print("+ = that side ran to the %.0f-unit limit without the contents changing" % limit)


def report_point(bsp, root, p):
    print("trace point %s" % (tuple(p),))
    leaf = point_contents(bsp, root, p)
    print("  contents: %s" % ("SOLID" if leaf == CONTENTS_SOLID else "empty (%d)" % leaf))
    if leaf != CONTENTS_SOLID:
        return
    cand, _ = descent_planes(bsp, root, p)
    cand.sort(key=lambda c: c[0])
    print("  the leaf's bounding planes, nearest first:")
    for i, (mag, pn, n) in enumerate(cand[:8]):
        ok = escape_exits(bsp, root, p, n, mag)
        print("    |d|=%8.3f plane#%-5d escape %-18s %-22s%s" % (
            mag, pn, str(tuple(round(v, 2) for v in gs_dir_to_godot(n))) + " godot",
            "EXITS the solid" if ok else "still SOLID — useless",
            "   <- hull_push_out picks this" if i == 0 else ""))


def survey(bsp, root, mins, maxs, n=20000, seed=11):
    """How often is hull_push_out's direction useless? Buckets by reported depth,
    because a small depth is intuitively 'shallow, so surely correct' — and isn't."""
    random.seed(seed)
    buckets = {}
    for _ in range(n):
        p = [random.uniform(mins[i] - 40, maxs[i] + 40) for i in range(3)]
        po = hull_push_out(bsp, root, p)
        if po is None:
            continue
        nrm, d = po
        k = next(k for lim, k in ((1, "<=1"), (2, "<=2"), (4, "<=4"), (8, "<=8"), (1e30, ">8"))
                 if d <= lim)
        t, f = buckets.get(k, (0, 0))
        buckets[k] = (t + 1, f + (0 if escape_exits(bsp, root, p, nrm, d) else 1))
    for k in ("<=1", "<=2", "<=4", "<=8", ">8"):
        t, f = buckets.get(k, (0, 0))
        if t:
            print("  reported depth %-4s n=%6d  escape fails to exit: %5.1f%%" % (k, t, 100.0 * f / t))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bsp")
    ap.add_argument("--model", type=int, help="brush model index (see --list)")
    ap.add_argument("--classname", help="brush entity classname, instead of --model")
    ap.add_argument("--hull", type=int, default=1, choices=(1, 2, 3))
    ap.add_argument("--point", type=float, nargs=3, metavar=("X", "Y", "Z"))
    ap.add_argument("--sweep", type=float, nargs=6, metavar=("X1", "Y1", "Z1", "X2", "Y2", "Z2"))
    ap.add_argument("--margin", type=float, default=0.0, help="hull inflation, GoldSrc units")
    ap.add_argument("--span", type=float, nargs=3, metavar=("X", "Y", "Z"),
                    help="free interval on all three axes through this point")
    ap.add_argument("--poses", help="file of dumped trace points (see report_poses)")
    ap.add_argument("--limit", type=float, default=256.0,
                    help="how far a span query looks along an axis (default 256)")
    ap.add_argument("--survey", action="store_true")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()

    bsp = BSP(a.bsp)
    if a.list:
        for e in bsp.ents:
            if e.get("model", "").startswith("*"):
                print("%-28s %s  origin=%s" % (e.get("classname"), e["model"], e.get("origin", "-")))
        return
    idx = a.model if a.model is not None else bsp.model_of(a.classname)
    if idx is None:
        ap.error("give --model N or a --classname that exists (see --list)")
    m = bsp.models[idx]
    root = m["headnode"][a.hull]
    print("model %d  hull %d  root clipnode %d  mins=%s maxs=%s\n" % (
        idx, a.hull, root, tuple(round(v, 1) for v in m["mins"]),
        tuple(round(v, 1) for v in m["maxs"])))
    if a.point:
        report_point(bsp, root, a.point)
    if a.span:
        report_span(bsp, root, a.span, a.limit, a.margin)
    if a.poses:
        report_poses(bsp, bsp.models, idx, a.poses, a.limit, a.margin)
    if a.sweep:
        tr = hull_sweep(bsp, root, a.sweep[0:3], a.sweep[3:6], a.margin)
        print("sweep hit=%s allsolid=%s fraction=%.4f endpos=%s normal=%s" % (
            tr["hit"], tr["allsolid"], tr["fraction"],
            tuple(round(v, 3) for v in tr["endpos"]),
            tuple(round(v, 3) for v in gs_dir_to_godot(tr["normal"]))))
    if a.survey:
        survey(bsp, root, m["mins"], m["maxs"])


if __name__ == "__main__":
    main()
