#!/usr/bin/env python3
"""Make replacements for the stock Half-Life gib and bone models in models/, one recipe per model.

  model_art.py [NAME ...]            make the named models (all of them when none are given)
  model_art.py --sheet OUT [NAME]    original and replacement shapes side by side, as a PNG

NAME is the path under models/ without .mdl, e.g. rockgibs. A gib model's submodels are the
debris shapes gib_effect.gd picks from at random; each replacement keeps its original's list of
them, every new shape fitted to the box of the one it replaces, and is written from scratch by
mdl.write as a static model: one bone, one bodypart, a single-frame idle. Shapes are built here
in code. Skins are baked from ambientCG CC0 materials (texture_kit.cc0, cached in build/cc0/) or
drawn, then moved onto the colour of the original's skin. The originals are read from git, as
they stood just before this script first replaced them (STOCK). models/CREDITS.md lists every
model made here and where its skins came from. Needs numpy and Pillow.
"""

import math
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mdl  # noqa: E402
import texture_kit as kit  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STOCK = "adcdaad9"


def original(name):
    data = subprocess.run(["git", "-C", ROOT, "show", "%s:models/%s.mdl" % (STOCK, name)],
                          capture_output=True, check=True).stdout
    return mdl.Mdl(name, data)


def rest_shapes(m):
    """Each submodel of the first bodypart as (verts, tris, uvs, skinref), posed at rest."""
    world = m.rest_world()
    out = []
    for sm in m.bodyparts[0]["models"]:
        vb = m.vert_bone(sm)
        verts = np.array([mdl.xform(world[vb[i]], v) for i, v in enumerate(m.verts(sm))]
                         or np.zeros((0, 3)))
        tris, uvs, skin = [], [], 0
        for mesh in m.meshes(sm):
            skin = mesh["skinref"]
            for tri in m.tris(mesh):
                tris.append([c[0] for c in tri])
                uvs.append([(c[2], c[3]) for c in tri])
        out.append((verts, np.array(tris, int).reshape(-1, 3), np.array(uvs, float).reshape(-1, 3, 2), skin))
    return out


# ---- shapes ----
# A shape is (P, T, UV): points, triangles wound counter-clockwise seen from outside, and
# per-corner UVs in 0..1 -- or None, for box_uv to project once the shape has its final size.

def icosphere(n):
    t = (1 + 5 ** 0.5) / 2
    P = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t), (0, -1, -t),
         (0, 1, -t), (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)]
    T = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4),
         (11, 10, 2), (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8),
         (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
    P = [np.array(p, float) / np.linalg.norm(p) for p in P]
    for _ in range(n):
        mid, T2 = {}, []

        def half(a, b):
            k = (min(a, b), max(a, b))
            if k not in mid:
                p = P[a] + P[b]
                P.append(p / np.linalg.norm(p))
                mid[k] = len(P) - 1
            return mid[k]
        for a, b, c in T:
            ab, bc, ca = half(a, b), half(b, c), half(c, a)
            T2 += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
        T = T2
    return np.array(P), np.array(T)


def lump(seed, subdiv=1, rough=0.25, chips=0, depth=0.25):
    """A rough ball: radial noise, then `chips` flat broken faces planed off it."""
    rnd = np.random.default_rng(seed)
    P, T = icosphere(subdiv)
    r = np.ones(len(P))
    for _ in range(6):
        w = rnd.normal(size=3) * rnd.uniform(1.5, 3.5)
        r += rough / 3 * np.cos(P @ w + rnd.uniform(0, math.tau))
    P = P * r[:, None]
    for _ in range(chips):
        d = rnd.normal(size=3)
        d /= np.linalg.norm(d)
        h = (P @ d).max() * (1 - depth * rnd.uniform(0.5, 1.0))
        over = np.maximum(P @ d - h, 0)
        P = P - over[:, None] * d
    return P, T, None


def ear_clip(poly):
    """Triangulate a simple counter-clockwise polygon."""
    idx = list(range(len(poly)))
    out = []

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    while len(idx) > 3:
        for k in range(len(idx)):
            i0, i1, i2 = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
            a, b, c = poly[i0], poly[i1], poly[i2]
            if cross(a, b, c) <= 1e-9:
                continue
            if any(cross(a, b, poly[j]) >= 0 and cross(b, c, poly[j]) >= 0 and cross(c, a, poly[j]) >= 0
                   for j in idx if j not in (i0, i1, i2)):
                continue
            out.append((i0, i1, i2))
            idx.pop(k)
            break
        else:
            break
    out.append(tuple(idx[:3]))
    return out


def extrude(outline, thick):
    """An outline in XY made a slab `thick` deep along Z."""
    poly = [tuple(p) for p in outline]
    if sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(poly, poly[1:] + poly[:1])) < 0:
        poly.reverse()
    n = len(poly)
    P = np.array([(x, y, thick / 2) for x, y in poly] + [(x, y, -thick / 2) for x, y in poly])
    T = []
    for a, b, c in ear_clip(poly):
        T += [(a, b, c), (c + n, b + n, a + n)]
    for i in range(n):
        j = (i + 1) % n
        T += [(i, i + n, j + n), (i, j + n, j)]
    return P, np.array(T), None


