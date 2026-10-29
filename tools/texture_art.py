#!/usr/bin/env python3
"""Make replacement textures for tools/wad_textures.py from CC0 materials and code.

Each recipe writes textures/<name>.png, a replacement for that texture in ww_base.wad. Photo materials come from ambientCG
(CC0, cached under build/cc0/); everything else is drawn here. textures/CREDITS.md is
rewritten to say where every PNG came from. Needs Pillow and network access on first run.

  texture_art.py [NAME ...]    run the named recipes (all of them when none are given)

GoldSrc textures carry their own shading -- the engine has no normal maps -- so a photo
material is baked: its colour times its ambient occlusion times a fixed light off its normal
map. The result is then pulled toward the original's colour statistics so a map keeps its
palette and its lighting balance.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from texture_kit import *  # noqa: E402,F401,F403
from texture_kit import credits  # noqa: E402
from PIL import Image, ImageChops, ImageDraw, ImageFilter  # noqa: E402
import math  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART = os.path.join(ROOT, "textures")


# --- recipes ------------------------------------------------------------------

def _ladder():
    ref = original("{ladder1")
    credit("{ladder1", "ambientCG Planks037A (CC0), drawn ladder")
    img = ladder(ref.size, "Planks037A")
    rgb = match(img.convert("RGB"), ref, 0.6)
    rgb.putalpha(img.getchannel("A"))
    return rgb


def _xbrace():
    credit("c2a4x_c2", "ambientCG MetalPlates013 (CC0), drawn brace")
    return xbrace(original("c2a4x_c2"), "MetalPlates013", (52, 78, 140))


def _rope():
    credit("rope", "ambientCG Rope001 (CC0) fibre, drawn strands")
    return rope(original("rope"), "Rope001")


RECIPES = {
    # ww_ravine
    "out_rk3": lambda: photo("out_rk3", "Rock051", zoom=3),
    "tnnl_rck1": lambda: photo("tnnl_rck1", "Rock062", zoom=2),
    "c1a3floor02": lambda: blocks("c1a3floor02", "Concrete031", 2, 2),
    "c1a3wall05": lambda: blocks("c1a3wall05", "Concrete033", 2, 4, bond=0.5, mortar=0.05),
    "babtech_dr4c": lambda: photo("babtech_dr4c", "Concrete033"),
    "generic015u": lambda: photo("generic015u", "DiamondPlate009", spread=1.0, box=(0, 0, 256, 256)),
    "trrm_wood2": lambda: photo("trrm_wood2", "Planks037A", box=(0, 0, 1024, 228)),
    "rope": _rope,
    "{ladder1": _ladder,
    "c2a4x_c2": _xbrace,
    "crete4_blue": lambda: blocks("crete4_blue", "Concrete031", 2, 2, seed=2),
    "crete4_red": lambda: blocks("crete4_red", "Concrete031", 2, 2, seed=2),
    "!waterblue": lambda: water("!waterblue", 7),
    "scrollwater1": lambda: water("scrollwater1", 11),
    "+0~light3a": lambda: lamp_recipe("+0~light3a", (235, 232, 220), True, "square"),
    "+a~light3a": lambda: lamp_recipe("+a~light3a", (235, 232, 220), False, "square"),
    "+0~light5a": lambda: lamp_recipe("+0~light5a", (70, 200, 235), True, "square"),
    "+a~light5a": lambda: lamp_recipe("+a~light5a", (70, 200, 235), False, "square"),
    "+0~light6a": lambda: lamp_recipe("+0~light6a", (230, 70, 70), True, "square"),
    "+a~light6a": lambda: lamp_recipe("+a~light6a", (230, 70, 70), False, "square"),
    "~light5a": lambda: lamp_recipe("~light5a", (90, 130, 255), True, "tubes"),
    "~light5e": lambda: lamp_recipe("~light5e", (255, 70, 80), True, "tubes"),
    "+0~fifts_lght06": lambda: lamp_recipe("+0~fifts_lght06", (225, 235, 240), True, "panel"),
    "+a~fifts_lght06": lambda: lamp_recipe("+a~fifts_lght06", (225, 235, 240), False, "panel"),
}



_sets = {}


def member(name, build):
    """One texture of a set built together (random tiles, animation frames)."""
    key = build.__name__ if hasattr(build, "__name__") else id(build)
    if key not in _sets:
        _sets[key] = build()
    return _sets[key][name]


def rand_set(stem, n, asset, **kw):
    names = ["-%d%s" % (i, stem) for i in range(n)]

    def build():
        return photo_set(names, asset, **kw)
    build.__name__ = "rand_" + stem
    return {nm: (lambda nm=nm: member(nm, build)) for nm in names}


def block_set(stem, n, asset, cols, rows, **kw):
    names = ["-%d%s" % (i, stem) for i in range(n)]

    def build():
        base = blocks(names[0], asset, cols, rows, **kw)
        mask = feather(base.size, min(base.size) // 5)
        out = {names[0]: base}
        for i, nm in enumerate(names[1:], 2):
            out[nm] = Image.composite(blocks(names[0], asset, cols, rows, **dict(kw, seed=i)), base, mask)
            credit(nm, credits[names[0]] + ", random-tile set")
        return out
    build.__name__ = "blocks_" + stem
    return {nm: (lambda nm=nm: member(nm, build)) for nm in names}


def banded(name, asset, bands, spread=0.8, base=None, fit=(0, 1), **kw):
    """A wall with horizontal bands: (top, bottom, what) in fractions of the height, where
    what is an asset name, an (r, g, b) paint stripe, or "trim" for a bevelled ledge."""
    ref, (W, H) = sized(name)
    part = ref.crop((0, int(fit[0] * ref.height), ref.width, int(fit[1] * ref.height)))
    img = base.resize((W, H)) if base is not None else material(asset, (W, H), part, spread, **kw)
    h = Image.new("L", (W, H), 128)
    for t, b, what in bands:
        box = (0, int(t * H), W, int(b * H))
        region = ref.crop((0, int(t * ref.height), ref.width, max(int(t * ref.height) + 1, int(b * ref.height))))
        if what == "trim":
            ImageDraw.Draw(h).rectangle([0, box[1], W, box[3]], fill=200)
            img.paste(material("Metal024", (W, box[3] - box[1]), region, 0.6), box[:2])
        elif isinstance(what, tuple):
            stripe = ImageChops.multiply(img.crop(box).point(lambda v: min(255, v + 90)), Image.new("RGB", (W, box[3] - box[1]), what))
            img.paste(stripe, box[:2])
        else:
            img.paste(material(what, (W, box[3] - box[1]), region, spread), box[:2])
            ImageDraw.Draw(h).line([(0, box[1]), (W, box[1])], fill=60, width=S)
    credit(name, (credits[name] if base is not None else "ambientCG %s (CC0)" % asset) + ", drawn bands")
    return emboss(img, h, 1.4, S * 0.5)


def ladder_recipe(name, asset):
    ref = original(name)
    credit(name, "ambientCG %s (CC0), drawn ladder" % asset)
    img = ladder(ref.size, asset)
    rgb = match(img.convert("RGB"), ref, 0.6)
    rgb.putalpha(img.getchannel("A"))
    return rgb


def frames(stems, make):
    """Animation frames named by `stems`; make(name, index) draws one."""
    return {n: (lambda n=n, i=i: make(n, i)) for i, n in enumerate(stems)}


def church_window(name):
    img = blocks(name, "Bricks108A", 4, 4, bond=0.5, mortar=0.025)
    W, H = img.size
    d = ImageDraw.Draw(img)
    cx, cy, r = W / 2, H / 2, H * 0.36
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(90, 70, 40))
    d.ellipse([cx - r * 0.86, cy - r * 0.86, cx + r * 0.86, cy + r * 0.86], fill=(60, 30, 80))
    for k in range(12):
        a = k * math.tau / 12
        d.line([(cx, cy), (cx + math.cos(a) * r * 0.86, cy + math.sin(a) * r * 0.86)], fill=(140, 110, 60), width=max(1, int(r * 0.06)))
        d.ellipse([cx + math.cos(a) * r * 0.55 - r * 0.12, cy + math.sin(a) * r * 0.55 - r * 0.12,
                   cx + math.cos(a) * r * 0.55 + r * 0.12, cy + math.sin(a) * r * 0.55 + r * 0.12], fill=(150, 60, 120))
    d.ellipse([cx - r * 0.2, cy - r * 0.2, cx + r * 0.2, cy + r * 0.2], fill=(190, 150, 70))
    credit(name, credits[name] + ", drawn rose window")
    return img


def brick_window(name):
    img = blocks(name, "Bricks066", 8, 16, bond=0.5, mortar=0.015)
    W, H = img.size
    box = [W * 0.39, H * 0.39, W * 0.61, H * 0.61]
    win = window(name, "Wood049", 3, 3, glass=(50, 45, 40), frame=0.12)
    img.paste(win.resize((int(box[2] - box[0]), int(box[3] - box[1]))), (int(box[0]), int(box[1])))
    credit(name, "ambientCG Bricks066 + Wood049 (CC0), drawn bricks and window")
    return img


def ornament(name):
    ref, (W, H) = sized(name)
    cols = palette_of(ref, 4)
    img = Image.new("RGB", (W, H), cols[0])
    d = ImageDraw.Draw(img)
    n = 4
    c = W / n
    for gx in range(n):
        for gy in range(n):
            x, y = gx * c + c / 2, gy * c + c / 2
            d.ellipse([x - c * 0.38, y - c * 0.38, x + c * 0.38, y + c * 0.38], outline=cols[1], width=int(c * 0.08))
            d.polygon([(x, y - c * 0.2), (x + c * 0.2, y), (x, y + c * 0.2), (x - c * 0.2, y)], fill=cols[2])
            d.rectangle([gx * c, gy * c, gx * c + c * 0.08, gy * c + c * 0.08], fill=cols[3])
    credit(name, "drawn tiles")
    return emboss(img, img.convert("L"), 0.8, 1)


def drawer(name):
    ref, (W, H) = sized(name)
    img = material("Metal024", (W, H), ref, 0.6)
    h = Image.new("L", (W, H), 160)
    ImageDraw.Draw(h).rectangle([W * 0.06, H * 0.12, W * 0.94, H * 0.88], fill=110)
    img = emboss(img, h, 1.6, S * 0.4)
    ImageDraw.Draw(img).rounded_rectangle([W * 0.35, H * 0.4, W * 0.65, H * 0.6], radius=int(H * 0.08), fill=(200, 200, 205))
    credit(name, "ambientCG Metal024 (CC0), drawn drawer")
    return img


def hatch(name):
    ref, (W, H) = sized(name)
    img = material("Metal041C", (W, H), ref, 0.7)
    h = Image.new("L", (W, H), 120)
    d = ImageDraw.Draw(h)
    d.ellipse([W * 0.06, H * 0.06, W * 0.94, H * 0.94], fill=180)
    d.ellipse([W * 0.14, H * 0.14, W * 0.86, H * 0.86], fill=110)
    d.rectangle([W * 0.46, H * 0.2, W * 0.54, H * 0.75], fill=200)
    img = emboss(img, h, 1.7, S * 0.5)
    rivet(img, W / 2, H * 0.2, W * 0.06)
    credit(name, "ambientCG Metal041C (CC0), drawn hatch")
    return img


def speakers(name):
    ref, (W, H) = sized(name)
    img = material("Metal024", (W, H), ref, 0.6)
    d = ImageDraw.Draw(img)
    for i in range(3):
        cy = H * (i + 0.5) / 3
        r = W * 0.32
        d.ellipse([W / 2 - r, cy - r, W / 2 + r, cy + r], fill=(30, 32, 36))
        d.ellipse([W / 2 - r * 0.6, cy - r * 0.6, W / 2 + r * 0.6, cy + r * 0.6], fill=(60, 64, 70))
        d.ellipse([W / 2 - r * 0.2, cy - r * 0.2, W / 2 + r * 0.2, cy + r * 0.2], fill=(20, 20, 22))
    credit(name, "drawn speakers")
    return img


def plaid(name):
    ref, (W, H) = sized(name)
    cols = palette_of(ref, 4)
    img = Image.new("RGB", (W, H), cols[0])
    over = Image.new("RGB", (W, H), cols[1])
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    for k in range(4):
        x = (k + 0.5) * W / 4
        d.rectangle([x - W * 0.06, 0, x + W * 0.06, H], fill=120)
        d.rectangle([0, x - H * 0.06, W, x + H * 0.06], fill=120)
    img = Image.composite(over, img, m)
    d2 = ImageDraw.Draw(img)
    for k in range(5):
        x = k * W / 4
        d2.line([(x, 0), (x, H)], fill=cols[2], width=S)
        d2.line([(0, x), (W, x)], fill=cols[2], width=S)
    weave = baked("Fabric061", (W, H)).convert("L").point(lambda v: 160 + v // 3)
    credit(name, "drawn plaid, ambientCG Fabric061 (CC0) weave")
    return ImageChops.multiply(img, Image.merge("RGB", [weave] * 3)).point(lambda v: min(255, int(v * 1.2)))


def pipes(name, asset, n):
    """Horizontal round ducts stacked down the texture."""
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, 0.8)
    shade = Image.new("L", (W, H))
    shade.putdata([int(255 * (0.3 + 0.7 * math.sin(math.pi * ((y * n / H) % 1)) ** 0.6)) for y in range(H) for x in range(W)])
    credit(name, "ambientCG %s (CC0), drawn ducts" % asset)
    return ImageChops.multiply(img, Image.merge("RGB", [shade] * 3)).point(lambda v: min(255, int(v * 1.35)))


def framed(name, asset, frame_asset, border=0.08, spread=0.8):
    """A panel of one material in a bevelled frame of another."""
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, spread)
    b = int(min(W, H) * border)
    fr = material(frame_asset, (W, H), ref, spread)
    m = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m).rectangle([0, 0, W - 1, H - 1], outline=255, width=b)
    img = Image.composite(fr, img, m)
    img = emboss(img, m, 1.6, S * 0.4)
    credit(name, "ambientCG %s + %s (CC0), drawn frame" % (asset, frame_asset))
    return img


def post(name, asset):
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, 0.8, rotate=90)
    shade = Image.new("L", (W, H))
    shade.putdata([int(255 * (0.35 + 0.65 * math.sin(math.pi * x / (W - 1)) ** 0.5)) for y in range(H) for x in range(W)])
    credit(name, "ambientCG %s (CC0), drawn post" % asset)
    return ImageChops.multiply(img, Image.merge("RGB", [shade] * 3)).point(lambda v: min(255, int(v * 1.3)))


def lab_door(name):
    ref, (W, H) = sized(name)
    img = corrugated(name, "Metal024", 14, vertical=False)
    band = Image.new("RGB", (W, int(H * 0.08)), (220, 180, 30))
    d = ImageDraw.Draw(band)
    for i in range(-band.height, W, band.height * 2):
        d.polygon([(i, band.height), (i + band.height, 0), (i + band.height * 2, 0), (i + band.height, band.height)], fill=(25, 25, 25))
    img.paste(band, (0, int(H * 0.88)))
    credit(name, "ambientCG Metal024 (CC0), drawn shutter door")
    return img


def hazard_floor(name):
    ref, (W, H) = sized(name)
    img = material("DiamondPlate009", (W, H), ref, 0.6)
    band = [0, H * 0.36, W, H * 0.64]
    m = rect_mask((W, H), [band])
    st = Image.new("RGB", (W, H), (30, 30, 32))
    d = ImageDraw.Draw(st)
    for i in range(-H, W + H, int(W / 5)):
        d.line([(i, band[3]), (i + (band[3] - band[1]), band[1])], fill=(110, 110, 115), width=int(W * 0.05))
    img = Image.composite(st, img, m)
    credit(name, "ambientCG DiamondPlate009 (CC0), drawn grille")
    return emboss(img, ImageChops.invert(m), 1.5, S * 0.4)


def tube_panel(name, color, on):
    credit(name, "drawn: light fitting")
    ref = original(name)
    img = lamp(ref.size, color, on, "tubes")
    return img


def tall_panel(name):
    ref, (W, H) = sized(name)
    img = material("Metal027", (W, H), ref, 0.8)
    h = Image.new("L", (W, H), 140)
    d = ImageDraw.Draw(h)
    for i in range(6):
        y = H * (0.86 + i * 0.022)
        d.line([(W * 0.1, y), (W * 0.9, y)], fill=60, width=S)
    d.rectangle([W * 0.08, H * 0.05, W * 0.92, H * 0.8], fill=110)
    credit(name, "ambientCG Metal027 (CC0), drawn panel")
    return emboss(img, h, 1.6, S * 0.4)


def stone_x(name, asset):
    """A stone panel with a raised X brace inside a raised frame."""
    ref, (W, H) = sized(name)
    img = material(asset, (W, H), ref, 0.5)
    h = Image.new("L", (W, H), 80)
    d = ImageDraw.Draw(h)
    b = W * 0.1
    d.rectangle([0, 0, W - 1, H - 1], outline=200, width=int(b))
    d.line([(b, b), (W - b, H - b)], fill=200, width=int(b * 1.3))
    d.line([(W - b, b), (b, H - b)], fill=200, width=int(b * 1.3))
    img = darken(img, h.point(lambda v: 255 if v < 100 else 0).filter(ImageFilter.GaussianBlur(S)), 0.55)
    credit(name, "ambientCG %s (CC0), drawn brace" % asset)
    return emboss(img, h, 2.6, S * 0.6, S // 2)


RECIPES.update({
    # liquids
    "!c2a5": lambda: water("!c2a5", 21),
    "!c2a54": lambda: water("!c2a54", 22),
    "!water2b": lambda: water("!water2b", 23),
    "!watergreen": lambda: water("!watergreen", 24),
    "water4b": lambda: water("water4b", 25),
    "scrollxen3": lambda: cells("scrollxen3", 30, 26, 0.2),

    # switch panels, +0 lit and +a dark
    "+0c1a4_swtch2": lambda: switch_panel("+0c1a4_swtch2", "OXY", (70, 120, 255), True),
    "+ac1a4_swtch2": lambda: switch_panel("+ac1a4_swtch2", "OXY", (70, 120, 255), False),
    "+0c1a4_swtch3": lambda: switch_panel("+0c1a4_swtch3", "FUEL", (235, 50, 40), True),
    "+ac1a4_swtch3": lambda: switch_panel("+ac1a4_swtch3", "FUEL", (235, 50, 40), False),
    "+0c1a4_swtch5": lambda: switch_panel("+0c1a4_swtch5", "POWER", (240, 210, 30), True),
    "+ac1a4_swtch5": lambda: switch_panel("+ac1a4_swtch5", "POWER", (240, 210, 30), False),

    # flat and noisy colours, including animated ones
    "+0generic_109": lambda: photo("+0generic_109", "Plaster002", spread=1.0),
    "+1generic_109": lambda: photo("+1generic_109", "Plaster003", spread=1.0),
    "+0~generic78b": lambda: photo("+0~generic78b", "Plaster002", spread=1.0),
    "+1~generic78b": lambda: photo("+1~generic78b", "Plaster003", spread=1.0),
    "+a~generic78b": lambda: photo("+a~generic78b", "Plaster004", spread=1.0),
    "+0~generic78c": lambda: photo("+0~generic78c", "Plaster002", spread=1.0),
    "+1~generic78c": lambda: photo("+1~generic78c", "Plaster003", spread=1.0),
    "+a~generic78c": lambda: photo("+a~generic78c", "Plaster004", spread=1.0),
    "c3a2a_telred1d": lambda: photo("c3a2a_telred1d", "Plaster001", spread=1.0),
    "ca1x_con1b": lambda: photo("ca1x_con1b", "Plaster001", spread=1.0),
    "gen_vend1b": lambda: photo("gen_vend1b", "Plaster007", spread=1.0),
    "drkmtlt_ceil01b": lambda: photo("drkmtlt_ceil01b", "Plaster003", spread=1.0),
    "+0~white": lambda: flat("+0~white"),
    "white": lambda: flat("white"),
    "black": lambda: flat("black"),
    "red": lambda: flat("red"),
    "yellow": lambda: flat("yellow"),
    "fade": lambda: gradient("fade"),
    "fade2": lambda: gradient("fade2"),

    # tool textures and holes
    "aaatrigger": lambda: tool("aaatrigger", (230, 120, 30), (40, 30, 20)),
    "clip": lambda: tool("clip", (160, 60, 200), (60, 20, 80)),
    "origin": lambda: tool("origin", (60, 200, 80), (20, 70, 30)),
    "sky": lambda: tool("sky", (180, 215, 245)),
    "{invisible": lambda: empty("{invisible"),
    "{blue": lambda: empty("{blue"),

    # lights
    "+0~drkmtls2c": lambda: lights("+0~drkmtls2c", "glow", (240, 190, 60), True),
    "+0~gymlight": lambda: lights("+0~gymlight", "rings", (235, 220, 150), True),
    "+a~gymlight": lambda: lights("+a~gymlight", "rings", (235, 220, 150), False),
    "+agymlight": lambda: lights("+agymlight", "rings", (120, 170, 200), False),
    "+0~tnnl_lgt3": lambda: tube_panel("+0~tnnl_lgt3", (235, 235, 210), True),
    "+a~tnnl_lgt3": lambda: tube_panel("+a~tnnl_lgt3", (235, 235, 210), False),
    "~light3b": lambda: tube_panel("~light3b", (120, 150, 255), True),
    "testlight1": lambda: lights("testlight1", "grid", (220, 225, 235), True),
    "sunbeam": lambda: streaks("sunbeam", 4),
    "glass_bright": lambda: streaks("glass_bright", 5),
    "glass_med": lambda: streaks("glass_med", 6),
    "glassblue2": lambda: streaks("glassblue2", 7),
    "~lab1_comp3b": lambda: computer("~lab1_comp3b"),
    "~lab1_comp7b": lambda: tall_panel("~lab1_comp7b"),
    "lab1_comp8b": lambda: tall_panel("lab1_comp8b"),

    # rock, ground, sand
    "canyonscliff": lambda: photo("canyonscliff", "Rock061"),
    "canyonsmud1": lambda: photo("canyonsmud1", "Ground054"),
    "canyonssand1": lambda: photo("canyonssand1", "Ground080"),
    "canyonssand4": lambda: photo("canyonssand4", "Ground079S", zoom=4),
    "cretecrumble": lambda: photo("cretecrumble", "Rocks006", zoom=4),
    "crossover03": lambda: photo("crossover03", "Rock064"),
    "generic93": lambda: photo("generic93", "Ground110"),
    "out_dirt2": lambda: photo("out_dirt2", "Ground106"),
    "out_gravel": lambda: photo("out_gravel", "Gravel040"),
    "out_grnd1": lambda: photo("out_grnd1", "Ground107"),
    "out_ground4": lambda: photo("out_ground4", "Grass001", spread=1.0, zoom=4),
    "out_ground9": lambda: photo("out_ground9", "Ground037"),
    "out_grvl2b": lambda: photo("out_grvl2b", "Gravel041", zoom=4),
    "out_hay1": lambda: photo("out_hay1", "ThatchedRoof001A"),
    "out_mud1": lambda: photo("out_mud1", "Ground054"),
    "out_rock5": lambda: photo("out_rock5", "Rock059"),
    "out_snd1": lambda: photo("out_snd1", "Ground080"),
    "out_snd2b": lambda: photo("out_snd2b", "Ground097", zoom=2),
    "rock_grey": lambda: photo("rock_grey", "Rock022"),
    "rubble1": lambda: photo("rubble1", "Rocks025"),
    "underwaterrock": lambda: photo("underwaterrock", "Rock064"),
    "xeno_16b": lambda: photo("xeno_16b", "Ground111"),
    "tnnl_w4a": lambda: photo("tnnl_w4a", "Rock030"),

    # concrete, plaster, marble, asphalt
    "babtech6": lambda: photo("babtech6", "Concrete044D"),
    "babtech_dr1c": lambda: photo("babtech_dr1c", "Concrete047A"),
    "c1a1c_w2": lambda: photo("c1a1c_w2", "Concrete030"),
    "c1a1c_w2b": lambda: photo("c1a1c_w2b", "Concrete030"),
    "c1a1w1d": lambda: photo("c1a1w1d", "Plaster001"),
    "crete1_wall01": lambda: photo("crete1_wall01", "Concrete036"),
    "crete2_flr01": lambda: photo("crete2_flr01", "Concrete036"),
    "crete3_wall01": lambda: photo("crete3_wall01", "Concrete036"),
    "crete3_wall01b": lambda: photo("crete3_wall01b", "Concrete034"),
    "crete3_wall02": lambda: photo("crete3_wall02", "Concrete032"),
    "fifties_dsk5b": lambda: photo("fifties_dsk5b", "Concrete034"),
    "fifties_tbl1": lambda: photo("fifties_tbl1", "Marble012"),
    "fifties_wall03": lambda: photo("fifties_wall03", "Plaster003"),
    "fifties_wall08": lambda: photo("fifties_wall08", "Plaster004"),
    "fifties_wall14a": lambda: photo("fifties_wall14a", "Plaster002"),
    "fifties_wall14v": lambda: photo("fifties_wall14v", "Plaster007"),
    "fiftsfile2": lambda: photo("fiftsfile2", "Concrete034"),
    "i_church2a": lambda: photo("i_church2a", "Marble014"),
    "keep05": lambda: photo("keep05", "Plaster004"),
    "keep09a": lambda: photo("keep09a", "Plaster003"),
    "out_pav3": lambda: photo("out_pav3", "Asphalt025C"),
    "out_pave1": lambda: photo("out_pave1", "Asphalt025C"),
    "road_1": lambda: photo("road_1", "Road012A"),
    "silo2_wet6": lambda: photo("silo2_wet6", "Concrete034"),
    "stain_wall06": lambda: photo("stain_wall06", "Metal041C"),
    "tnnl_flr4": lambda: photo("tnnl_flr4", "Concrete032"),
    "tnnl_flr4c": lambda: photo("tnnl_flr4c", "Concrete036"),
    "xcrate2c": lambda: photo("xcrate2c", "Concrete048"),
    "double_trim1": lambda: photo("double_trim1", "Rocks025"),
    "ital_wall5": lambda: photo("ital_wall5", "Bricks106A"),

    # metal
    "babtech_ceil01": lambda: photo("babtech_ceil01", "Metal024"),
    "c2a3turbine2": lambda: photo("c2a3turbine2", "Metal041C"),
    "crete_bord04": lambda: photo("crete_bord04", "MetalWalkway014", spread=1.0),
    "drkmtlt_bord11": lambda: photo("drkmtlt_bord11", "Metal027"),
    "drkmtlt_bord12": lambda: photo("drkmtlt_bord12", "Metal028"),
    "generic012": lambda: photo("generic012", "Metal021"),
    "generic039": lambda: photo("generic039", "Metal041C"),
    "generic105b": lambda: photo("generic105b", "Metal041B"),
    "generic77": lambda: photo("generic77", "CorrugatedSteel009", zoom=2),
    "metal_bord01": lambda: photo("metal_bord01", "Metal024"),
    "steel": lambda: photo("steel", "Metal021"),
    "out_roof1": lambda: corrugated("out_roof1", "CorrugatedSteel007A", 5, frame=0.06),
    "out_roof1a": lambda: corrugated("out_roof1a", "CorrugatedSteel007A", 5, frame=0.06),
    "out_roof2c": lambda: corrugated("out_roof2c", "CorrugatedSteel007C", 5, frame=0.06),
    "out_wall2a": lambda: corrugated("out_wall2a", "CorrugatedSteel007A", 5),
    "fifties_ceil02": lambda: pipes("fifties_ceil02", "Metal041B", 4),
    "lab1_door01": lambda: lab_door("lab1_door01"),
    "babtech_flr02": lambda: hazard_floor("babtech_flr02"),
    "frostgrate": lambda: slots("frostgrate", "Metal024", 5),
    "grate_rust": lambda: slots("grate_rust", "Metal041C", 5),
    "fifties_dsk5dx": lambda: drawer("fifties_dsk5dx"),
    "generic034a": lambda: hatch("generic034a"),
    "lab1_brd1": lambda: speakers("lab1_brd1"),
    "fifties_cmp2c": lambda: framed("fifties_cmp2c", "Plaster007", "Metal024"),
    "c2a3rustdoor1": lambda: door("c2a3rustdoor1", "Metal041C", (1, 3), rotate=0),
    "babtech_dr4": lambda: door("babtech_dr4", "Metal024", (1, 1), rotate=0),
    "fifties_door01": lambda: door("fifties_door01", "Metal041B", (1, 3), rotate=0),
    "i_door_blue1": lambda: door("i_door_blue1", "PaintedMetal004", (1, 3), rotate=0),
    "i_door_wood1": lambda: door("i_door_wood1", "Metal024", (1, 3), rotate=0),
    "tnnl_swrc1": lambda: stone_x("tnnl_swrc1", "Concrete032"),

    # trims and strips
    "babtech_bordl8": lambda: trim("babtech_bordl8", "Metal021", rivets=5, grooves=0),
    "babtech_bordl9": lambda: trim("babtech_bordl9", "Metal021", rivets=5, grooves=0),
    "con1_bord02": lambda: blocks("con1_bord02", "Concrete032", 6, 12, mortar=0.02),
    "con1_bord04": lambda: blocks("con1_bord04", "Concrete036", 6, 12, mortar=0.02),
    "crete2_flr03c": lambda: trim("crete2_flr03c", "Metal027", rivets=3, grooves=0),
    "drkmtlt_bord08": lambda: vbars("drkmtlt_bord08", "Metal021", 4),
    "drkmtlt_bord15": lambda: banded("drkmtlt_bord15", "Metal027", [(0.35, 0.65, "trim")]),
    "elev1_trim": lambda: trim("elev1_trim", "Metal021", grooves=1),
    "in_metal_rail2": lambda: trim("in_metal_rail2", "Metal027", round_=True, grooves=0),
    "lab10_tnk2b": lambda: trim("lab10_tnk2b", "Metal024", round_=True, grooves=0),
    "lab1_brd3b": lambda: trim("lab1_brd3b", "Metal024", round_=True, grooves=0),
    "metal_bord08": lambda: trim("metal_bord08", "Metal021", rivets=8, grooves=0),
    "silo2_brd1b": lambda: trim("silo2_brd1b", "Metal041C", rivets=8, grooves=0),
    "i_grate1": lambda: vbars("i_grate1", "Metal021", 10),
    "generic89b": lambda: post("generic89b", "Wood051"),

    # wood
    "eastwood01": lambda: photo("eastwood01", "Planks037A", rotate=90, zoom=3),
    "eastwood03": lambda: photo("eastwood03", "Planks037A", rotate=90, zoom=3),
    "eastwood04": lambda: photo("eastwood04", "Planks037A", rotate=90, zoom=3),
    "fift_drtemp": lambda: photo("fift_drtemp", "Wood051", rotate=90),
    "fifties_dr6a": lambda: photo("fifties_dr6a", "Wood066", rotate=90),
    "in_floor2": lambda: photo("in_floor2", "WoodFloor051"),
    "m_floor7": lambda: photo("m_floor7", "WoodFloor064"),
    "m_wood1": lambda: photo("m_wood1", "Wood049"),
    "out_fence1": lambda: photo("out_fence1", "WoodSiding008", rotate=90, zoom=3),
    "trrm_wood": lambda: photo("trrm_wood", "Planks037A", box=(0, 0, 1024, 256)),
    "tnnl_w6": lambda: blocks("tnnl_w6", "Planks037A", 1, 4, mortar=0.03),
    "tnnl_w6_2": lambda: blocks("tnnl_w6_2", "Planks037A", 1, 4, mortar=0.03, seed=2),
    "m_ceiling4": lambda: blocks("m_ceiling4", "Wood066", 2, 5, mortar=0.06),
    "fifties_dr1": lambda: photo("fifties_dr1", "Wood066", rotate=90),
    "fifties_dr2": lambda: door("fifties_dr2", "Wood051", (2, 3), knob="right"),
    "fifties_dr6": lambda: door("fifties_dr6", "Wood049", (1, 2)),
    "fifties_dr6a2": lambda: door("fifties_dr6a2", "Wood049", (1, 2), knob="right"),
    "eastdoor1": lambda: door("eastdoor1", "Planks037A", (2, 1), frame=0.06),
    "eastdoor2": lambda: door("eastdoor2", "Planks037A", (1, 1), frame=0.08),
    "eastwndwb0": lambda: louvers("eastwndwb0", "Wood049"),
    "eastwndwbtall": lambda: louvers("eastwndwbtall", "Wood049"),
    "in_window4": lambda: window("in_window4", "Wood051", 3, 3),
    "{woodrail": lambda: lattice("{woodrail", "Wood049", 5, 2),

    # crates
    "bcrate09a": lambda: crate("bcrate09a", hazard=True, sign=True),
    "bcrate09b": lambda: crate("bcrate09b", hazard=True),
    "bcrate18": lambda: crate("bcrate18"),
    "bcrate25": lambda: crate("bcrate25"),
    "bcrate26": lambda: crate("bcrate26"),
    "crate1": lambda: crate("crate1", brace="diag", asset="Wood049"),
    "crate1a": lambda: crate("crate1a", asset="Wood094", metal="Metal024"),
    "crate10": lambda: crate("crate10", brace="h"),
    "crate12": lambda: crate("crate12", brace="h"),
    "crate24": lambda: crate("crate24", brace="h", asset="Wood051"),
    "crate27": lambda: crate("crate27", brace="h", asset="Wood051"),

    # bricks, tiles, panels
    "c1a3wall08": lambda: blocks("c1a3wall08", "Metal024", 4, 1, mortar=0.02),
    "crete3_ceil01": lambda: coffers("crete3_ceil01", "Concrete032", 3, 3),
    "crete4_flr03": lambda: blocks("crete4_flr03", "Concrete031", 2, 2),
    "crete4_redb": lambda: blocks("crete4_redb", "Concrete031", 2, 2, seed=3),
    "crete4_wall01": lambda: blocks("crete4_wall01", "Concrete031", 2, 1, mortar=0.04),
    "eastfloor5": lambda: banded("eastfloor5", "Concrete044D", [(0, 0.12, "trim"), (0.88, 1, "trim")]),
    "fifties_wall13d": lambda: blocks("fifties_wall13d", "Concrete034", 2, 4, bond=0.5, mortar=0.05),
    "fifties_wall14u": lambda: banded("fifties_wall14u", "Plaster002", [(0.68, 1.0, "Wood066")], fit=(0, 0.65)),
    "i_church1": lambda: blocks("i_church1", "Bricks108A", 4, 4, bond=0.5, mortar=0.025),
    "i_church1a": lambda: blocks("i_church1a", "Bricks108A", 4, 4, bond=0.5, mortar=0.025, seed=2),
    "i_church4": lambda: church_window("i_church4"),
    "double_blue2": lambda: brick_window("double_blue2"),
    "i_trim1": lambda: columns("i_trim1", "Marble014", 3),
    "i_trim3": lambda: ornament("i_trim3"),
    "lab1_bluxflr1": lambda: blocks("lab1_bluxflr1", "Concrete034", 8, 8, mortar=0.02),
    "out_w5": lambda: blocks("out_w5", "Concrete030", 4, 5, bond=0.5, mortar=0.03),
    "slate_roof_1": lambda: photo("slate_roof_1", "RoofingTiles013A"),
    "eastrooftop": lambda: roof_tiles("eastrooftop", "Concrete047A", 4, 3),
    "wet_wall05": lambda: blocks("wet_wall05", "Bricks094", 2, 4, bond=0.5, mortar=0.05),
    "rock1a": lambda: banded("rock1a", None, [(0, 0.06, "trim"), (0.7, 0.78, (60, 90, 200))],
                             base=blocks("rock1a", "Concrete036", 3, 7, bond=0.5, mortar=0.03)),
    "rock1b": lambda: banded("rock1b", None, [(0, 0.06, "trim"), (0.7, 0.78, (200, 50, 50))],
                             base=blocks("rock1b", "Concrete036", 3, 7, bond=0.5, mortar=0.03)),
    "c3a1_w5b": lambda: banded("c3a1_w5b", "Concrete030", [(0, 0.08, "trim")]),
    "c3a1_w5blu": lambda: banded("c3a1_w5blu", "Concrete030", [(0, 0.08, "trim"), (0.78, 0.86, (60, 90, 200))]),
    "c3a1_w5red": lambda: banded("c3a1_w5red", "Concrete030", [(0, 0.08, "trim"), (0.78, 0.86, (170, 70, 40))]),

    # fabric, rugs, sandbags
    "eastcarpet3b": lambda: carpet("eastcarpet3b", seed=1),
    "eastcarpet3c": lambda: carpet("eastcarpet3c", seed=2),
    "eastcarpet3d": lambda: carpet("eastcarpet3d", seed=3),
    "fifties_cch4b": lambda: plaid("fifties_cch4b"),
    "out_tnt2": lambda: photo("out_tnt2", "Fabric061"),
    "out_snbag": lambda: sandbags("out_snbag", "Fabric066", 4, 2),
    "out_snbagc": lambda: sandbags("out_snbagc", "Fabric066", 2, 2),

    # props
    "pfab_bks1a": lambda: books("pfab_bks1a", seed=1),
    "pfab_bks1b": lambda: books("pfab_bks1b", seed=2),
    "prefabbook1": lambda: books("prefabbook1", spines=False),
    "prefabbook2": lambda: books("prefabbook2", spines=False),
    "prefabbook3": lambda: books("prefabbook3", spines=False),
    "prefab_pot1": lambda: pot("prefab_pot1"),
    "paper1": lambda: paper("paper1", 1),
    "paper5": lambda: paper("paper5", 2),
    "paper6": lambda: paper("paper6", 3),
    "paper7": lambda: paper("paper7", 4, lines=False),
    "sign_capt": lambda: sign("sign_capt", ["CAPTURE", "POINT"]),
    "sign_resup1": lambda: sign("sign_resup1", ["RESUPPLY"]),
    "out_cac1": lambda: columns("out_cac1", "Grass004", 3),

    # xen, crystals
    "biotech_2": lambda: cells("biotech_2", 12, 31),
    "biotech_2b": lambda: cells("biotech_2b", 12, 32),
    "xeno_8w3a": lambda: cells("xeno_8w3a", 24, 33, 0.25, invert=True),
    "crys_1c": lambda: crystal("crys_1c", 1),
    "crys_1top": lambda: crystal("crys_1top", 2),
    "crys_2a": lambda: crystal("crys_2a", 3),
    "crys_2top": lambda: crystal("crys_2top", 4),
    "crys_3a": lambda: crystal("crys_3a", 5),
    "crys_3b": lambda: crystal("crys_3b", 6),
    "crys_4a": lambda: crystal("crys_4a", 7),

    # alpha-tested
    "{bars": lambda: bars("{bars", "Metal027", 4),
    "{grass1": lambda: foliage("{grass1", "grass", 1, asset="Grass004"),
    "{grass2": lambda: foliage("{grass2", "grass", 2, asset="Grass004"),
    "{shrub1a": lambda: foliage("{shrub1a", "shrub", 3),
    "{shrub1b": lambda: foliage("{shrub1b", "shrub", 4),
    "{vine1": lambda: foliage("{vine1", "vine", 5, asset="Grass004"),
    "{xeno_6": lambda: foliage("{xeno_6", "roots", 6, asset="Bark007"),
    "{grate2": lambda: grid_holes("{grate2", "Metal027", 8, 8, cross=0.04),
    "{grate3a": lambda: grid_holes("{grate3a", "Metal041C", 5, 5, bar=0.35),
    "{grate4a": lambda: grid_holes("{grate4a", "Metal041C", 4, 6, bar=0.3),
    "{gratestep3": lambda: grid_holes("{gratestep3", "Metal027", 6, 6, bar=0.3, frame=0.06),
    "{out_net1b": lambda: net("{out_net1b", "Fabric061", 60, 41),
    "{ladder2": lambda: ladder_recipe("{ladder2", "Metal024"),
    "{ladder3a": lambda: ladder_recipe("{ladder3a", "Planks037A"),
    "{ladder3b": lambda: ladder_recipe("{ladder3b", "Planks037A"),

    # decals (coverage only)
    "{shot1": lambda: decal("{shot1", "shot", 1),
    "{shot2": lambda: decal("{shot2", "shot", 2),
    "{shot3": lambda: decal("{shot3", "shot", 3),
    "{shot4": lambda: decal("{shot4", "shot", 4),
    "{scorch1": lambda: decal("{scorch1", "scorch", 5),
    "{scorch2": lambda: decal("{scorch2", "scorch", 6),
    "{scorch3": lambda: decal("{scorch3", "scorch", 7),
    "{drip4": lambda: decal("{drip4", "drip", 8),
    "{fault04": lambda: decal("{fault04", "crack", 9),
})
RECIPES.update(frames(["+0laser1fall", "+1laser1fall", "+2laser1fall", "+3laser1fall"], laser))
RECIPES.update(rand_set("out_rk3", 5, "Rock051", zoom=3))
RECIPES.update(rand_set("tnnl_rck1", 3, "Rock062", zoom=2))
RECIPES.update(rand_set("out_dirt2", 5, "Ground106", zoom=4))
RECIPES.update(rand_set("out_grnd2b", 3, "Ground107"))
RECIPES.update(rand_set("out_wall8", 3, "Concrete023"))
RECIPES.update(block_set("crete4_wall01", 4, "Concrete031", 4, 1, mortar=0.025))
RECIPES.update(block_set("fifties_w12", 3, "Bricks108A", 2, 4, bond=0.5, mortar=0.05))
RECIPES.update(block_set("fift_wall13", 1, "Concrete047A", 4, 6, bond=0.5, mortar=0.04))


def write_credits():
    path = os.path.join(ART, "CREDITS.md")
    known = {}
    if os.path.exists(path):
        for line in open(path):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if line.startswith("| `") and len(cells) == 2:
                known[cells[0].strip("`")] = cells[1]
    known.update(credits)
    with open(path, "w") as f:
        f.write("# Texture sources\n\nReplacements for ww_base.wad, written by tools/texture_art.py. "
                "ambientCG materials are CC0 (https://ambientcg.com); \"drawn\" textures are "
                "generated by the script.\n\n| texture | source |\n|---|---|\n")
        for name, src in sorted(known.items()):
            f.write("| `%s` | %s |\n" % (name, src))


def main():
    want = {n.lower() for n in sys.argv[1:]}
    os.makedirs(ART, exist_ok=True)
    for name, make in RECIPES.items():
        if want and name.lower() not in want:
            continue
        img = make()
        ref = original(name)
        # Saved at the WAD's own size: build would resample anything larger down to it anyway.
        if img.size != ref.size:
            img = img.resize(ref.size, Image.LANCZOS) if img.mode == "RGBA" else resize_tiled(img, ref.size)
        img.save(os.path.join(ART, name + ".png"))
        print(name)
    write_credits()


if __name__ == "__main__":
    main()
