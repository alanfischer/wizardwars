#!/usr/bin/env python3
"""Analyze GoldSrc BSP water and generate info_clipbrush entities.

GoldSrc CLIP brushes live only in the clip hulls (hull 1-3), which our importer
does not build — so clip walls meant to keep players out of water are missing and
players fall through into the void. Since we own the importer, we recover the
intent by injecting `info_clipbrush` point entities (AABBs, optionally yaw-rotated)
into the BSP's plain-text entity lump; the runtime turns each into a StaticBody3D
box on LAYER_CLIP (blocks player movement, transparent to spells).

Usage:
  ww_clipbrush.py analyze <bsp>          # dump water faces / clusters
  ww_clipbrush.py inject  <bsp> [--dry]  # add info_clipbrush ents for water
"""
import math
import re
import sys
from collections import deque

from bsp import Bsp
NUM_LUMPS = 15


def is_water_tex(name):
    return name.startswith("!") or name.startswith("*")


def face_polys(bsp):
    """Yield (face_index, texname, model_index, poly_verts) for every face."""
    verts = bsp.verts
    edges = bsp.edges
    surfedges = bsp.surfedges
    faces = bsp.faces
    texinfos = bsp.texinfo
    names = bsp.texnames()
    models = bsp.models

    # dmodel_t tail is headnode[4], visleafs, firstface, numfaces -> indices 14 and 15.
    face_model = [0] * len(faces)
    for mi, m in enumerate(models):
        for fi in range(m[14], m[14] + m[15]):
            if 0 <= fi < len(faces):
                face_model[fi] = mi

    for fi, fc in enumerate(faces):
        miptex = texinfos[fc[4]][8]
        name = names[miptex] if 0 <= miptex < len(names) else ""
        poly = []
        for k in range(fc[3]):
            se = surfedges[fc[2] + k]
            e = edges[abs(se)]
            v = e[0] if se >= 0 else e[1]
            poly.append(tuple(verts[v]))
        yield fi, name, face_model[fi], poly


def cluster_water(bsp):
    """Group water faces into connected components by XY-overlap of AABBs."""
    boxes = []  # (minx,miny,minz,maxx,maxy,maxz, texname, model)
    for _, name, model, poly in face_polys(bsp):
        if not is_water_tex(name) or not poly:
            continue
        xs = [p[0] for p in poly]
        ys = [p[1] for p in poly]
        zs = [p[2] for p in poly]
        boxes.append([min(xs), min(ys), min(zs), max(xs), max(ys), max(zs), name, model])
    return boxes


def cluster_components(boxes, pad=1.0):
    """Union-find water face AABBs that overlap/touch in XY into components."""
    n = len(boxes)
    parent = list(range(n))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        parent[find(a)] = find(b)

    def xy_touch(a, b):
        return (a[0] <= b[3] + pad and b[0] <= a[3] + pad and
                a[1] <= b[4] + pad and b[1] <= a[4] + pad)

    for i in range(n):
        for j in range(i + 1, n):
            if xy_touch(boxes[i], boxes[j]):
                union(i, j)
    groups = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(boxes[i])
    return list(groups.values())


def analyze(path):
    bsp = Bsp(path)
    print("version", bsp.version, "models", len(bsp.models))
    names = bsp.texnames()
    watertex = sorted({n for n in names if is_water_tex(n)})
    print("water textures:", watertex)
    boxes = cluster_water(bsp)
    print("water faces:", len(boxes))
    if not boxes:
        return
    allmin = [min(b[i] for b in boxes) for i in range(3)]
    allmax = [max(b[i + 3] for b in boxes) for i in range(3)]
    print("overall liquid AABB mins=%s maxs=%s" % (allmin, allmax))

    groups = cluster_components(boxes)
    print("\n%d spatial liquid clusters (XY-connected):" % len(groups))
    groups.sort(key=lambda g: -(  # sort by footprint area
        (max(x[3] for x in g) - min(x[0] for x in g)) *
        (max(x[4] for x in g) - min(x[1] for x in g))))
    for gi, g in enumerate(groups):
        mn = [min(x[i] for x in g) for i in range(3)]
        mx = [max(x[i + 3] for x in g) for i in range(3)]
        texset = sorted({x[6] for x in g})
        top = max(x[5] for x in g)
        print("  [%d] faces=%3d tex=%s\n       mins=(%.0f,%.0f,%.0f) maxs=(%.0f,%.0f,%.0f) surfZ=%.0f"
              % (gi, len(g), texset, mn[0], mn[1], mn[2], mx[0], mx[1], mx[2], top))


# --- clip box generation -----------------------------------------------------