def ragged(rnd, pts, jag):
    """A closed outline with every edge broken into a zigzag of `jag` relative depth."""
    out = []
    for i in range(len(pts)):
        a, b = np.array(pts[i], float), np.array(pts[(i + 1) % len(pts)], float)
        out.append(a)
        if jag:
            d = b - a
            nrm = np.array([-d[1], d[0]])
            for k in range(1, int(rnd.integers(1, 3)) + 1):
                f = k / 3 + rnd.uniform(-0.08, 0.08)
                out.append(a + d * f + nrm * rnd.uniform(-jag, jag))
    return out


def blob_outline(rnd, n, wobble):
    ang = (np.arange(n) + rnd.uniform(-0.3, 0.3, n)) / n * math.tau
    rad = 1 + rnd.uniform(-wobble, wobble, n)
    return [(math.cos(a) * r, math.sin(a) * r) for a, r in zip(ang, rad)]


def broken_end(rnd, x, w, teeth, depth, sign):
    """Points across a plank's end at x, a splintered zigzag `depth` deep, from -w/2 to w/2."""
    ys = np.linspace(-w / 2, w / 2, teeth * 2 + 1)
    return [(x + sign * (depth * rnd.uniform(0.4, 1.0) if k % 2 else depth * rnd.uniform(0, 0.25)), y)
            for k, y in enumerate(ys)]


def plank(seed, teeth=3):
    rnd = np.random.default_rng(seed)
    w = 0.2
    right = broken_end(rnd, 0.5, w, teeth, 0.08, 1)
    left = broken_end(rnd, -0.5, w, teeth, 0.08, -1)[::-1]
    return extrude(right + left, 0.04)


def splinter(seed):
    rnd = np.random.default_rng(seed)
    pts = [(-0.5, 0), (-0.1, -0.05), (0.5, rnd.uniform(-0.01, 0.01)), (0.05, 0.05)]
    P, T, _ = extrude(pts, 0.04)
    P[:, 2] *= 1 - (P[:, 0] + 0.5) * 0.7  # tapers toward the point
    return P, T, None


def plate(seed, curl, n=7):
    """A torn sheet: a lumpy outline with ragged edges, curled along its length."""
    rnd = np.random.default_rng(seed)
    P, T, _ = extrude(ragged(rnd, blob_outline(rnd, n, 0.35), 0.06), 0.06)
    P[:, 2] += curl * P[:, 0] ** 2 + curl * 0.4 * rnd.uniform(-1, 1) * P[:, 1] ** 2
    return P, T, None


def shard(seed, n):
    rnd = np.random.default_rng(seed)
    P, T, _ = extrude(blob_outline(rnd, n, 0.45), 0.05)
    P[:, 2] += 0.08 * P[:, 0]  # a slight lean, so no two shards land flat alike
    return P, T, None


def box(lo, hi):
    (x0, y0, z0), (x1, y1, z1) = lo, hi
    P = np.array([(x, y, z) for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)], float)
    T = [(0, 1, 3), (0, 3, 2), (4, 6, 7), (4, 7, 5), (0, 4, 5), (0, 5, 1),
         (2, 3, 7), (2, 7, 6), (0, 2, 6), (0, 6, 4), (1, 5, 7), (1, 7, 3)]
    return P, np.array(T), None


