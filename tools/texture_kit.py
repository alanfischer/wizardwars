#!/usr/bin/env python3
"""Building blocks for tools/texture_art.py: CC0 sources, baking, colour matching, and the
drawing every recipe shares. See texture_art.py for what they make.
"""

import io
import math
import os
import random
import sys
import urllib.request
import zipfile

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageStat

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wad_textures import original_wad, to_image  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "build", "cc0")
LIGHT = (-0.45, 0.55, 0.70)     # up-left, toward the viewer: the usual baked-texture key light

credits = {}


# --- sources ------------------------------------------------------------------

def cc0(asset, kind="Color"):
    """One map of an ambientCG material at 1K, or None if the material has no such map."""
    d = os.path.join(CACHE, asset)
    if not os.path.isdir(d):
        url = "https://ambientcg.com/get?file=%s_1K-JPG.zip" % asset
        req = urllib.request.Request(url, headers={"User-Agent": "wizardwars-texture-art"})
        with urllib.request.urlopen(req) as r:
            zipfile.ZipFile(io.BytesIO(r.read())).extractall(d)
    path = os.path.join(d, "%s_1K-JPG_%s.jpg" % (asset, kind))
    return Image.open(path) if os.path.exists(path) else None


_originals = []


def original(name):
    """The stock texture `name` replaces, as RGBA."""
    if not _originals:
        _originals.append(original_wad())
    return to_image(_originals[0].texture(name))