# Fill the big "!waterblue" river with clip. Cap top well above the shore so
# players are stopped at the waterline (ww_golem has nothing walkable over the
# water — no bridges — so a tall wall blocks nothing legitimate); floor to the
# basin bottom so downward moves can't tunnel through.
WATER_TEX = "!waterblue"
CLIP_TOP = 1024     # box top Z — "to the sky" (map ceiling is ~995). Nothing is
                    # walkable over the water, so a tall wall blocks players at
                    # the shoreline while overshoot lands only on water/void and
                    # the (deliberately non-walkable) dock.
CLIP_BOTTOM = -272  # box bottom Z (just under the basin floor at -256)


def water_top_polys(bsp):
    """2D polygons of the flat top surface of the target water (at its surfZ)."""
    polys = []
    for _, name, _, poly in face_polys(bsp):
        if name != WATER_TEX or not poly:
            continue
        zs = [p[2] for p in poly]
        if max(zs) - min(zs) > 0.5:
            continue  # not a flat (horizontal) face
        polys.append([(p[0], p[1]) for p in poly])
    return polys


SEAM_PAD = 8.0      # expand each box in-plane so runs overlap at the bends
ADJ_DIST = 300.0    # connect surface tiles whose centroids are within this (u)
DP_EPS = 380.0      # Douglas-Peucker tolerance: larger = fewer, longer runs


def _centroid(poly):
    n = len(poly)
    return (sum(p[0] for p in poly) / n, sum(p[1] for p in poly) / n)


def _rot(x, y, deg):
    r = math.radians(deg)
    c, s = math.cos(r), math.sin(r)
    return (x * c - y * s, x * s + y * c)


def _min_area_angle(pts):
    """Angle (deg) of the minimum-area oriented bounding box of a point set.
    This snaps to the run's true long edge; PCA of the centroids drifts a degree
    or two (enough to leave a visible sliver), so we minimize box area instead."""
    best_area, best = None, 0.0
    a = 0.0
    while a < 90.0:  # box has 90° symmetry, so [0,90) covers all orientations
        r = math.radians(a)
        c, s = math.cos(r), math.sin(r)
        xs = [px * c + py * s for px, py in pts]
        ys = [-px * s + py * c for px, py in pts]
        area = (max(xs) - min(xs)) * (max(ys) - min(ys))
        if best_area is None or area < best_area:
            best_area, best = area, a
        a += 0.25
    return best


def _seg_point_dist(p, a, b):
    """Distance from point p to segment a-b."""
    (px, py), (ax, ay), (bx, by) = p, a, b
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy or 1.0)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def _adjacency(cents):
    n = len(cents)
    adj = [[] for _ in range(n)]
    for i in range(n):
        for j in range(i + 1, n):
            dx = cents[i][0] - cents[j][0]
            dy = cents[i][1] - cents[j][1]
            if dx * dx + dy * dy <= ADJ_DIST * ADJ_DIST:
                adj[i].append(j)
                adj[j].append(i)
    return adj


def _components(adj):
    n = len(adj)
    seen = [False] * n
    comps = []
    for s in range(n):
        if seen[s]:
            continue
        seen[s] = True
        stack, comp = [s], []
        while stack:
            u = stack.pop()
            comp.append(u)
            for v in adj[u]:
                if not seen[v]:
                    seen[v] = True
                    stack.append(v)
        comps.append(comp)
    return comps


def _farthest(adj, src):
    """BFS from src; return the farthest reachable node and the parent map."""
    par = {src: -1}
    q = deque([src])
    last = src
    while q:
        u = q.popleft()
        last = u
        for v in adj[u]:
            if v not in par:
                par[v] = u
                q.append(v)
    return last, par


def _centerline(adj, comp):
    """Ordered tile indices along the component's longest path (graph diameter):
    the water's centerline, found by two BFS passes."""
    a, _ = _farthest(adj, comp[0])
    b, par = _farthest(adj, a)
    path, u = [], b
    while u != -1:
        path.append(u)
        u = par[u]
    return path


def _douglas_peucker(pts, eps):
    """Indices of pts kept when simplifying the polyline within tolerance eps."""
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i0, i1 = stack.pop()
        ax, ay = pts[i0]
        bx, by = pts[i1]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy) or 1.0
        dmax, idx = 0.0, -1
        for k in range(i0 + 1, i1):
            x, y = pts[k]
            d = abs(dy * x - dx * y + bx * ay - by * ax) / length
            if d > dmax:
                dmax, idx = d, k
        if dmax > eps:
            keep[idx] = True
            stack += [(i0, idx), (idx, i1)]
    return [k for k in range(len(pts)) if keep[k]]