def merge(*shapes):
    Ps, Ts, n = [], [], 0
    for P, T, _ in shapes:
        Ps.append(P)
        Ts.append(T + n)
        n += len(P)
    return np.concatenate(Ps), np.concatenate(Ts), None


def cinder_block(seed, cells):
    """A hollow block `cells` cores long (x), its face walls and webs as boxes, the broken
    end chipped off when the piece is partial."""
    rnd = np.random.default_rng(seed)
    wall, web, L, W, H = 0.12, 0.14, 0.5 * cells, 0.5, 0.5
    parts = [box((0, 0, 0), (L, wall, H)), box((0, W - wall, 0), (L, W, H))]
    xs = [0] + [k * 0.5 for k in range(1, cells)] + [L]
    for k, x in enumerate(xs):
        if cells < 2 and k == len(xs) - 1:
            break
        a = min(max(x - web / 2, 0), L - web)
        parts.append(box((a, wall, 0), (a + web, W - wall, H)))
    P, T, _ = merge(*parts)
    jit = rnd.uniform(-0.02, 0.02, P.shape) * (P[:, :1] > L - 0.01)
    return P + jit - np.array([L / 2, W / 2, H / 2]), T, None


def lathe(profile, sides=8, lobe=0.0, flat=1.0):
    """A solid of revolution about Y: `profile` is (y, radius) end to end, radius 0 at both
    ends. `lobe` pinches the cross-section into two knuckles where the radius swells, as a long
    bone's ends do; `flat` squashes it along Z."""
    ys = np.array([p[0] for p in profile], float)
    rs = np.array([p[1] for p in profile], float)
    swell = (rs - rs[1:-1].min()) / max(rs.max() - rs[1:-1].min(), 1e-6)
    P, UV, T = [], [], []
    for i, (y, r) in enumerate(zip(ys, rs)):
        for j in range(sides + 1):
            a = math.tau * j / sides
            k = r * (1 + lobe * swell[i] * math.cos(2 * a))
            P.append((k * math.cos(a), y, k * math.sin(a) * flat))
            UV.append((j / sides, (y - ys[0]) / (ys[-1] - ys[0])))
    row = sides + 1
    for i in range(len(ys) - 1):
        for j in range(sides):
            a, b, c, d = i * row + j, i * row + j + 1, (i + 1) * row + j, (i + 1) * row + j + 1
            T += [(a, c, d), (a, d, b)]
    P, UV, T = np.array(P), np.array(UV), np.array(T)
    return P, T, UV[T]


def long_bone(knob=0.08, shaft=0.035, lobe=0.35, sides=8):
    prof = [(-0.5, 0), (-0.49, knob * 0.7), (-0.46, knob), (-0.40, knob * 0.8), (-0.32, shaft * 1.2),
            (0, shaft), (0.32, shaft * 1.2), (0.40, knob * 0.8), (0.46, knob), (0.49, knob * 0.7), (0.5, 0)]
    return lathe(prof, sides, lobe, 0.8)


def rib(seed):
    rnd = np.random.default_rng(seed)
    prof = [(-0.5, 0), (-0.48, 0.03)] + [(y, 0.025 + 0.004 * rnd.uniform(-1, 1)) for y in np.linspace(-0.4, 0.4, 7)] \
        + [(0.48, 0.02), (0.5, 0)]
    P, T, UV = lathe(prof, 6, 0.0, 0.45)
    a = P[:, 1] * 2.2  # bent into an arc about Z
    R = 0.45
    x, y = (R + P[:, 0]) * np.cos(a), (R + P[:, 0]) * np.sin(a)
    return np.stack([x, y, P[:, 2] + 0.3 * a], 1), T, UV  # and twisted out of that plane, as a rib is


