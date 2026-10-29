#!/usr/bin/env python3
"""Draw replacements for the stock Half-Life sprites in sprites/, one recipe per sprite.

  sprite_art.py [NAME ...]          draw the named sprites (all of them when none are given)
  sprite_art.py --sheet OUT [NAME]  original and replacement frames side by side, as a PNG

Every replacement keeps its original's header (orientation, texture format, bounding radius),
frame count, frame size and frame origins, so maps and code that name the sprite, its frame
rate or its frame count need no change. The originals are read from git as first committed;
only their per-frame brightness is used, so each drawing gives off the light the original did. sprites/CREDITS.md lists what this script drew. Needs Pillow.
"""

import math
import os
import random
import subprocess
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spr import Sprite  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPRITES = os.path.join(ROOT, "sprites")


def original(name):
    """The sprite as first committed: the stock art this replaces."""
    rel = "sprites/%s.spr" % name
    first = subprocess.run(["git", "log", "--diff-filter=A", "--format=%H", "--", rel], cwd=ROOT,
                           capture_output=True, text=True, check=True).stdout.split()[-1]
    data = subprocess.run(["git", "show", "%s:%s" % (first, rel)], cwd=ROOT,
                          capture_output=True, check=True).stdout
    return Sprite.parse(data)


# ---- drawing helpers: greyscale fields are lists of floats in 0..1, row by row ----

def lerp(a, b, t):
    return a + (b - a) * t


def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else hi if v > hi else v