def baked(asset, size, box=None, rotate=0, relief=0.55, zoom=1):
    """`asset`'s colour with its AO and a key light off its normal map baked in. zoom > 1 takes
    a corner 1/zoom of the material across, for bigger features, and makes it tile again."""
    # Displacement stands in for a missing AO map: low is occluded either way.
    maps = [cc0(asset, k) for k in ("Color", "AmbientOcclusion", "NormalGL")]
    maps[1] = maps[1] or cc0(asset, "Displacement")
    if rotate:
        maps = [m.rotate(rotate, expand=True) for m in maps]
    if zoom > 1:
        box = (0, 0, maps[0].width // zoom, maps[0].height // zoom)
    if box:
        maps = [m.crop(box) for m in maps]
    # A whole material tiles, so it is resampled as a tile; a crop has no wrap to respect.
    fit = (lambda m: m.resize(size, Image.LANCZOS)) if box else (lambda m: resize_tiled(m, size))
    color, ao, normal = (fit(m) for m in maps)
    color, ao = color.convert("RGB"), ao.convert("L")
    lx, ly, lz = LIGHT
    ln = math.sqrt(lx * lx + ly * ly + lz * lz)
    shade = Image.new("L", size)
    shade.putdata([max(0, min(255, int(255 * ((1 - relief) + relief * 1.6 * max(0.0,
                  ((r / 127.5 - 1) * lx + (g / 127.5 - 1) * ly + (b / 127.5 - 1) * lz) / ln)))))
                   for r, g, b in zip(*[iter(normal.convert("RGB").tobytes())] * 3)])
    lit = ImageChops.multiply(color, Image.merge("RGB", [ImageChops.multiply(shade, ao)] * 3))
    return make_tileable(lit) if zoom > 1 else lit


def make_tileable(img):
    """A crop made to tile: its half-shifted copy shows at the edges (where the shift put the
    crop's interior), the crop itself in the middle (over the copy's seam). Fine for stochastic
    surfaces; anything with structure would ghost."""
    W, H = img.size
    shifted = ImageChops.offset(img, W // 2, H // 2)
    return Image.composite(img, shifted, feather(img.size, min(W, H) // 6))


def tiled(img, fn):
    """fn applied to img as the tile it is: run on a 3x3 repeat, keep the middle."""
    big = Image.new(img.mode, (img.width * 3, img.height * 3))
    for x in range(3):
        for y in range(3):
            big.paste(img, (x * img.width, y * img.height))
    out = fn(big)
    w, h = out.width // 3, out.height // 3
    return out.crop((w, h, 2 * w, 2 * h))


def resize_tiled(img, size):
    return tiled(img, lambda b: b.resize((size[0] * 3, size[1] * 3), Image.LANCZOS))


def match(img, ref, spread=1.0):
    """Move img's per-channel mean (and `spread` of its contrast) onto ref's opaque pixels."""
    ref_rgb = ref.convert("RGB")
    mask = ref.getchannel("A") if ref.mode == "RGBA" else None
    a, b = ImageStat.Stat(img.convert("RGB")), ImageStat.Stat(ref_rgb, mask)
    bands = []
    for ch, band in enumerate(img.convert("RGB").split()):
        sa, sb = max(a.stddev[ch], 1e-3), b.stddev[ch]
        k = 1 + spread * (sb / sa - 1)
        bands.append(band.point(lambda v, k=k, ma=a.mean[ch], mb=b.mean[ch]:
                                max(0, min(255, int(round((v - ma) * k + mb))))))
    return Image.merge("RGB", bands)


# --- drawn --------------------------------------------------------------------

def caustics(size, cells, seed, edge=0.10, warp=0.06, even=False, body=0.22):
    """Tileable Voronoi cell edges, bent by a periodic warp so they curve like the bright web
    light makes on a shallow bed. even seeds the cells on a jittered grid instead of at random,
    so no cell or junction is big enough to stand out where the tile repeats; body is how far
    each cell brightens from its middle out to its rim."""
    w, h = size
    rnd = random.Random(seed)
    if even:
        nx = max(1, round(math.sqrt(cells * w / h)))
        ny = max(1, round(cells / nx))
        cells = nx * ny
        pts = [((i + 0.5 + rnd.uniform(-0.35, 0.35)) * w / nx, (j + 0.5 + rnd.uniform(-0.35, 0.35)) * h / ny)
               for i in range(nx) for j in range(ny)]
    else:
        pts = [(rnd.random() * w, rnd.random() * h) for _ in range(cells)]
    pts = [(x + dx * w, y + dy * h) for x, y in pts for dx in (-1, 0, 1) for dy in (-1, 0, 1)]
    ph = [rnd.random() * math.tau for _ in range(4)]
    cell = math.sqrt(w * h / cells)
    # Seeds bucketed by cell, so a pixel only measures the ones near it. Three buckets out
    # always holds the nearest two, however the random seeds happen to clump.
    buckets = {}
    for q in pts:
        buckets.setdefault((int(q[0] // cell), int(q[1] // cell)), []).append(q)
    reach = 2 if even else 3
    px = []
    for y in range(h):
        for x in range(w):
            wx = (x + warp * w * (math.sin(math.tau * 2 * y / h + ph[0]) + 0.5 * math.sin(math.tau * 3 * x / w + ph[1]))) % w
            wy = (y + warp * h * (math.sin(math.tau * 2 * x / w + ph[2]) + 0.5 * math.sin(math.tau * 3 * y / h + ph[3]))) % h
            d1 = d2 = 1e9
            bx, by = int(wx // cell), int(wy // cell)
            near = [q for i in range(bx - reach, bx + reach + 1) for j in range(by - reach, by + reach + 1)
                    for q in buckets.get((i, j), ())]
            for qx, qy in near:
                d = (qx - wx) ** 2 + (qy - wy) ** 2
                if d < d1:
                    d1, d2 = d, d1
                elif d < d2:
                    d2 = d
            gap = (math.sqrt(d2) - math.sqrt(d1)) / cell
            body_v = body * min(1.0, math.sqrt(d1) / cell)
            px.append(int(255 * min(1.0, max(0.0, 1 - gap / edge) ** 1.5 + body_v)))
    out = Image.new("L", size)
    out.putdata(px)
    return out


def rope(ref, asset, strands=4):
    """Twisted strands at 45 degrees; tiles along the rope as long as `strands` divides it."""
    s = 8
    W, H = ref.width * s, ref.height * s
    period = H / strands
    fibre = baked(asset, (W, H), box=(0, 0, 256, 128), rotate=0, relief=0.3).convert("L")
    shade = Image.new("L", (W, H))
    shade.putdata([int(255 * math.sin(math.pi * (((x + y) % period) / period)) ** 0.6)
                   for y in range(H) for x in range(W)])
    lum = ImageChops.multiply(shade, fibre.point(lambda v: 110 + v // 2))
    return match(Image.merge("RGB", [lum] * 3), ref, 0.9).resize(ref.size, Image.LANCZOS)


def water(name, seed):
    """Caustic cells, evenly sized so that nothing in one tile stands out where it repeats:
    a liquid texture is small and covers whole rivers."""
    ref = original(name)
    big = (ref.width * 4, ref.height * 4)
    per = max(big) / min(big)  # stock keeps ~25 cells per square of tile, whatever its size
    web = tiled(caustics(big, round(25 * per), seed, 0.3, even=True, body=0.8),
                lambda b: b.filter(ImageFilter.GaussianBlur(3)))
    fine = tiled(caustics(big, round(64 * per), seed + 1, 0.25, even=True, body=0.3),
                 lambda b: b.filter(ImageFilter.GaussianBlur(1.5)))
    lum = ImageChops.add(ImageChops.multiply(web, Image.new("L", big, 180)),
                         ImageChops.multiply(fine, Image.new("L", big, 80)))
    img = match(Image.merge("RGB", [lum] * 3), ref)
    credit(name, "drawn: tileable Voronoi caustics")
    return img


def blocks(name, asset, cols, rows, bond=0.0, mortar=0.03, jitter=0.10, spread=0.8, seed=1):
    """Slabs or bricks laid over a whole (so seamless) material: each block shows the material
    at its own random offset and brightness, with dark joints and a bevel lit like baked() is.
    Tiles by construction, which a crop of a photo of bricks does not."""
    ref = original(name)
    s = 4
    W, H = ref.width * s, ref.height * s
    fill = baked(asset, (W, H))
    rnd = random.Random(seed)
    bw, bh = W / cols, H / rows
    img = fill.copy()
    joint = Image.new("L", (W, H))
    jd = ImageDraw.Draw(joint)
    lit = Image.new("L", (W, H))
    ld = ImageDraw.Draw(lit)
    shadow = Image.new("L", (W, H))
    sd = ImageDraw.Draw(shadow)
    mw = max(2, int(mortar * min(W, H)))
    for r in range(rows):
        shift = (bond * r % 1.0) * bw
        for c in range(cols):
            x0, y0 = c * bw + shift, r * bh
            k = 1 + jitter * (rnd.random() * 2 - 1)
            face = ImageChops.offset(fill, rnd.randrange(W), rnd.randrange(H)).point(lambda v, k=k: min(255, int(v * k)))
            for dx in (0, -W):
                box = [int(x0 + dx), int(y0), int(x0 + dx + bw), int(y0 + bh)]
                m = Image.new("L", (W, H))
                ImageDraw.Draw(m).rectangle([box[0], box[1], box[2] - 1, box[3] - 1], fill=255)
                img.paste(face, mask=m)
                jd.rectangle([box[0], box[1], box[2] - 1, box[1] + mw - 1], fill=255)
                jd.rectangle([box[0], box[1], box[0] + mw - 1, box[3] - 1], fill=255)
                ld.rectangle([box[0] + mw, box[1] + mw, box[2] - 1, box[1] + 2 * mw - 1], fill=255)
                ld.rectangle([box[0] + mw, box[1] + mw, box[0] + 2 * mw - 1, box[3] - 1], fill=255)
                sd.rectangle([box[0] + mw, box[3] - mw, box[2] - 1, box[3] - 1], fill=255)
                sd.rectangle([box[2] - mw, box[1] + mw, box[2] - 1, box[3] - 1], fill=255)
    soft = lambda m: tiled(m, lambda b: b.filter(ImageFilter.GaussianBlur(s * 0.4)))
    img = Image.composite(img.point(lambda v: min(255, int(v * 1.25))), img, soft(lit).point(lambda v: v // 2))
    img = Image.composite(img.point(lambda v: int(v * 0.6)), img, soft(shadow).point(lambda v: v // 2))
    img = Image.composite(img.point(lambda v: int(v * 0.35)), img, soft(joint))
    credit(name, "ambientCG %s (CC0), drawn %dx%d blocks" % (asset, cols, rows))
    return match(img, ref, spread)


def lamp(size, color, on, shape):
    """A light fitting at 8x, drawn as a hot core in a dark housing; `on` false is the
    switched-off frame of a +0/+a pair."""
    s = 8
    W, H = size[0] * s, size[1] * s
    img = Image.new("RGB", (W, H), (18, 18, 20))
    d = ImageDraw.Draw(img)
    hot = color if on else tuple(int(c * 0.28) for c in color)
    core = tuple(min(255, int(c * 0.35 + 255 * 0.65)) for c in hot) if on else hot
    if shape == "square":
        d.rectangle([s, s, W - s - 1, H - s - 1], fill=(58, 60, 64))
        d.rectangle([3 * s, 3 * s, W - 3 * s - 1, H - 3 * s - 1], fill=hot)
        glow = Image.new("L", (W, H))
        ImageDraw.Draw(glow).ellipse([W * 0.28, H * 0.28, W * 0.72, H * 0.72], fill=255)
        img.paste(core, mask=glow.filter(ImageFilter.GaussianBlur(W * 0.08)))
        for i in (W // 3, 2 * W // 3):
            d.line([(i, 3 * s), (i, H - 3 * s)], fill=(30, 30, 34), width=s)
            d.line([(3 * s, i), (W - 3 * s, i)], fill=(30, 30, 34), width=s)
    elif shape == "tubes":
        for cy in (H * 0.3, H * 0.7):
            d.rectangle([0, cy - H * 0.17, W, cy + H * 0.17], fill=(48, 50, 56))
            d.rectangle([s, cy - H * 0.09, W - s, cy + H * 0.09], fill=hot)
            d.line([(s, cy), (W - s, cy)], fill=core, width=max(1, int(H * 0.06)))
        for x in (0, W - 2 * s):
            d.rectangle([x, 0, x + 2 * s, H], fill=(70, 72, 78))
    elif shape == "panel":
        d.rectangle([0, 0, W - 1, H - 1], fill=(92, 94, 100))
        d.rectangle([2 * s, 2 * s, W - 2 * s - 1, H - 2 * s - 1], fill=(36, 38, 42))
        n = 6
        span = (W - 6 * s) / n
        for i in range(n):
            x0 = 3 * s + i * span
            d.rectangle([x0 + s, 3 * s, x0 + span - s, H - 3 * s], fill=hot)
            d.line([(x0 + span / 2, 4 * s), (x0 + span / 2, H - 4 * s)], fill=core, width=s)
    return img.resize(size, Image.LANCZOS)


def ladder(size, rail_asset):
    s = 8
    W, H = size[0] * s, size[1] * s
    wood = baked(rail_asset, (W, H), rotate=90, relief=0.4)
    mask = Image.new("L", (W, H))
    d = ImageDraw.Draw(mask)
    rail = W // 8
    d.rectangle([0, 0, rail, H], fill=255)
    d.rectangle([W - rail - 1, 0, W, H], fill=255)
    for cy in (H * 0.06, H * 0.56):
        d.rectangle([0, cy - rail * 0.45, W, cy + rail * 0.45], fill=255)
    img = wood.convert("RGBA")
    img.putalpha(mask)
    return img.resize(size, Image.LANCZOS)


def xbrace(ref, plate, frame_color):
    s = 4
    W, H = ref.width * s, ref.height * s
    img = match(baked(plate, (W, H), relief=0.6), ref.crop((16, 16, 112, 112)), 0.5)
    img = ImageChops.multiply(img, Image.new("RGB", (W, H), (120, 120, 125)))
    d = ImageDraw.Draw(img)
    b = W // 11
    d.rectangle([0, 0, W - 1, H - 1], outline=frame_color, width=b)
    d.rectangle([b, b, W - b - 1, H - b - 1], outline=tuple(c // 2 for c in frame_color), width=s)
    bar = Image.new("L", (W, H))
    bd = ImageDraw.Draw(bar)
    for p, q in (((b, b), (W - b, H - b)), ((W - b, b), (b, H - b))):
        bd.line([p, q], fill=255, width=int(W * 0.12))
    steel = Image.linear_gradient("L").resize((W, H)).rotate(45).point(lambda v: 150 + v // 3)
    img.paste(Image.merge("RGB", [steel] * 3), mask=bar.filter(ImageFilter.GaussianBlur(s)))
    hi = Image.new("L", (W, H))
    hd = ImageDraw.Draw(hi)
    for p, q in (((b, b), (W - b, H - b)), ((W - b, b), (b, H - b))):
        hd.line([p, q], fill=255, width=int(W * 0.03))
    img.paste((235, 238, 245), mask=hi.filter(ImageFilter.GaussianBlur(s * 1.5)))
    return img.resize(ref.size, Image.LANCZOS)


# --- recipe helpers -------------------------------------------------------------

def credit(name, source):
    credits[name] = source


def photo(name, asset, spread=0.8, **kw):
    ref = original(name)
    img = match(baked(asset, (ref.width * 2, ref.height * 2), **kw), ref, spread)
    credit(name, "ambientCG %s (CC0)" % asset)
    return img


def lamp_recipe(name, color, on, shape):
    credit(name, "drawn: light fitting")
    return lamp(original(name).size, color, on, shape)




# --- drawing --------------------------------------------------------------------------
# Drawn recipes work at S times the original; texture_art.main saves them at its size.

S = 4
FONTS = {
    "stencil": ("BlackOpsOne-Regular.ttf", "ofl/blackopsone/BlackOpsOne-Regular.ttf"),
    "label": ("RobotoCondensed.ttf", "ofl/robotocondensed/RobotoCondensed%5Bwght%5D.ttf"),
}


def sized(name, s=S):
    ref = original(name)
    return ref, (ref.width * s, ref.height * s)


def material(asset, size, ref=None, spread=0.8, **kw):
    img = baked(asset, size, **kw)
    return match(img, ref, spread) if ref is not None else img


def mean_color(img, mask=None):
    return tuple(int(c) for c in ImageStat.Stat(img.convert("RGB"), mask).mean)


def font(kind, size):
    """An OFL font from google/fonts, cached under build/fonts."""
    fname, path = FONTS[kind]
    local = os.path.join(ROOT, "build", "fonts", fname)
    if not os.path.exists(local):
        os.makedirs(os.path.dirname(local), exist_ok=True)
        req = urllib.request.Request("https://github.com/google/fonts/raw/main/" + path,
                                     headers={"User-Agent": "wizardwars-texture-art"})
        with urllib.request.urlopen(req) as r, open(local, "wb") as f:
            f.write(r.read())
    f = ImageFont.truetype(local, size)
    if kind == "label":
        f.set_variation_by_name("Bold")
    return f


def text(img, box, line, kind="stencil", fill=(20, 20, 20), shadow=None):
    """`line` as large as fits in box, centred."""
    x0, y0, x1, y1 = box
    d = ImageDraw.Draw(img)
    size = int(y1 - y0)
    while size > 4:
        f = font(kind, size)
        l, t, r, b = d.textbbox((0, 0), line, font=f)
        if r - l <= x1 - x0 and b - t <= y1 - y0:
            break
        size -= 1
    x = (x0 + x1 - (r - l)) / 2 - l
    y = (y0 + y1 - (b - t)) / 2 - t
    if shadow:
        o = max(1, size // 16)
        d.text((x + o, y + o), line, font=f, fill=shadow)
    d.text((x, y), line, font=f, fill=fill)


def emboss(img, height, k=1.0, blur=2.0, d=1):
    """Light img as if `height` (L, white = raised) were its relief, from up-left. Wraps, so a
    tile stays a tile."""
    h = tiled(height, lambda b: b.filter(ImageFilter.GaussianBlur(blur))) if blur else height
    lit = ImageChops.subtract(ImageChops.offset(h, -d, -d), ImageChops.offset(h, d, d), 1, 128)
    lit = lit.point(lambda v: max(0, min(255, int(128 + (v - 128) * k))))
    mode = img.mode
    rgb = ImageChops.add(img.convert("RGB"), Image.merge("RGB", [lit] * 3), 1, -128)
    if mode == "RGBA":
        rgb.putalpha(img.getchannel("A"))
    return rgb


def darken(img, mask, k):
    """Scale img's brightness by k where mask is white."""
    return Image.composite(img.point(lambda v: max(0, min(255, int(v * k)))), img, mask)


def rect_mask(size, boxes, radius=0, blur=0):
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    for b in boxes:
        d.rounded_rectangle([int(v) for v in b], radius=radius, fill=255)
    return m.filter(ImageFilter.GaussianBlur(blur)) if blur else m


def rivet(img, x, y, r, color=(140, 140, 135)):
    d = ImageDraw.Draw(img)
    d.ellipse([x - r, y - r + r * 0.35, x + r, y + r + r * 0.35], fill=(18, 18, 18))
    d.ellipse([x - r, y - r, x + r, y + r], fill=color)
    hi = tuple(min(255, c + 70) for c in color)
    d.ellipse([x - r * 0.55, y - r * 0.55, x + r * 0.05, y + r * 0.05], fill=hi)


def corner_rivets(img, inset, r, color=(140, 140, 135)):
    W, H = img.size
    for x in (inset, W - inset):
        for y in (inset, H - inset):
            rivet(img, x, y, r, color)


def feather(size, inset):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rectangle([inset, inset, size[0] - inset - 1, size[1] - inset - 1], fill=255)
    return m.filter(ImageFilter.GaussianBlur(inset / 2))


def random_tiles(base, n, seed=1):
    """GoldSrc lays -0..-N variants at random per tile, so each must meet every other at the
    edges: each is base with its interior swapped for another part of the same tile."""
    rnd = random.Random(seed)
    W, H = base.size
    mask = feather(base.size, min(W, H) // 5)
    out = [base]
    for _ in range(1, n):
        alt = ImageChops.offset(base, rnd.randrange(W // 4, 3 * W // 4), rnd.randrange(H // 4, 3 * H // 4))
        out.append(Image.composite(alt, base, mask))
    return out


def palette_of(ref, n):
    """The n main colours of ref, most common first."""
    q = ref.convert("RGB").quantize(colors=n, method=Image.Quantize.MEDIANCUT)
    pal = q.getpalette()
    counts = sorted(q.getcolors(), reverse=True)
    return [tuple(pal[i * 3:i * 3 + 3]) for _, i in counts]


def vertical_gradient(size, stops):
    """stops: [(t, (r, g, b)), ...] with t from 0 (top) to 1 (bottom)."""
    W, H = size
    img = Image.new("RGB", size)
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / max(1, H - 1)
        for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
            if t0 <= t <= t1:
                u = (t - t0) / max(1e-6, t1 - t0)
                d.line([(0, y), (W, y)], fill=tuple(int(a + (b - a) * u) for a, b in zip(c0, c1)))
                break
    return img


def curve(d, pts, width, fill):
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        d.line([(x0, y0), (x1, y1)], fill=fill, width=max(1, int(width)))
        d.ellipse([x1 - width / 2, y1 - width / 2, x1 + width / 2, y1 + width / 2], fill=fill)


def branch(d, x, y, ang, length, width, depth, rnd, fill, leaves=None):
    """A recursive branch from (x, y); ang in radians, 0 = up."""
    pts = [(x, y)]
    for i in range(6):
        ang += rnd.uniform(-0.25, 0.25)
        x += math.sin(ang) * length / 6
        y -= math.cos(ang) * length / 6
        pts.append((x, y))
    curve(d, pts, width, fill)
    if leaves:
        leaves(pts)
    if depth > 0:
        for _ in range(rnd.randint(2, 3)):
            i = rnd.randint(2, 5)
            branch(d, pts[i][0], pts[i][1], ang + rnd.uniform(-0.9, 0.9), length * rnd.uniform(0.5, 0.75),
                   width * 0.65, depth - 1, rnd, fill, leaves)


# --- recipe builders --------------------------------------------------------------------
# Each takes the texture name and returns an image at some multiple of its size.

def photo_set(names, asset, spread=0.8, seed=1, **kw):
    """A -0..-N random-tiling set from one material."""
    ref = original(names[0])
    base = match(baked(asset, (ref.width * 2, ref.height * 2), **kw), ref, spread)
    for n in names:
        credit(n, "ambientCG %s (CC0), random-tile set" % asset)
    return dict(zip(names, random_tiles(base, len(names), seed)))


def flat(name, grain="Plaster001", spread=1.0):
    """A plain colour, given the original's grain (none when the original has none)."""
    ref = original(name)
    credit(name, "drawn: flat colour")
    return match(baked(grain, (ref.width * 2, ref.height * 2)), ref, spread)


def gradient(name):
    ref = original(name).convert("RGB")
    W, H = ref.size
    stops = [(t, mean_color(ref.crop((0, int(t * (H - 1)), W, int(t * (H - 1)) + 1)))) for t in (0, 0.25, 0.5, 0.75, 1)]
    credit(name, "drawn: gradient")
    return vertical_gradient((W * 2, H * 2), stops)


def tool(name, color, stripe=None):
    """Tool textures are never drawn in game; they only need to be recognisable in an editor."""
    ref, (W, H) = sized(name)
    img = Image.new("RGB", (W, H), color)
    if stripe:
        d = ImageDraw.Draw(img)
        for i in range(-H, W, W // 4):
            d.line([(i, H), (i + H, 0)], fill=stripe, width=W // 10)
    credit(name, "drawn: tool texture")
    return img


def empty(name):
    ref = original(name)
    credit(name, "drawn: fully transparent")
    return Image.new("RGBA", ref.size, (0, 0, 0, 0))


def trim(name, asset, rivets=0, grooves=2, spread=0.8, round_=False):
    """A metal strip along its long axis: bevelled edges, optional rivets and grooves."""
    ref, (W, H) = sized(name)
    vertical = H > W
    img = material(asset, (W, H), ref, spread)
    h = Image.new("L", (W, H), 128)
    d = ImageDraw.Draw(h)
    L, T = (H, W) if vertical else (W, H)
    for g in range(1, grooves + 1):
        p = T * g / (grooves + 1)
        box = [p - T * 0.03, 0, p + T * 0.03, L] if vertical else [0, p - T * 0.03, L, p + T * 0.03]
        d.rectangle(box, fill=70)
    if round_:
        prof = Image.new("L", (W, H))
        prof.putdata([int(128 + 100 * math.sin(math.pi * ((x if vertical else y) / (T - 1)))) - 50
                      for y in range(H) for x in range(W)])
        h = ImageChops.add(h, prof, 1, -78)
    img = emboss(img, h, 1.4, S * 0.6)
    img = darken(img, ImageChops.invert(feather((W, H), max(1, T // 10))), 0.65)
    for i in range(rivets):
        p = L * (i + 0.5) / rivets
        rivet(img, T / 2 if vertical else p, p if vertical else T / 2, T * 0.14, mean_color(img))
    credit(name, "ambientCG %s (CC0), drawn trim" % asset)
    return img


def door(name, asset, panels=(1, 2), knob=None, spread=0.5, rotate=90, frame=0.1, glass=None):
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread, rotate=rotate)
    h = Image.new("L", (W, H), 150)
    d = ImageDraw.Draw(h)
    m = W * frame
    cols, rows = panels
    cw, ch = (W - 2 * m) / cols, (H - 2 * m) / rows
    boxes = []
    for c in range(cols):
        for r in range(rows):
            box = [m + c * cw + m * 0.35, m + r * ch + m * 0.35, m + (c + 1) * cw - m * 0.35, m + (r + 1) * ch - m * 0.35]
            boxes.append(box)
            d.rectangle(box, fill=70)
            d.rectangle([box[0] + m * 0.3, box[1] + m * 0.3, box[2] - m * 0.3, box[3] - m * 0.3], fill=130)
    d.rectangle([0, 0, W - 1, H - 1], outline=220, width=int(m * 0.5))
    img = emboss(img, h, 3.0, S * 0.6, S // 2)
    img = darken(img, h.point(lambda v: 255 if v < 80 else 0).filter(ImageFilter.GaussianBlur(S * 0.5)), 0.6)
    if glass:
        for box in boxes:
            pane = vertical_gradient((int(box[2] - box[0] - m * 0.6), int(box[3] - box[1] - m * 0.6)),
                                     [(0, glass), (1, tuple(c // 3 for c in glass))])
            img.paste(pane, (int(box[0] + m * 0.3), int(box[1] + m * 0.3)))
    if knob:
        kx = W * (0.85 if knob == "right" else 0.15)
        rivet(img, kx, H * 0.53, W * 0.05, (196, 160, 70))
    credit(name, "ambientCG %s (CC0), drawn door" % asset)
    return img


def crate(name, asset="Planks037A", spread=0.8, brace=None, hazard=False, sign=False, frame=0.11, metal=None):
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread)
    h = Image.new("L", (W, H), 110)
    d = ImageDraw.Draw(h)
    b = min(W, H) * frame
    d.rectangle([0, 0, W - 1, H - 1], outline=190, width=int(b))
    if brace in ("diag", "x"):
        d.line([(b, H - b), (W - b, b)], fill=170, width=int(b))
        if brace == "x":
            d.line([(b, b), (W - b, H - b)], fill=170, width=int(b))
    if brace == "h":
        for y in (H / 3, 2 * H / 3):
            d.rectangle([b, y - b / 2, W - b, y + b / 2], fill=170)
    if metal:
        frame_mask = Image.new("L", (W, H), 0)
        ImageDraw.Draw(frame_mask).rectangle([0, 0, W - 1, H - 1], outline=255, width=int(b))
        img.paste(material(metal, (W, H), None), mask=frame_mask)
    boards = h.point(lambda v: 255 if v > 150 else 0)
    img = Image.composite(img.point(lambda v: min(255, int(v * 1.25 + 12))), img, boards)
    gaps = ImageChops.subtract(boards.filter(ImageFilter.MaxFilter(2 * (S // 2) + 1)), boards)
    img = darken(img, gaps, 0.35)
    img = emboss(img, h, 2.4, S * 0.5, S // 2)
    if hazard:
        stripes = Image.new("RGB", (W, H), (230, 90, 20))
        sd = ImageDraw.Draw(stripes)
        for i in range(-H, W + H, int(b * 1.6)):
            sd.line([(i, 0), (i + H, H)], fill=(25, 20, 18), width=int(b * 0.6))
        band = Image.new("L", (W, H), 0)
        ImageDraw.Draw(band).rectangle([0, 0, W - 1, H - 1], outline=255, width=int(b * 0.8))
        img = Image.composite(ImageChops.multiply(stripes, img.point(lambda v: min(255, v + 90))), img, band)
    if sign:
        tri = [(W / 2, H * 0.24), (W * 0.27, H * 0.7), (W * 0.73, H * 0.7)]
        sd = ImageDraw.Draw(img)
        sd.polygon(tri, fill=(225, 95, 25), outline=(20, 15, 10), width=int(b * 0.35))
        sd.rectangle([W * 0.485, H * 0.38, W * 0.515, H * 0.56], fill=(20, 15, 10))
        sd.ellipse([W * 0.48, H * 0.6, W * 0.52, H * 0.64], fill=(20, 15, 10))
    credit(name, "ambientCG %s (CC0), drawn crate" % asset)
    return img


def slots(name, asset, n, spread=0.8):
    """A vent plate with n horizontal slots."""
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread)
    m = W * 0.12
    pitch = (H - 2 * m) / n
    boxes = [[m, m + i * pitch + pitch * 0.18, W - m, m + (i + 1) * pitch - pitch * 0.18] for i in range(n)]
    hole = rect_mask((W, H), boxes, radius=int(pitch * 0.3))
    h = ImageChops.invert(hole).point(lambda v: v * 3 // 4)
    img = emboss(img, h, 2.0, S)
    img = darken(img, hole, 0.08)
    credit(name, "ambientCG %s (CC0), drawn vent" % asset)
    return img


def corrugated(name, asset, ribs, vertical=True, spread=0.8, frame=0.0):
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread)
    L = W if vertical else H
    h = Image.new("L", (W, H))
    h.putdata([int(128 + 110 * math.sin(math.tau * ribs * (x if vertical else y) / L))
               for y in range(H) for x in range(W)])
    if frame:
        ImageDraw.Draw(h).rectangle([0, 0, W - 1, H - 1], outline=250, width=int(min(W, H) * frame))
    img = emboss(img, h, 1.2, 1)
    credit(name, "ambientCG %s (CC0), drawn corrugation" % asset)
    return img


def coffers(name, asset, cols, rows, spread=0.45):
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread)
    h = Image.new("L", (W, H), 180)
    d = ImageDraw.Draw(h)
    cw, ch = W / cols, H / rows
    for c in range(cols):
        for r in range(rows):
            for k, f in ((0.16, 120), (0.24, 90)):
                d.rectangle([c * cw + cw * k, r * ch + ch * k, (c + 1) * cw - cw * k, (r + 1) * ch - ch * k], fill=f)
    img = emboss(img, h, 3.0, S * 0.5, S // 2)
    credit(name, "ambientCG %s (CC0), drawn coffers" % asset)
    return img


def columns(name, asset, n, spread=0.4):
    """Fluted vertical columns."""
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread)
    shade = Image.new("L", (W, H))
    shade.putdata([int(255 * (0.35 + 0.65 * math.sin(math.pi * ((x * n / W) % 1)) ** 0.7)) for y in range(H) for x in range(W)])
    img = ImageChops.multiply(img, Image.merge("RGB", [shade] * 3)).point(lambda v: min(255, int(v * 1.3)))
    credit(name, "ambientCG %s (CC0), drawn columns" % asset)
    return img


def vbars(name, asset, n, gap=0.4, spread=0.6):
    """Round vertical bars with dark space between them."""
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread)
    shade = Image.new("L", (W, H))
    shade.putdata([int(255 * (0.08 if (x * n / W) % 1 > 1 - gap else 0.4 + 0.6 * math.sin(math.pi * ((x * n / W) % 1) / (1 - gap))))
                   for y in range(H) for x in range(W)])
    credit(name, "ambientCG %s (CC0), drawn bars" % asset)
    return ImageChops.multiply(img, Image.merge("RGB", [shade] * 3)).point(lambda v: min(255, int(v * 1.4)))


def window(name, frame_asset, cols, rows, glass=(40, 50, 90), spread=0.8, frame=0.09):
    ref, (W, H) = sized(name)
    img = material(frame_asset, (W, H), ref, spread)
    m = W * frame
    cw, ch = (W - 2 * m) / cols, (H - 2 * m) / rows
    bar = m * 0.35
    panes = [[m + c * cw + bar, m + r * ch + bar, m + (c + 1) * cw - bar, m + (r + 1) * ch - bar] for c in range(cols) for r in range(rows)]
    pane = vertical_gradient((W, H), [(0, tuple(min(255, v + 40) for v in glass)), (1, glass)])
    streak = Image.new("L", (W, H))
    streak.putdata([int(60 * max(0, math.sin((x + y) / W * 9))) for y in range(H) for x in range(W)])
    pane = ImageChops.add(pane, Image.merge("RGB", [streak] * 3))
    mask = rect_mask((W, H), panes)
    img = Image.composite(pane, img, mask)
    img = emboss(img, ImageChops.invert(mask), 1.5, S * 0.4)
    credit(name, "ambientCG %s (CC0), drawn window" % frame_asset)
    return img


def louvers(name, asset, leaves=2, spread=0.8):
    """Shutters: `leaves` side by side, each a frame of slanted slats."""
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread)
    h = Image.new("L", (W, H), 200)
    d = ImageDraw.Draw(h)
    lw = W / leaves
    m = lw * 0.12
    slat = lw * 0.12
    for i in range(leaves):
        x0, x1 = i * lw + m, (i + 1) * lw - m
        y = m
        while y + slat <= H - m:
            for k in range(int(slat)):
                d.line([(x0, y + k), (x1, y + k)], fill=int(40 + 170 * k / slat))
            y += slat
    img = emboss(img, h, 1.6, 1)
    credit(name, "ambientCG %s (CC0), drawn louvers" % asset)
    return img


def carpet(name, grain="Fabric061", seed=1):
    """A rug in the original's colours: border bands, a field of small diamonds, a medallion."""
    ref, (W, H) = sized(name)
    cols = palette_of(ref, 5)
    rnd = random.Random(seed)
    img = Image.new("RGB", (W, H), cols[0])
    d = ImageDraw.Draw(img)
    step = W / 16
    for gx in range(17):
        for gy in range(17):
            x, y = gx * step, gy * step
            d.polygon([(x, y - step * 0.3), (x + step * 0.3, y), (x, y + step * 0.3), (x - step * 0.3, y)], fill=cols[2 + (gx + gy) % 2])
    for k, c in ((0.0, cols[1]), (0.04, cols[3]), (0.07, cols[1]), (0.11, cols[4])):
        d.rectangle([W * k, H * k, W * (1 - k) - 1, H * (1 - k) - 1], outline=c, width=int(W * 0.03))
    cx, cy = W / 2, H / 2
    for r, c in ((0.3, cols[1]), (0.22, cols[3]), (0.12, cols[4]), (0.05, cols[2])):
        d.polygon([(cx, cy - H * r), (cx + W * r * 0.8, cy), (cx, cy + H * r), (cx - W * r * 0.8, cy)], fill=c)
    weave = baked(grain, (W, H)).convert("L").point(lambda v: 150 + v // 3)
    img = ImageChops.multiply(img, Image.merge("RGB", [weave] * 3)).point(lambda v: min(255, int(v * 1.25)))
    img = match(img, ref, 0.6)
    credit(name, "drawn rug, ambientCG %s (CC0) weave" % grain)
    return img


def roof_tiles(name, asset, cols, rows, spread=0.4):
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread)
    h = Image.new("L", (W, H))
    px = []
    for y in range(H):
        v = (y * rows / H) % 1
        for x in range(W):
            u = (x * cols / W) % 1
            px.append(int(255 * math.sin(math.pi * u) * (0.35 + 0.65 * v)))
    h.putdata(px)
    img = ImageChops.multiply(img, Image.merge("RGB", [h.point(lambda v: 40 + v * 215 // 255)] * 3)).point(lambda v: min(255, int(v * 1.5)))
    credit(name, "ambientCG %s (CC0), drawn roof tiles" % asset)
    return img


def sandbags(name, asset, rows, per_row, spread=0.8):
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread)
    h = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(h)
    bh = H / rows
    bw = W / per_row
    for r in range(rows):
        off = (r % 2) * bw / 2
        for c in range(-1, per_row + 1):
            x = c * bw + off
            for k in range(6, 0, -1):
                f = 255 - k * 35
                d.rounded_rectangle([x + k * bw * 0.02, r * bh + k * bh * 0.04, x + bw - k * bw * 0.02, (r + 1) * bh - k * bh * 0.04],
                                    radius=int(bh * 0.4), fill=255 - f + 40)
    img = emboss(img, h, 1.6, S)
    img = darken(img, h.point(lambda v: 255 if v < 30 else 0).filter(ImageFilter.GaussianBlur(S)), 0.35)
    credit(name, "ambientCG %s (CC0), drawn sandbags" % asset)
    return img


def books(name, spines=True, seed=1):
    ref, (W, H) = sized(name)
    rnd = random.Random(seed)
    cols = palette_of(ref, 6)
    img = Image.new("RGB", (W, H), cols[0])
    d = ImageDraw.Draw(img)
    if spines:
        x = 0
        while x < W:
            w = rnd.uniform(W * 0.07, W * 0.13)
            c = rnd.choice(cols)
            d.rectangle([x, 0, x + w - S * 0.5, H], fill=c)
            for y in (H * 0.2, H * 0.8):
                d.rectangle([x, y, x + w - S * 0.5, y + H * 0.06], fill=tuple(min(255, v + 60) for v in c))
            x += w
    else:
        d.rectangle([0, 0, W * 0.12, H], fill=tuple(v // 2 for v in cols[0]))
        for y in (0.3, 0.42, 0.75):
            d.rectangle([W * 0.3, H * y, W * 0.85, H * (y + 0.05)], fill=tuple(v // 2 for v in cols[0]))
    credit(name, "drawn books")
    return emboss(img, img.convert("L"), 0.6, 1)


def paper(name, seed=1, lines=True):
    ref, (W, H) = sized(name)
    rnd = random.Random(seed)
    img = Image.new("RGB", (W, H), mean_color(ref))
    img = Image.new("RGB", (W, H), tuple(min(255, c + 15) for c in palette_of(ref, 2)[0]))
    d = ImageDraw.Draw(img)
    if lines:
        y = H * 0.12
        while y < H * 0.9:
            d.rectangle([W * 0.12, y, W * rnd.uniform(0.55, 0.88), y + H * 0.02], fill=(110, 110, 110))
            y += H * 0.045
    else:
        for _ in range(6):
            x, y = rnd.uniform(0.2, 0.7) * W, rnd.uniform(0.2, 0.7) * H
            d.rectangle([x, y, x + W * 0.15, y + H * 0.08], fill=(140, 130, 90))
    credit(name, "drawn paper")
    return img


def pot(name):
    ref, (W, H) = sized(name)
    cols = palette_of(ref, 3)
    img = Image.new("RGB", (W, H), cols[1] if len(cols) > 1 else cols[0])
    d = ImageDraw.Draw(img)
    d.ellipse([W * 0.12, H * 0.12, W * 0.88, H * 0.88], fill=(70, 40, 25))
    d.ellipse([W * 0.2, H * 0.2, W * 0.8, H * 0.8], fill=(35, 22, 14))
    credit(name, "drawn pot")
    return emboss(img, img.convert("L"), 1.2, S)


def computer(name, knobs=(3, 3), seed=1):
    ref, (W, H) = sized(name)
    rnd = random.Random(seed)
    img = material("Metal024", (W, H), ref, 0.6)
    d = ImageDraw.Draw(img)
    kc, kr = knobs
    for c in range(kc):
        for r in range(kr):
            x = W * 0.1 + (c + 0.5) * W * 0.4 / kc
            y = H * 0.15 + (r + 0.5) * H * 0.7 / kr
            rivet(img, x, y, min(W, H) * 0.06, (170, 170, 175))
    for i in range(24):
        x = W * rnd.uniform(0.55, 0.92)
        y = H * rnd.uniform(0.15, 0.85)
        d.rectangle([x, y, x + S * 1.5, y + S], fill=rnd.choice([(230, 60, 40), (60, 220, 90), (240, 200, 60), (40, 40, 40)]))
    credit(name, "drawn control panel")
    return img


def lights(name, kind, color, on, asset="Metal024"):
    """Light fittings beyond lamp(): concentric rings, a single glow, a grid of cells."""
    ref, (W, H) = sized(name)
    hot = color if on else tuple(int(c * 0.25) for c in color)
    core = tuple(min(255, int(c * 0.35 + 255 * 0.65)) for c in hot) if on else hot
    img = Image.new("RGB", (W, H), (16, 16, 18))
    d = ImageDraw.Draw(img)
    if kind == "rings":
        cx, cy = W / 2, H / 2
        for i, r in enumerate((0.48, 0.38, 0.28, 0.18, 0.08)):
            d.ellipse([cx - W * r, cy - H * r, cx + W * r, cy + H * r], fill=(hot if i % 2 == 0 else (30, 30, 34)))
        d.ellipse([cx - W * 0.06, cy - H * 0.06, cx + W * 0.06, cy + H * 0.06], fill=core)
        for a in range(4):
            ang = a * math.pi / 2
            d.line([(cx, cy), (cx + math.cos(ang) * W * 0.5, cy + math.sin(ang) * H * 0.5)], fill=(40, 40, 46), width=int(W * 0.04))
    elif kind == "glow":
        base = Image.new("RGB", (W, H), tuple(int(c * 0.85) for c in hot))
        glow = Image.new("L", (W, H))
        ImageDraw.Draw(glow).ellipse([W * 0.2, H * 0.2, W * 0.8, H * 0.8], fill=255 if on else 60)
        img = Image.composite(Image.new("RGB", (W, H), core), base, glow.filter(ImageFilter.GaussianBlur(W * 0.15)))
    elif kind == "grid":
        n = 4
        cw = W / n
        for c in range(n):
            for r in range(n):
                box = [c * cw + cw * 0.14, r * cw + cw * 0.14, (c + 1) * cw - cw * 0.14, (r + 1) * cw - cw * 0.14]
                d.rectangle(box, fill=hot)
                d.rectangle([box[0] + cw * 0.15, box[1] + cw * 0.15, box[2] - cw * 0.25, box[3] - cw * 0.25], fill=core)
        img = img.filter(ImageFilter.GaussianBlur(S * 0.4))
    credit(name, "drawn: light fitting")
    return img


def switch_panel(name, label, color, on):
    ref, (W, H) = sized(name)
    img = material("Metal024", (W, H), ref, 0.5)
    h = Image.new("L", (W, H), 128)
    d = ImageDraw.Draw(h)
    d.rectangle([W * 0.1, H * 0.1, W * 0.9, H * 0.38], fill=100)
    d.rectangle([W * 0.28, H * 0.5, W * 0.72, H * 0.86], fill=170)
    img = emboss(img, h, 1.6, S * 0.5)
    text(img, (W * 0.13, H * 0.13, W * 0.87, H * 0.35), label, "label", fill=(25, 25, 28))
    lamp_c = color if on else tuple(c // 4 for c in color)
    pane = vertical_gradient((int(W * 0.36), int(H * 0.28)), [(0, tuple(min(255, c + 70) for c in lamp_c)), (1, lamp_c)])
    img.paste(pane, (int(W * 0.32), int(H * 0.54)))
    corner_rivets(img, W * 0.05, W * 0.025)
    credit(name, "drawn: switch panel")
    return img


def sign(name, lines, plate=(205, 130, 30), ink=(28, 22, 15)):
    ref, (W, H) = sized(name)
    grain = baked("Metal024", (W, H)).convert("L").point(lambda v: 170 + v // 3)
    img = ImageChops.multiply(Image.new("RGB", (W, H), plate), Image.merge("RGB", [grain] * 3))
    h = Image.new("L", (W, H), 150)
    ImageDraw.Draw(h).rectangle([0, 0, W - 1, H - 1], outline=220, width=int(min(W, H) * 0.06))
    img = emboss(img, h, 1.6, S * 0.6)
    n = len(lines)
    for i, line in enumerate(lines):
        y0 = H * 0.16 + i * H * 0.68 / n
        text(img, (W * 0.1, y0 + H * 0.03, W * 0.9, y0 + H * 0.68 / n - H * 0.03), line, "stencil", ink)
    corner_rivets(img, min(W, H) * 0.08, min(W, H) * 0.04, (170, 150, 110))
    credit(name, "drawn sign (Black Ops One, OFL)")
    return img


def laser(name, frame, frames=4, seed=3):
    """A falling beam; frames scroll its ripples down one period between them."""
    ref, (W, H) = sized(name)
    rnd = random.Random(seed)
    waves = [(rnd.uniform(1, 3), rnd.uniform(0, math.tau)) for _ in range(3)]
    lum = Image.new("L", (W, H))
    px = []
    for y in range(H):
        t = (y / H + frame / frames)
        for x in range(W):
            u = x / W
            core = math.exp(-((u - 0.5 - 0.06 * math.sin(math.tau * (t * 2 + 0.3))) / 0.22) ** 2)
            rip = sum(0.12 * math.sin(math.tau * (t * k * 4) + p + u * 6) for k, p in waves)
            px.append(int(255 * max(0.0, min(1.0, core * (0.75 + rip)))))
    lum.putdata(px)
    credit(name, "drawn: animated beam")
    return match(Image.merge("RGB", [lum] * 3), ref, 1.0)


def streaks(name, seed=1, spread=1.0):
    """Glass, or light falling through it: soft diagonal streaks."""
    ref, (W, H) = sized(name)
    rnd = random.Random(seed)
    bands = [(rnd.randint(1, 3), rnd.uniform(0, math.tau), rnd.uniform(0.3, 1)) for _ in range(5)]
    lum = Image.new("L", (W, H))
    lum.putdata([int(128 + 120 * sum(a * math.sin(math.tau * f * (x / W + y / H) + p) for f, p, a in bands) / 3)
                 for y in range(H) for x in range(W)])
    lum = tiled(lum, lambda b: b.filter(ImageFilter.GaussianBlur(S)))
    credit(name, "drawn: glass streaks")
    return match(Image.merge("RGB", [lum] * 3), ref, spread)


def crystal(name, seed=1):
    ref, (W, H) = sized(name)
    rnd = random.Random(seed)
    lum = Image.new("L", (W, H))
    waves = [(rnd.randint(1, 6), rnd.uniform(0, math.tau), rnd.uniform(10, 40)) for _ in range(5)]
    lum.putdata([int(min(255, max(0, 150 + 25 * math.sin(math.tau * y / H) + sum(a * math.sin(math.tau * f * x / W + p + 0.6 * math.sin(math.tau * y / H)) for f, p, a in waves))))
                 for y in range(H) for x in range(W)])
    d = ImageDraw.Draw(lum)
    for _ in range(14):
        x, y = rnd.uniform(0, W), rnd.uniform(0, H)
        pts = [(x, y)]
        for _ in range(4):
            x += rnd.uniform(-W * 0.2, W * 0.2)
            y += rnd.uniform(-H * 0.1, H * 0.2)
            pts.append((x, y))
        d.line(pts, fill=250, width=max(1, S // 2))
    credit(name, "drawn: crystal")
    return match(Image.merge("RGB", [lum.filter(ImageFilter.GaussianBlur(1))] * 3), ref, 1.0)


def cells(name, n, seed, edge=0.12, spread=1.0, invert=False, asset="Ground111"):
    """Organic cells (xen membrane, bubbly growth) from the caustics web."""
    ref, (W, H) = sized(name, 2)
    web = tiled(caustics((W, H), n, seed, edge), lambda b: b.filter(ImageFilter.GaussianBlur(1.5)))
    if invert:
        web = ImageChops.invert(web)
        img = emboss(Image.merge("RGB", [web] * 3), web, 1.5, 1)
        credit(name, "drawn: cells")
        return match(img, ref, spread)
    ground = match(baked(asset, (W, H)), ref, 0.6)
    veins = web.point(lambda v: 255 if v > 110 else int(v * 1.5))
    img = Image.composite(ground.point(lambda v: min(255, int(v * 1.3 + 12))), ground.point(lambda v: int(v * 0.85)), veins)
    credit(name, "drawn veins, ambientCG %s (CC0)" % asset)
    return emboss(img, veins, 2.0, 1.5)


def grid_holes(name, asset, cols, rows, bar=0.22, frame=0.0, spread=0.8, cross=None):
    """A grate: a bar lattice whose openings are holes."""
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread)
    f = min(W, H) * frame
    cw, ch = (W - 2 * f) / cols, (H - 2 * f) / rows
    holes = []
    for c in range(cols):
        for r in range(rows):
            holes.append([f + c * cw + cw * bar / 2, f + r * ch + ch * bar / 2, f + (c + 1) * cw - cw * bar / 2 - 1, f + (r + 1) * ch - ch * bar / 2 - 1])
    mask = ImageChops.invert(rect_mask((W, H), holes))
    if cross:
        d = ImageDraw.Draw(mask)
        d.rectangle([W / 2 - W * cross, 0, W / 2 + W * cross, H], fill=255)
        d.rectangle([0, H / 2 - H * cross, W, H / 2 + H * cross], fill=255)
    img = emboss(img, mask, 1.8, S * 0.8)
    if cross:
        for i in range(1, 8):
            rivet(img, W / 2, H * i / 8, W * cross * 0.4)
            rivet(img, W * i / 8, H / 2, W * cross * 0.4)
    img = img.convert("RGBA")
    img.putalpha(mask)
    credit(name, "ambientCG %s (CC0), drawn grate" % asset)
    return img


def bars(name, asset, n, spread=0.8):
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread)
    pitch = H / n
    mask = rect_mask((W, H), [[0, i * pitch + pitch * 0.25, W, i * pitch + pitch * 0.75] for i in range(n)])
    img = emboss(img, mask, 2.0, S * 0.5).convert("RGBA")
    img.putalpha(mask)
    credit(name, "ambientCG %s (CC0), drawn bars" % asset)
    return img


def lattice(name, asset, cols, rows, spread=0.8):
    """A wooden rail: a heavy frame round a lattice of small openings."""
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread)
    f = W * 0.1
    holes = []
    for half in (0, 1):
        y0 = f + half * (H - f) / 2
        hh = (H - 3 * f) / 2
        cw, ch = (W - 2 * f) / cols, hh / rows
        for c in range(cols):
            for r in range(rows):
                holes.append([f + c * cw + cw * 0.17, y0 + r * ch + ch * 0.17, f + (c + 1) * cw - cw * 0.17, y0 + (r + 1) * ch - ch * 0.17])
    mask = ImageChops.invert(rect_mask((W, H), holes))
    img = emboss(img, mask, 1.6, S * 0.6).convert("RGBA")
    img.putalpha(mask)
    credit(name, "ambientCG %s (CC0), drawn lattice" % asset)
    return img


def net(name, asset, cells_n, seed, spread=0.8):
    ref, (W, H) = sized(name, 2)
    web = tiled(caustics((W, H), cells_n, seed, 0.18, 0.04), lambda b: b.filter(ImageFilter.GaussianBlur(0.8)))
    mask = web.point(lambda v: 255 if v > 90 else 0)
    img = emboss(material(asset, (W, H), ref, spread), web, 1.5, 1).convert("RGBA")
    img.putalpha(mask)
    credit(name, "ambientCG %s (CC0), drawn net" % asset)
    return img


def foliage(name, kind, seed, color=None, asset="Bark001"):
    """Alpha-tested plants: grass tufts, shrubs, hanging vines, roots."""
    ref, (W, H) = sized(name)
    rnd = random.Random(seed)
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(mask)
    if kind == "grass":
        for _ in range(26):
            x = W * rnd.uniform(0.2, 0.8)
            ang = rnd.uniform(-0.6, 0.6)
            length = H * rnd.uniform(0.45, 0.95)
            pts, px, py = [], x, H - 1
            for i in range(10):
                pts.append((px, py))
                ang += ang * 0.08
                px += math.sin(ang) * length / 10
                py -= math.cos(ang) * length / 10
            for i, (a, b) in enumerate(zip(pts, pts[1:])):
                d.line([a, b], fill=255, width=max(1, int(W * 0.035 * (1 - i / 10))))
    elif kind == "shrub":
        for _ in range(6):
            branch(d, W * rnd.uniform(0.25, 0.75), H - 1, rnd.uniform(-0.7, 0.7), H * 0.5, W * 0.035, 4, rnd, 255)
    elif kind == "vine":
        def leaves(pts):
            for x, y in pts[1:]:
                if rnd.random() < 0.8:
                    d.ellipse([x - W * 0.025, y - W * 0.015, x + W * 0.025, y + W * 0.015], fill=255)
        for _ in range(6):
            x = W * rnd.uniform(0.05, 0.95)
            branch(d, x, 0, math.pi + rnd.uniform(-0.3, 0.3), H * rnd.uniform(0.4, 0.8), W * 0.012, 1, rnd, 255, leaves)
    elif kind == "roots":
        for _ in range(9):
            x, y = rnd.uniform(0, W), rnd.uniform(0, H)
            branch(d, x, y, rnd.uniform(0, math.tau), W * 0.6, W * 0.09, 2, rnd, 255)
    img = material(asset, (W, H), None)
    if color:
        img = ImageChops.multiply(img.point(lambda v: min(255, v + 80)), Image.new("RGB", (W, H), color))
    img = emboss(img, mask, 1.2, S * 0.4)
    img = match(img, ref, 0.6) if not color else img
    img = img.convert("RGBA")
    img.putalpha(mask)
    credit(name, "drawn %s, ambientCG %s (CC0)" % (kind, asset))
    return img


def decal(name, kind, seed):
    """Coverage for the decal ramp: alpha is how dark the mark is."""
    ref, (W, H) = sized(name)
    rnd = random.Random(seed)
    cov = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(cov)
    cx, cy = W / 2, H / 2
    if kind == "shot":
        for r, v in ((0.32, 90), (0.2, 170), (0.1, 250)):
            pts = [(cx + math.cos(a) * W * r * rnd.uniform(0.7, 1.2), cy + math.sin(a) * H * r * rnd.uniform(0.7, 1.2))
                   for a in [i * math.tau / 9 for i in range(9)]]
            d.polygon(pts, fill=v)
        cov = cov.filter(ImageFilter.GaussianBlur(S * 0.4))
    elif kind == "scorch":
        for _ in range(140):
            a = rnd.uniform(0, math.tau)
            r = rnd.uniform(0.1, 0.48) * W
            d.line([(cx, cy), (cx + math.cos(a) * r, cy + math.sin(a) * r)], fill=rnd.randint(60, 140), width=int(W * 0.03))
        cov = cov.filter(ImageFilter.GaussianBlur(W * 0.02))
        core = Image.new("L", (W, H), 0)
        ImageDraw.Draw(core).ellipse([W * 0.25, H * 0.25, W * 0.75, H * 0.75], fill=210)
        cov = ImageChops.lighter(cov, core.filter(ImageFilter.GaussianBlur(W * 0.08)))
    elif kind == "drip":
        for _ in range(9):
            x = rnd.uniform(0.05, 0.95) * W
            L = rnd.uniform(0.3, 0.95) * H
            w = rnd.uniform(0.02, 0.06) * W
            d.rectangle([x - w, 0, x + w, L], fill=rnd.randint(120, 220))
            d.ellipse([x - w * 1.4, L - w * 2, x + w * 1.4, L + w], fill=200)
        d.rectangle([0, 0, W, H * 0.15], fill=200)
        cov = cov.filter(ImageFilter.GaussianBlur(S * 0.5))
    elif kind == "crack":
        branch(d, W * 0.05, H * 0.6, math.pi / 2, W * 0.55, H * 0.06, 3, rnd, 230)
    credit(name, "drawn decal")
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    img.putalpha(cov)
    return img