def vertebra(seed):
    body = lathe([(-0.1, 0), (-0.1, 0.16), (-0.06, 0.19), (0.06, 0.19), (0.1, 0.16), (0.1, 0)], 10)
    spine = box((-0.05, -0.04, 0.12), (0.05, 0.04, 0.55))
    left = box((-0.42, -0.035, 0.08), (-0.12, 0.035, 0.16))
    right = box((0.12, -0.035, 0.08), (0.42, 0.035, 0.16))
    P, T, _ = merge(body, spine, left, right)
    P = P[:, [0, 2, 1]] * np.array([1, 1, -1])  # body axis along Z, the spine along Y
    return P, T, None


def fit(shape, lo, hi):
    """Turn and stretch `shape` into the box lo..hi: its longest axis onto the box's longest,
    and so on down, without mirroring it."""
    P, T, UV = shape
    ext = P.max(0) - P.min(0)
    want = np.array(hi) - np.array(lo)
    perm = np.zeros(3, int)
    perm[np.argsort(want)] = np.argsort(ext)
    P = P[:, perm]
    M = np.eye(3)[:, perm]
    if np.linalg.det(M) < 0:
        P[:, int(np.argmin(want))] *= -1
    P = (P - P.min(0)) / np.maximum(P.max(0) - P.min(0), 1e-9) * want + np.array(lo)
    return P, T, UV


def box_uv(P, T):
    """Per-triangle planar projection along its normal's dominant axis, the piece's longest
    span across the texture's width."""
    n = np.cross(P[T[:, 1]] - P[T[:, 0]], P[T[:, 2]] - P[T[:, 0]])
    lo, span = P.min(0), (P.max(0) - P.min(0)).max()
    order = np.argsort(-(P.max(0) - P.min(0)))
    UV = np.zeros(T.shape + (2,))
    for i, tri in enumerate(T):
        axes = [a for a in order if a != int(np.argmax(np.abs(n[i])))]
        UV[i] = (P[tri][:, axes] - lo[axes]) / span
    return UV


def finish(shape, smooth):
    """(verts, norms, tris) for mdl.write: flat shapes get a normal per triangle, smooth ones
    one per position (so a lathe's seam doesn't show), and every triangle is wound back."""
    P, T, UV = shape
    if UV is None:
        UV = box_uv(P, T)
    fn = np.cross(P[T[:, 1]] - P[T[:, 0]], P[T[:, 2]] - P[T[:, 0]])
    keys = {}
    vid = np.array([keys.setdefault(tuple(np.round(p, 5)), len(keys)) for p in P])
    verts = np.zeros((len(keys), 3))
    verts[vid] = P
    if smooth:
        acc = np.zeros((len(keys), 3))
        for i, tri in enumerate(T):
            for v in tri:
                acc[vid[v]] += fn[i]
        norms = acc / np.maximum(np.linalg.norm(acc, axis=1, keepdims=True), 1e-9)
        nid = lambda i, v: vid[v]  # noqa: E731
    else:
        norms = fn / np.maximum(np.linalg.norm(fn, axis=1, keepdims=True), 1e-9)
        nid = lambda i, v: i  # noqa: E731
    tris = []
    for i, tri in enumerate(T):
        if np.linalg.norm(fn[i]) < 1e-9:
            continue
        corners = [(vid[v], nid(i, v), UV[i][k]) for k, v in enumerate(tri)]
        tris.append([corners[0], corners[2], corners[1]])
    return verts, norms, tris


# ---- skins ----

def noise(size, seed, scale, octaves=4):
    rnd = np.random.default_rng(seed)
    w, h = size
    out = np.zeros((h, w))
    for o in range(octaves):
        g = rnd.uniform(-1, 1, (max(2, int(h / scale * 2 ** o)), max(2, int(w / scale * 2 ** o))))
        img = Image.fromarray(((g + 1) * 127.5).astype(np.uint8)).resize((w, h), Image.BICUBIC)
        out += (np.asarray(img, float) / 127.5 - 1) / 2 ** o
    return out / 2


def tint(field, stops):
    """Map a -1..1 field through colour stops [(at, (r, g, b)), ...]."""
    at = np.array([s[0] for s in stops])
    rgb = np.array([s[1] for s in stops], float)
    f = np.clip(field, at[0], at[-1])
    out = np.stack([np.interp(f, at, rgb[:, c]) for c in range(3)], -1)
    return Image.fromarray(out.clip(0, 255).astype(np.uint8))