def _river_segments(polys):
    """Split the water into straight runs. Each connected component (river) is
    reduced to its centerline, Douglas-Peucker breaks it at the bends, and every
    tile is assigned to its nearest segment. Yields (theta_deg, [poly, ...])."""
    cents = [_centroid(p) for p in polys]
    adj = _adjacency(cents)
    out = []

    def emit(indices):
        faces = [polys[i] for i in indices]
        # angle from the run's own tile edges (min-area box), not the wiggly
        # centerline — this is what makes the wall parallel to the shore.
        out.append((_min_area_angle([v for p in faces for v in p]), faces))

    for comp in _components(adj):
        # tiny stray clusters (or an already-straight blob): one box
        if len(comp) < 6:
            emit(comp)
            continue
        path = _centerline(adj, comp)
        verts = [path[k] for k in _douglas_peucker([cents[i] for i in path], DP_EPS)]
        segs = list(zip(verts, verts[1:]))
        if not segs:
            emit(comp)
            continue
        groups = [[] for _ in segs]
        for i in comp:
            dists = [_seg_point_dist(cents[i], cents[a], cents[b]) for (a, b) in segs]
            groups[dists.index(min(dists))].append(i)
        for g in groups:
            if g:
                emit(g)
    return out


def generate_boxes(bsp):
    """Oriented clip boxes hugging the water. The river is split into straight
    runs by simplifying its centerline (see _river_segments); each run gets ONE
    yaw-rotated bounding box. Boxes reach the sky and overlap at the bends so the
    water is fully sealed with no gaps; overshoot lands only on water, void and
    the (deliberately non-walkable) dock, never on playable ground (verified)."""
    polys = water_top_polys(bsp)
    boxes = []
    cz = (CLIP_TOP + CLIP_BOTTOM) / 2.0
    sz = CLIP_TOP - CLIP_BOTTOM
    for theta, faces in _river_segments(polys):
        # rotate the run into its own frame; its axis-aligned extent there is a
        # single oriented bounding box hugging that straight segment.
        pts = [_rot(px, py, -theta) for poly in faces for (px, py) in poly]
        lxmin, lxmax = min(p[0] for p in pts) - SEAM_PAD, max(p[0] for p in pts) + SEAM_PAD
        lymin, lymax = min(p[1] for p in pts) - SEAM_PAD, max(p[1] for p in pts) + SEAM_PAD
        lcx, lcy = (lxmin + lxmax) / 2.0, (lymin + lymax) / 2.0
        cx, cy = _rot(lcx, lcy, theta)  # rotate the run's center back to world
        boxes.append((cx, cy, cz, lxmax - lxmin, lymax - lymin, sz, theta))
    return boxes, len(polys)


def fmt_num(v):
    return str(int(v)) if float(v).is_integer() else ("%.1f" % v)


def build_entities(boxes):
    blocks = []
    for (cx, cy, cz, sx, sy, sz, theta) in boxes:
        lines = ['{', '"classname" "info_clipbrush"',
                 '"origin" "%s %s %s"' % (fmt_num(cx), fmt_num(cy), fmt_num(cz)),
                 '"size" "%s %s %s"' % (fmt_num(sx), fmt_num(sy), fmt_num(sz))]
        if abs(theta) > 0.05:
            lines.append('"angles" "0 %s 0"' % fmt_num(round(theta, 1)))
        lines.append('}')
        blocks.append("\n".join(lines))
    return "\n".join(blocks)


def inject(path, dry=False):
    bsp = Bsp(path)
    boxes, nfaces = generate_boxes(bsp)
    print("%d %s surface faces -> %d oriented clip boxes, Z=[%d,%d]"
          % (nfaces, WATER_TEX, len(boxes), CLIP_BOTTOM, CLIP_TOP))

    ent_text = bsp.entities
    # idempotent: strip any previously-injected info_clipbrush blocks
    ent_text = re.sub(r'\{[^{}]*"classname"\s+"info_clipbrush"[^{}]*\}\s*',
                      "", ent_text).rstrip()
    new_block = build_entities(boxes)

    if dry:
        print("--- first 2 generated entities ---")
        print("\n".join(new_block.split("}")[:2]) + "}")
        print("--- (dry run, not written) ---")
        return

    bsp.entities = ent_text + "\n" + new_block
    bsp.save_entities()


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("analyze", "inject"):
        print(__doc__)
        sys.exit(1)
    if sys.argv[1] == "analyze":
        analyze(sys.argv[2])
    elif sys.argv[1] == "inject":
        inject(sys.argv[2], dry="--dry" in sys.argv)