def smooth(e0, e1, v):
    t = clamp((v - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)


def field(w, h, fn):
    """fn(u, v) over pixel centres, u and v in -1..1 (v down)."""
    return [fn((x + 0.5) / w * 2 - 1, (y + 0.5) / h * 2 - 1) for y in range(h) for x in range(w)]


def noise(w, h, cells, seed):
    """Smooth value noise that tiles in both directions; `cells` lattice points across."""
    rnd = random.Random(seed)
    cw, ch = cells, max(1, round(cells * h / w))
    grid = Image.new("L", (cw, ch))
    grid.putdata([rnd.randrange(256) for _ in range(cw * ch)])
    wrap = Image.new("L", (cw * 3, ch * 3))
    for i in range(3):
        for j in range(3):
            wrap.paste(grid, (i * cw, j * ch))
    big = wrap.resize((w * 3, h * 3), Image.Resampling.BICUBIC)
    return [p / 255 for p in big.crop((w, h, 2 * w, 2 * h)).tobytes()]


def fbm(w, h, seed, base=4, octaves=4):
    """Octaves of noise, normalised to 0..1."""
    out = [0.0] * (w * h)
    total = 0.0
    for o in range(octaves):
        amp = 0.5 ** o
        n = noise(w, h, base << o, seed * 31 + o)
        out = [a + b * amp for a, b in zip(out, n)]
        total += amp
    lo, hi = min(out), max(out)
    return [(v - lo) / (hi - lo) for v in out]


def ramp(stops):
    """0..1 -> RGB through (position, (r, g, b)) stops."""
    def at(t):
        t = clamp(t)
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if t <= p1:
                k = (t - p0) / (p1 - p0) if p1 > p0 else 0
                return tuple(round(lerp(a, b, k)) for a, b in zip(c0, c1))
        return stops[-1][1]
    return at


FIRE = ramp([(0, (0, 0, 0)), (0.25, (90, 12, 0)), (0.5, (220, 80, 10)), (0.75, (255, 180, 60)),
             (1, (255, 250, 220))])


BLAST = ramp([(0, (0, 0, 0)), (0.2, (110, 20, 0)), (0.45, (230, 110, 20)), (0.7, (255, 210, 120)),
              (1, (255, 250, 235))])
FLAME = ramp([(0, (0, 0, 0)), (0.3, (110, 25, 5)), (0.65, (230, 100, 30)), (1, (255, 190, 110))])


def to_image(w, h, vals, colour=(255, 255, 255)):
    """A greyscale field times a colour, or through a ramp when `colour` is callable."""
    im = Image.new("RGB", (w, h))
    if callable(colour):
        im.putdata([colour(v) for v in vals])
    else:
        im.putdata([tuple(round(clamp(v) * c) for c in colour) for v in vals])
    return im


def add(*ims):
    out = ims[0]
    for im in ims[1:]:
        out = ImageChops.add(out, im)
    return out


def glow(w, h, cx, cy, radius, colour, power=2.0):
    """A soft additive spot: brightness falls off as exp(-(d/radius)^power)."""
    return to_image(w, h, field(w, h, lambda u, v: math.exp(
        -((math.hypot((u - cx) * w / 2, (v - cy) * h / 2) / radius) ** power))), colour)


def rays(w, h, count, length, width, colour, seed, jitter=0.5, core=0.0):
    """Thin spikes out of the centre, of random length, plus an optional hot core."""
    rnd = random.Random(seed)
    spikes = [(rnd.uniform(0, math.tau), length * rnd.uniform(1 - jitter, 1)) for _ in range(count)]

    def fn(u, v):
        x, y = u * w / 2, v * h / 2
        d = math.hypot(x, y)
        a = math.atan2(y, x)
        s = 0.0
        for ang, ln in spikes:
            da = abs((a - ang + math.pi) % math.tau - math.pi)
            off = d * math.sin(min(da, math.pi / 2))
            if da < math.pi / 2:
                s = max(s, math.exp(-(off / width) ** 2) * clamp(1 - d / ln))
        if core:
            s = max(s, math.exp(-(d / core) ** 2))
        return s
    return to_image(w, h, field(w, h, fn), colour)


def specks(w, h, points, size=1.0, blur=0.6):
    """Additive dots: points are (x, y, (r, g, b)) in pixels."""
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    for x, y, c in points:
        d.ellipse((x - size / 2, y - size / 2, x + size / 2, y + size / 2), fill=c)
    return im.filter(ImageFilter.GaussianBlur(blur)) if blur else im


def scale(im, k):
    return im.point(lambda p: min(255, round(p * k)))


# ---- matching the original's light ----

def lum(im):
    px = im.convert("L").tobytes()
    return sum(px) / len(px)


def on_black(im):
    bg = Image.new("RGB", im.size)
    bg.paste(im.convert("RGB"), (0, 0), im.convert("RGBA").getchannel("A"))
    return bg


def match(frames, ref):
    """Each frame is scaled to the original's brightness at that frame, so an effect keeps the
    light curve the maps and code were tuned against. Gain only, so black stays black under
    additive blending; colour is the recipe's own (a per-channel gain turned white cores cyan)."""
    out = []
    for im, r in zip(frames, ref.to_images()):
        want, have = lum(on_black(r)), lum(im)
        out.append(scale(im, clamp(want / have, 0.25, 2.5)) if have > 0.2 else im)
    return out


# ---- recipes: name -> fn(w, h, n) returning n frames ----

def r_glow01(w, h, n):
    return [add(glow(w, h, 0, 0, w * 0.3, (200, 200, 200), 1.6),
                glow(w, h, 0, 0, 1.5, (255, 255, 255)))]


def r_flare1(w, h, n):
    return [add(glow(w, h, 0, 0, w * 0.32, (200, 120, 160), 1.5),
                rays(w, h, 40, w * 0.5, 0.7, (70, 45, 60), 11, jitter=0.6),
                glow(w, h, 0, 0, w * 0.16, (255, 235, 245), 2.5))]


def r_animglow01(w, h, n):
    return [add(glow(w, h, 0, 0, w * lerp(0.18, 0.3, (i * 0.37) % 1), (230, 230, 230), 1.3),
                rays(w, h, 16, w * 0.45, 0.9, (255, 255, 255), 100 + i, core=w * 0.08))
            for i in range(n)]


def r_muzzleflash3(w, h, n):
    return [add(glow(w, h, 0, 0, w * 0.2, (255, 120, 30), 1.5),
                rays(w, h, 14, w * 0.5, 1.3, (255, 170, 80), 7, core=w * 0.07),
                glow(w, h, 0, 0, w * 0.06, (255, 255, 230)))]


def r_flare6(w, h, n):
    frames = []
    for i in range(n):
        t = i / n
        ring = field(w, h, lambda u, v: math.exp(-((math.hypot(u, v) * w / 2 - 7 - 2 * math.sin(
            t * math.tau)) / 0.9) ** 2) * 0.7)
        frames.append(add(to_image(w, h, ring, (140, 230, 140)),
                          rays(w, h, 8, w * lerp(0.3, 0.5, 0.5 + 0.5 * math.cos(t * math.tau)),
                               0.6, (200, 255, 200), 40 + i % 4, jitter=0.4, core=w * 0.05),
                          glow(w, h, 0, 0, w * 0.12, (60, 160, 60))))
    return frames


def r_nhth1(w, h, n):
    return [add(rays(w, h, 70, w * 0.5, 0.7, (190, 110, 230), 300 + i, jitter=0.7),
                glow(w, h, 0, 0, w * 0.17, (170, 230, 255), 1.5),
                glow(w, h, 0, 0, w * 0.07, (255, 255, 255)))
            for i in range(n)]


def burst(w, h, n, seed, colours, core, count=500, spread=(0.25, 0.95), shrink=False, loop=False):
    """Teleport-style bloom: specks scattered on a disc around a growing core glow.
    colours(t) -> (speck colour, core colour); core(t) -> core radius as a fraction of w.
    A `loop` holds the specks still and ends one frame short of where it starts."""
    rnd = random.Random(seed)
    parts = [(rnd.uniform(0, math.tau), rnd.uniform(*spread), rnd.uniform(0.3, 1.0),
              rnd.uniform(0, 1)) for _ in range(count)]
    frames = []
    for i in range(n):
        t = i / n if loop else i / max(n - 1, 1)
        speck, ccol = colours(t)
        pts = []
        for ang, r, b, phase in parts:
            rr = r * (0.8 if loop else 1 - 0.5 * t if shrink else 0.6 + 0.4 * t) * w / 2
            k = b * (0.6 + 0.4 * math.sin((t * 3 + phase) * math.tau))
            pts.append((w / 2 + rr * math.cos(ang), h / 2 + rr * math.sin(ang),
                        tuple(round(c * k) for c in speck)))
        r = max(core(t) * w, 0.5)
        frames.append(add(specks(w, h, pts, 1.2, 0.5), glow(w, h, 0, 0, r, ccol, 1.6),
                          glow(w, h, 0, 0, r * 0.45, (255, 255, 255), 2.0)))
    return frames


def r_b_tele1(w, h, n):
    speck = ramp([(0, (40, 60, 255)), (0.5, (60, 220, 200)), (1, (220, 255, 230))])
    core = ramp([(0, (60, 200, 230)), (0.45, (80, 235, 130)), (1, (255, 255, 255))])
    return burst(w, h, n, 1, lambda t: (speck(t), core(t)),
        lambda t: 0.04 + 0.22 * math.sin(math.pi * min(t * 1.3, 1)), shrink=True)


def r_c_tele1(w, h, n):
    return burst(w, h, n, 2, lambda t: ((110, 80, 40), (255, 190, 100)),
                 lambda t: 0.04 + 0.26 * math.sin(math.pi * min(t * 1.1, 1)) ** 0.7, count=120)


def r_d_tele1(w, h, n):
    hot = ramp([(0, (200, 20, 10)), (0.5, (255, 200, 30)), (1, (255, 255, 245))])
    return burst(w, h, n, 3, lambda t: (hot(t * 0.8), hot(t)),
                 lambda t: 0.08 + 0.2 * t, count=250, spread=(0.3, 0.7))


def r_e_tele1(w, h, n):
    return burst(w, h, n, 4, lambda t: ((220, 140, 60), (200, 120, 150)),
                 lambda t: 0.16 + 0.02 * math.sin(t * 9), count=700, spread=(0.3, 0.95), loop=True)


def r_cnt1(w, h, n):
    return burst(w, h, n, 5, lambda t: ((30, 150, 70), (90, 220, 140)),
                 lambda t: 0.2 + 0.02 * math.sin(t * 7), count=900, spread=(0.3, 0.95), loop=True)


def r_enter1(w, h, n):
    frames = []
    for i in range(n):
        tex = fbm(w, h, 50 + i, base=6)
        a = i / n * math.tau
        rs = field(w, h, lambda u, v: math.hypot(u, v))
        ring = [math.exp(-((r - 0.62) / 0.24) ** 2) * (0.5 + 0.7 * t) for r, t in zip(rs, tex)]
        core = [math.exp(-(r / 0.28) ** 2) * (0.7 + 0.5 * t) for r, t in zip(rs, tex)]
        img = add(to_image(w, h, ring, (230, 100, 30)), to_image(w, h, core, (150, 230, 40)),
                  glow(w, h, 0.05 * math.cos(a), 0.05 * math.sin(a), w * 0.06, (255, 255, 120)))
        frames.append(img)
    return frames


def fireball(w, h, n, seed, life, colour=BLAST, cx=0.0, cy=0.0, rise=0.0, size=0.9):
    """An explosion: a noisy blob that swells and cools. life(t) -> (radius, heat)."""
    tex = [fbm(w, h, seed * 10 + k, base=5) for k in range(3)]
    frames = []
    for i in range(n):
        t = i / max(n - 1, 1)
        radius, heat = life(t)
        nz = [lerp(a, b, (t * 2) % 1) for a, b in zip(tex[int(t * 2) % 3], tex[(int(t * 2) + 1) % 3])]
        oy = cy - rise * t

        def fn(u, v, k):
            d = math.hypot(u - cx, (v - oy) * h / w) / max(radius * size, 1e-3)
            dens = smooth(1.0, 0.3, d + (k - 0.5) * 0.9)
            return clamp(dens * (0.4 + 0.8 * k) * heat + smooth(0.45, 0.0, d) * 0.35 * heat)
        vals = [fn((x + 0.5) / w * 2 - 1, (y + 0.5) / h * 2 - 1, nz[y * w + x])
                for y in range(h) for x in range(w)]
        frames.append(to_image(w, h, vals, colour))
    return frames


def r_zerogxplode(w, h, n):
    return fireball(w, h, n, 1, lambda t: (0.25 + 0.95 * t ** 0.5, 1.0 - 0.45 * t), rise=0.15)


def r_fexplo1(w, h, n):
    frames = fireball(w, h, n, 2, lambda t: (0.2 + 0.8 * t ** 0.5, 1.0 - 0.6 * t), size=0.8)
    for i in (1, 2, 3):
        k = (0.5, 1.0, 0.6)[i - 1]
        streak = field(w, h, lambda u, v: math.exp(-(v * h / 2 / 1.2) ** 2) * clamp(1 - abs(u)) * k)
        frames[i] = add(frames[i], to_image(w, h, streak, (255, 220, 160)))
    return frames


def r_mushroom(w, h, n):
    frames = []
    stem = fireball(w, h, n, 3, lambda t: (0.3 + 0.3 * t, 1.0 - 0.5 * t), cy=0.65, rise=0.6)
    cap = fireball(w, h, n, 4, lambda t: (0.2 + 0.6 * t, 1.0 - 0.5 * t), cy=0.55, rise=1.1)
    for i in range(n):
        frames.append(ImageChops.lighter(stem[i], cap[i]))
    return frames


def r_bm1(w, h, n):
    rnd = random.Random(9)
    chunks = [(rnd.uniform(0, math.tau), rnd.uniform(0, 1) ** 0.7, rnd.uniform(1.0, 2.6)) for _ in range(90)]
    frames = []
    for i in range(n):
        t = (i + 1) / n
        im = Image.new("RGB", (w, h))
        d = ImageDraw.Draw(im)
        for ang, r, s in chunks:
            rr = r * t ** 0.5 * w * 0.45
            x, y = w / 2 + rr * math.cos(ang), h / 2 + rr * math.sin(ang) * 0.8
            shade = rnd.uniform(0.35, 1.0)
            c = (round(50 * shade), round(150 * shade), round(130 * shade))
            d.ellipse((x - s, y - s, x + s, y + s), fill=tuple(min(255, v) for v in c))
        frames.append(im.filter(ImageFilter.GaussianBlur(0.6)))
    return frames


def puff(w, h, n, seed, life, colour=(200, 200, 200)):
    """A smoke ball: noise inside a soft disc. life(t) -> (radius, density)."""
    tex = fbm(w, h, seed, base=5)
    frames = []
    for i in range(n):
        t = i / max(n - 1, 1)
        radius, dens = life(t)
        rs = field(w, h, lambda u, v: math.hypot(u, v))
        shift = int(t * w * 0.25)
        vals = []
        for k in range(w * h):
            q = tex[(k + shift) % len(tex)]
            vals.append(smooth(1.0, 0.3, rs[k] / max(radius, 1e-3) + (q - 0.5) * 0.7)
                        * (0.15 + 0.85 * q ** 1.4) * dens)
        frames.append(to_image(w, h, vals, colour))
    return frames


def r_ballsmoke(w, h, n):
    return puff(w, h, n, 21, lambda t: (0.8 + 0.15 * t, 1.0 - 0.6 * t))


r_poison = r_ballsmoke   # the mod's poison.spr was a copy of ballsmoke.spr


def r_stmbal1(w, h, n):
    return puff(w, h, n, 22, lambda t: (0.5 + 0.5 * t ** 0.7, smooth(0, 0.1, t) * (1.0 - 0.5 * t)))


def scroll_noise(w, h, n, step, seed, base):
    """Noise that loops when scrolled up `step` rows a frame for n frames: period n*step."""
    period = n * step
    big = fbm(w, period, seed, base=base)
    return lambda i, x, y: big[((y + i * step) % period) * w + x]


def r_fire(w, h, n):
    lo = scroll_noise(w, h, n, 7, 31, 3)
    hi = scroll_noise(w, h, n, 14, 32, 6)
    frames = []
    for i in range(n):
        vals = []
        for y in range(h):
            up = 1 - (y + 0.5) / h          # 0 at the base, 1 at the tip
            for x in range(w):
                u = (x + 0.5) / w * 2 - 1
                # broad shapes stretched 2x up the flame, dark streaks between tongues 4x
                k = 0.5 * lo(i, x, y // 2) + 0.5 * hi(i, x, y // 4)
                edge = abs(u) / (1.1 - 0.55 * up)
                vals.append(smooth(1.0, 0.3, edge + (k - 0.5) * 0.6)
                            * smooth(1.1, 0.25, up + (k - 0.5) * 0.9)
                            * (0.5 + 0.7 * k) * (1 - 0.3 * up))
        frames.append(to_image(w, h, vals, FLAME))
    return frames


r_firez = r_fire   # firez.spr is fire.spr upright; the header keeps that


def r_xsmoke3(w, h, n):
    tex = scroll_noise(w, h, n, 3, 41, 4)
    frames = []
    for i in range(n):
        vals = []
        for y in range(h):
            up = 1 - (y + 0.5) / h
            for x in range(w):
                u = (x + 0.5) / w * 2 - 1 + 0.25 * math.sin(up * 5 + i * 0.4)
                vals.append(smooth(0.2, 0.55, tex(i, x, y) * (1 - abs(u) * (1.5 - up))) * (1 - up * 0.4))
        frames.append(to_image(w, h, vals))
    return frames


def r_smoke(w, h, n):
    """An env_beam texture: it tiles down its length and scrolls, so the noise wraps in v."""
    frames = []
    for i in range(n):
        tex = fbm(w, h, 60 + i, base=3)
        vals = [math.exp(-(((k % w) + 0.5) / w * 2 - 1) ** 2 / 0.35) * (0.4 + 0.6 * tex[k])
                for k in range(w * h)]
        frames.append(to_image(w, h, vals))
    return frames


def r_laserbeam(w, h, n):
    tex = fbm(w, h, 70, base=2, octaves=2)
    return [to_image(w, h, [math.exp(-((((k % w) + 0.5) / w * 2 - 1) / 0.5) ** 2)
                            * (0.9 + 0.1 * tex[k]) for k in range(w * h)])]


def r_lgtning(w, h, n):
    frames = []
    for i in range(n):
        rnd = random.Random(80 + i)
        # A zigzag that starts and ends at the same x, so the beam tiles down its length.
        xs = [0.0] + [rnd.uniform(-0.4, 0.4) * (0.4 + 0.6 * (j % 2)) for j in range(13)] + [0.0]
        def at(v, xs=xs):
            p = (v + 1) / 2 * (len(xs) - 1)
            j = min(int(p), len(xs) - 2)
            return lerp(xs[j], xs[j + 1], p - j)
        vals = field(w, h, lambda u, v: math.exp(-((u - at(v)) * w / 2 / 0.7) ** 2)
                     + 0.3 * math.exp(-((u - at(v)) * w / 2 / 3.5) ** 2)
                     + 0.12 * math.exp(-(u * w / 2 / 9) ** 2))
        frames.append(to_image(w, h, vals, ramp([(0, (0, 0, 0)), (0.4, (60, 140, 160)),
                                                 (1, (235, 255, 255))])))
    return frames


def r_xspark1(w, h, n, colour=(80, 200, 255), seed=90):
    frames = []
    for i in range(n):
        tex = fbm(w, h, seed + i, base=4)
        rs = field(w, h, lambda u, v: math.hypot(u, v))
        vals = [clamp(math.exp(-(r / 0.45) ** 2) * (0.6 + 0.8 * t)) for r, t in zip(rs, tex)]
        frames.append(add(to_image(w, h, vals, colour), glow(w, h, 0, 0, w * 0.12, (255, 255, 255))))
    return frames


def r_xspark4(w, h, n):
    return r_xspark1(w, h, n, (255, 150, 30), 95)


def sparkle(w, h, n, seed, count, grow):
    rnd = random.Random(seed)
    pts = [(rnd.uniform(0, math.tau), rnd.uniform(0.1, 1), rnd.uniform(0.4, 1)) for _ in range(count)]
    frames = []
    for i in range(n):
        t = i / max(n - 1, 1)
        rr = grow(t)
        frames.append(add(specks(w, h, [(w / 2 + r * rr * w / 2 * math.cos(a), h / 2 + r * rr * h / 2
                                         * math.sin(a), tuple(round(c * b * (1 - 0.5 * t))
                                                              for c in (150, 220, 255)))
                                        for a, r, b in pts], 1.0, 0.3),
                          glow(w, h, 0, 0, w * 0.06 * (1 - t) + 0.5, (220, 255, 255))))
    return frames


def r_xspark2(w, h, n):
    return sparkle(w, h, n, 91, 30, lambda t: 0.2 + 0.8 * t)


def r_xspark3(w, h, n):
    return sparkle(w, h, n, 92, 45, lambda t: 0.7 + 0.3 * t)


def r_bhit(w, h, n):
    """Alpha-tested: a small white splinter star, hole everywhere else."""
    frames = []
    for i in range(n):
        rnd = random.Random(110 + i)
        im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        for _ in range(5):
            a = rnd.uniform(0, math.tau)
            ln = rnd.uniform(4, 7.5)
            d.line((w / 2, h / 2, w / 2 + ln * math.cos(a), h / 2 + ln * math.sin(a)),
                   fill=(235, 235, 235, 255), width=1)
        d.ellipse((w / 2 - 1.5, h / 2 - 1.5, w / 2 + 1.5, h / 2 + 1.5), fill=(255, 255, 255, 255))
        frames.append(im)
    return frames


def r_moths(w, h, n):
    rnd = random.Random(120)
    moths = [(rnd.uniform(4, w - 4), rnd.uniform(4, h - 4), rnd.uniform(2, 4), rnd.uniform(0, math.tau))
             for _ in range(4)]
    frames = []
    for i in range(n):
        a = i / n * math.tau
        pts = [(x + amp * math.cos(a + ph), y + amp * 0.6 * math.sin(2 * (a + ph)), (230, 225, 170))
               for x, y, amp, ph in moths]
        frames.append(specks(w, h, pts, 2.2, 0.4))
    return frames


def r_sdrip1(w, h, n):
    frames = []
    for i in range(n):
        t = i / max(n - 1, 1)
        y = 2 + t * t * (h - 4)
        frames.append(specks(w, h, [(w / 2, y, (120, 200, 160))], 1.6, 0.5))
    return frames


RECIPES = {
    "animglow01": r_animglow01, "b-tele1": r_b_tele1, "ballsmoke": r_ballsmoke, "bhit": r_bhit,
    "bm1": r_bm1, "c-tele1": r_c_tele1, "cnt1": r_cnt1, "d-tele1": r_d_tele1, "e-tele1": r_e_tele1,
    "enter1": r_enter1, "fexplo1": r_fexplo1, "fire": r_fire, "firez": r_firez, "flare1": r_flare1,
    "flare6": r_flare6, "glow01": r_glow01, "laserbeam": r_laserbeam, "lgtning": r_lgtning,
    "moths": r_moths, "mushroom": r_mushroom, "muzzleflash3": r_muzzleflash3, "nhth1": r_nhth1,
    "poison": r_poison, "sdrip1": r_sdrip1, "smoke": r_smoke, "stmbal1": r_stmbal1,
    "xsmoke3": r_xsmoke3, "xspark1": r_xspark1, "xspark2": r_xspark2, "xspark3": r_xspark3,
    "xspark4": r_xspark4, "zerogxplode": r_zerogxplode,
}


def draw(name):
    ref = original(name)
    imgs = ref.images()
    frames = RECIPES[name](imgs[0].width, imgs[0].height, len(imgs))
    if ref.format != 3:
        frames = match(frames, ref)
    out = Sprite(ref.type, ref.format, list(ref.images()), ref.palette, ref.radius,
                 ref.beam_length, ref.sync)
    out.set_images(frames)
    return ref, out


def sheet(path, names):
    rows = []
    for name in names:
        ref = original(name)
        new = Sprite.load(os.path.join(SPRITES, name + ".spr"))
        a, b = ref.to_images(), new.to_images()
        pick = sorted({round(k * (len(a) - 1) / 7) for k in range(8)})
        rows.append((name, [a[k] for k in pick], [b[k] for k in pick]))
    cell = max(max(im.width for im in r[1]) for r in rows) + 6
    heights = [max(im.height for im in r[1]) for r in rows]
    out = Image.new("RGB", (100 + 16 * cell + 20, sum(heights) + 14 * len(rows)), (40, 40, 48))
    d = ImageDraw.Draw(out)
    y = 0
    for (name, a, b), hgt in zip(rows, heights):
        d.text((4, y + 4), name, fill=(255, 255, 255))
        for col, ims in ((100, a), (100 + 8 * cell + 20, b)):
            for k, im in enumerate(ims):
                out.paste(on_black(im), (col + k * cell, y + 7))
        y += hgt + 14
    out.save(path)


def write_credits():
    names = sorted(RECIPES)
    with open(os.path.join(SPRITES, "CREDITS.md"), "w") as f:
        f.write("# Sprite sources\n\n")
        f.write("Drawn by tools/sprite_art.py, replacing stock Half-Life sprites of the same name, size\n"
                "and frame count. Sprites not listed here are Wizard Wars' own.\n\n")
        for n in names:
            f.write("- `%s.spr`\n" % n)


def main(argv):
    if argv[1:2] == ["--sheet"]:
        sheet(argv[2], argv[3:] or sorted(RECIPES))
        return 0
    names = argv[1:] or sorted(RECIPES)
    for name in names:
        if name not in RECIPES:
            print("no recipe for %s" % name)
            return 2
    for name in names:
        _, out = draw(name)
        out.save(os.path.join(SPRITES, name + ".spr"))
        print("drew sprites/%s.spr" % name)
    write_credits()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