def bone_skin(size, seed):
    w, h = size
    n = 0.6 * noise(size, seed, 5) + 0.4 * noise(size, seed + 1, 2)
    ends = np.abs(np.linspace(-1, 1, h))[:, None] ** 8  # joint ends darker, as in the original
    pores = noise(size, seed + 2, 1.5, 1) > 0.5
    img = tint(n - ends * 0.35 - pores * 0.12, [(-1, (120, 100, 70)), (0, (205, 190, 155)), (1, (235, 228, 205))])
    return img.filter(ImageFilter.SMOOTH)


def flesh_skin(size, seed):
    n = noise(size, seed, 8)
    streak = np.sin(np.linspace(0, 9, size[0])[None, :] + 3 * noise(size, seed + 1, 12)) ** 8
    fat = noise(size, seed + 2, 5) > 0.35
    img = tint(n, [(-1, (60, 8, 10)), (0, (130, 25, 25)), (1, (175, 60, 55))])
    a = np.asarray(img, float)
    a = a * (1 - 0.35 * streak[..., None]) + np.array([200, 110, 100]) * 0.35 * streak[..., None]
    a[fat] = a[fat] * 0.5 + np.array([215, 190, 120]) * 0.5
    return Image.fromarray(a.clip(0, 255).astype(np.uint8)).filter(ImageFilter.SMOOTH)


def glass_skin(size, seed):
    w, h = size
    yy, xx = np.mgrid[0:h, 0:w] / max(w, h)
    sheen = np.sin((xx + yy) * 7 + 2 * noise(size, seed, 16)) * 0.6 + 0.25 * noise(size, seed + 1, 4)
    return tint(sheen, [(-1, (70, 95, 105)), (0, (150, 180, 185)), (1, (235, 245, 245))])


def photo(asset, size, rotate=0):
    return kit.baked(asset, size, rotate=rotate)


# ---- recipes ----
# Each model: its skins as (name, flags, size, maker, source), then one entry per original submodel:
# (shape maker, skin index, smooth). Makers take a seed, so each shape differs.

def matched(img, ref_rgb, spread=0.7):
    """Onto the original skin's colour, leaving out its black: unused texels, and the background
    some originals paint their part on."""
    ref = ref_rgb.convert("RGBA")
    ref.putalpha(ref_rgb.convert("L").point(lambda v: 255 if v > 24 else 0))
    return kit.match(img, ref, spread)


MODELS = {
    "rockgibs": (
        [("rock.bmp", 0, (64, 64), lambda s: photo("Rock035", (64, 64)), "ambientCG Rock035 (CC0)")],
        [(lambda s: lump(s, 1, 0.3, 6, 0.3), 0, False)] * 3),
    "woodgibs": (
        [("wood.bmp", 0, (64, 64), lambda s: photo("Wood049", (64, 64), rotate=90), "ambientCG Wood049 (CC0)")],
        [(splinter, 0, False), (lambda s: plank(s, 2), 0, False), (lambda s: plank(s, 3), 0, False)]),
    "metalplategibs": (
        [("metal2.bmp", 0, (32, 32), lambda s: photo("Metal024", (32, 32)), "ambientCG Metal024 (CC0)"),
         ("metal1.bmp", 0, (64, 64), lambda s: photo("MetalPlates013", (64, 64)), "ambientCG MetalPlates013 (CC0)")],
        [(lambda s: plate(s, 1.2, 6), 0, False), (lambda s: plate(s, 1.0), 0, False)]
        + [(lambda s: plate(s, 0.4), 1, False)] * 11),
    "glassgibs": (
        [("glass.bmp", 3, (64, 64), lambda s: glass_skin((64, 64), s), "drawn")],
        [(lambda s: shard(s, 3), 0, False), (lambda s: shard(s, 3), 0, False), (lambda s: shard(s, 4), 0, False),
         (lambda s: shard(s, 4), 0, False), (lambda s: shard(s, 3), 0, False), (lambda s: shard(s, 4), 0, False),
         (lambda s: shard(s, 5), 0, False)]),
    "cindergibs": (
        [("brokencinder.bmp", 0, (64, 64), lambda s: photo("Concrete031", (64, 64)), "ambientCG Concrete031 (CC0)"),
         ("cinder.bmp", 0, (128, 64), lambda s: photo("Concrete034", (128, 64)), "ambientCG Concrete034 (CC0)")],
        [(lambda s: lump(s, 1, 0.2, 7, 0.35), 0, False)] * 4
        + [(lambda s: cinder_block(s, 1), 1, False), (lambda s: cinder_block(s, 2), 1, False),
           (lambda s: cinder_block(s, 2), 1, False), (lambda s: cinder_block(s, 2), 1, False),
           (lambda s: cinder_block(s, 1), 1, False)]),
    "fleshgibs": (
        [("flesh.bmp", 0, (64, 64), lambda s: flesh_skin((64, 64), s), "drawn")],
        [(lambda s: lump(s, 1, 0.35), 0, True)] * 4),
    "bonegibs": (
        [("bone.bmp", 0, (32, 96), lambda s: bone_skin((32, 96), s), "drawn")],
        [(lambda s: long_bone(), 0, True), (lambda s: long_bone(0.09, 0.04, 0.4), 0, True),
         (lambda s: long_bone(0.06, 0.03, 0.2), 0, True), (rib, 0, True), (vertebra, 0, False)]),
    "bone": (
        [("bone.bmp", 0, (32, 128), lambda s: bone_skin((32, 128), s), "drawn")],
        [(lambda s: long_bone(0.13, 0.045, 0.6, 10), 0, True)]),
}

ORIGINAL_SKIN = {"metalplategibs": [0, 1], "cindergibs": [0, 1]}  # skins kept one for one
SPREAD = {"bone": 0.2}  # its original is a drawn bone, black outlines and all: take its colour only


def make(name):
    skins, parts = MODELS[name]
    orig = original(name)
    shapes = [s for s in rest_shapes(orig) if len(s[0])]
    otex = orig.textures()
    textures = []
    for i, (tname, flags, size, maker, _) in enumerate(skins):
        j = ORIGINAL_SKIN.get(name, [0] * len(skins))[i]
        _, _, w, h, rgb = otex[j]
        img = matched(maker(i + 1).convert("RGB").resize(size, Image.LANCZOS), Image.frombytes("RGB", (w, h), rgb),
                      SPREAD.get(name, 0.7))
        q = img.quantize(256, method=Image.Quantize.MEDIANCUT)
        pal = bytes(q.getpalette()[:768]).ljust(768, b"\0")
        textures.append((tname, flags, size[0], size[1], q.tobytes(), pal))
    subs = []
    for k, ((maker, skin, smooth), (V, _, _, _)) in enumerate(zip(parts, shapes)):
        sm_name = orig.bodyparts[0]["models"][k]["name"] or "gib%d" % (k + 1)
        verts, norms, tris = finish(fit(maker(k + 1), V.min(0), V.max(0)), smooth)
        w, h = textures[skin][2], textures[skin][3]
        tris = [[(vi, ni, int(round(uv[0] * (w - 1))), int(round(uv[1] * (h - 1)))) for vi, ni, uv in tri]
                for tri in tris]
        subs.append((sm_name, verts.tolist(), norms.tolist(), skin, tris))
    mdl.write(os.path.join(ROOT, "models", name + ".mdl"), name + ".mdl", textures, subs)
    print("models/%s.mdl: %d shapes, %d triangles" % (name, len(subs), sum(len(s[4]) for s in subs)))


# ---- review sheet ----

def render(m, cell=150, yaw=35, pitch=25):
    """Every submodel of `m`, one cell each, orthographic from above and to the side."""
    tex = [np.frombuffer(t[4], np.uint8).reshape(t[3], t[2], 3) for t in m.textures()]
    cy, sy = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    cp, sp = math.cos(math.radians(pitch)), math.sin(math.radians(pitch))
    R = np.array([[cy, sy, 0], [-sy * sp, cy * sp, cp], [sy * cp, -cy * cp, sp]])  # x right, y up, z toward eye
    light = np.array([0.4, 0.5, 0.75])
    light /= np.linalg.norm(light)
    cells = []
    for V, T, UV, skin in rest_shapes(m):
        img = np.full((cell, cell, 3), 40.0)
        if not len(V):
            cells.append(img)
            continue
        Q = V @ R.T
        lo, hi = Q.min(0), Q.max(0)
        k = (cell - 16) / max((hi - lo)[:2].max(), 1e-6)
        sx = (Q[:, 0] - (lo[0] + hi[0]) / 2) * k + cell / 2
        sy_ = cell / 2 - (Q[:, 1] - (lo[1] + hi[1]) / 2) * k
        zb = np.full((cell, cell), -1e9)
        t = tex[skin]
        for tri, uv in zip(T, UV):
            a, b, c = tri
            n = np.cross(Q[b] - Q[a], Q[c] - Q[a])
            if np.linalg.norm(n) < 1e-12:
                continue
            shade = 0.35 + 0.65 * abs(np.dot(n / np.linalg.norm(n), light))
            xs, ys = np.array([sx[a], sx[b], sx[c]]), np.array([sy_[a], sy_[b], sy_[c]])
            x0, x1 = int(max(xs.min(), 0)), int(min(xs.max() + 1, cell))
            y0, y1 = int(max(ys.min(), 0)), int(min(ys.max() + 1, cell))
            if x0 >= x1 or y0 >= y1:
                continue
            gx, gy = np.meshgrid(np.arange(x0, x1) + 0.5, np.arange(y0, y1) + 0.5)
            d = (ys[1] - ys[2]) * (xs[0] - xs[2]) + (xs[2] - xs[1]) * (ys[0] - ys[2])
            if abs(d) < 1e-9:
                continue
            w0 = ((ys[1] - ys[2]) * (gx - xs[2]) + (xs[2] - xs[1]) * (gy - ys[2])) / d
            w1 = ((ys[2] - ys[0]) * (gx - xs[2]) + (xs[0] - xs[2]) * (gy - ys[2])) / d
            w2 = 1 - w0 - w1
            inside = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
            z = w0 * Q[a, 2] + w1 * Q[b, 2] + w2 * Q[c, 2]
            sub = zb[y0:y1, x0:x1]
            hit = inside & (z > sub)
            if not hit.any():
                continue
            s = (w0 * uv[0, 0] + w1 * uv[1, 0] + w2 * uv[2, 0]).astype(int) % t.shape[1]
            tt = (w0 * uv[0, 1] + w1 * uv[1, 1] + w2 * uv[2, 1]).astype(int) % t.shape[0]
            sub[hit] = z[hit]
            img[y0:y1, x0:x1][hit] = t[tt[hit], s[hit]] * shade
        cells.append(img)
    return cells


def sheet(out, names):
    rows = []
    for name in names:
        old = render(original(name))
        new = render(mdl.Mdl(os.path.join(ROOT, "models", name + ".mdl")))
        rows += [old, new]
    cols = max(len(r) for r in rows)
    cell = rows[0][0].shape[0]
    img = np.full((len(rows) * cell, cols * cell, 3), 25.0)
    for i, r in enumerate(rows):
        for j, c in enumerate(r):
            img[i * cell:(i + 1) * cell, j * cell:(j + 1) * cell] = c
    Image.fromarray(img.clip(0, 255).astype(np.uint8)).save(out)
    print("wrote %s: original over replacement, rows %s" % (out, ", ".join(names)))


def write_credits():
    lines = ["# Model sources", "",
             "Replacements for the stock Half-Life gib and bone models, written by tools/model_art.py. "
             "Every shape is built in code; ambientCG materials are CC0 (https://ambientcg.com), and "
             "\"drawn\" skins are generated by the script.", "", "| model | skins |", "|---|---|"]
    for name, (skins, _) in MODELS.items():
        src = "; ".join("`%s`: %s" % (skin[0], skin[4]) for skin in skins)
        lines.append("| `%s.mdl` | %s |" % (name, src))
    open(os.path.join(ROOT, "models", "CREDITS.md"), "w").write("\n".join(lines) + "\n")


def main(argv):
    if argv[:1] == ["--sheet"]:
        sheet(argv[1], argv[2:] or list(MODELS))
        return
    for name in argv or list(MODELS):
        make(name)
    if not argv:
        write_credits()


if __name__ == "__main__":
    main(sys.argv[1:])
