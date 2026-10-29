#!/usr/bin/env python3
"""Rebuild ww_base.wad, WW's stand-in for the stock Valve WADs, from replacement art.

The maps still name the WADs they were built with (halflife.wad, tfc.wad, ...). Those aren't
shipped: MapConverter loads whichever declared WADs exist and then ww_base.wad, which holds
every texture any map takes from them. The first committed ww_base.wad is those textures
copied verbatim; it is the reference every build starts from, read straight out of git.

New art is textures/<texture name>.png. A texture without a PNG keeps its original bytes, so
the WAD is replaced one texture at a time and `status` says how much is left. Needs Pillow.

  usage   [--map M]               which WAD each map's textures resolve to
  status                          which ww_base textures are still the originals
  extract [--map M] [--out DIR]   dump the original textures as PNGs (reference for new art)
  build                           write ww_base.wad: the originals with every PNG folded in
  sheet   --map M [--out PNG]     original | rebuilt, for every replaced texture on a map

A replacement must keep the original's name and aspect ratio. Its size may be any multiple:
the WAD stores texels at the original size because a face's texinfo maps world units to
texels, so a different size would rescale it on every surface it covers. It is resampled
down here. Hole textures ({) take their holes from the PNG's alpha; decals take coverage
from alpha and keep the original's tint.

Changing the WAD does not invalidate converted maps -- MapConverter keys on CACHE_VERSION and
the extension's pipeline id only. `build` drops the local .scn of every map; a release needs
a CACHE_VERSION bump.
"""

import argparse
import glob
import os
import re
import struct
import subprocess
import sys

from PIL import Image, ImageDraw, ImageStat

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bsp import Bsp, invalidate_cache  # noqa: E402
from wad import Texture, Wad, norm  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART = os.path.join(ROOT, "textures")
BASE = "ww_base.wad"
ORIGINAL_CACHE = os.path.join(ROOT, "build", "ww_base.original.wad")
USERDATA = os.path.expanduser("~/Library/Application Support/Godot/app_userdata/Wizard Wars/resources")
# What decals.wad held. They are coverage ramps, not pictures (see wad.py).
DECALS = {"{shot1", "{shot2", "{shot3", "{shot4", "{scorch1", "{scorch2", "{scorch3",
          "{drip4", "{fault04"}
# WW's own art that happened to live in a stock WAD; it stays as it is.
KEEP = {"team1a", "team2a"}
# Never drawn, or drawn by something other than the texture (sky is the skybox).
SKIP = {"aaatrigger", "clip", "origin", "sky", "null", "hint", "skip", "{invisible"}


def original_wad():
    """ww_base.wad as first committed: the untouched stock textures."""
    rev = subprocess.run(["git", "-C", ROOT, "log", "--diff-filter=A", "--format=%H", "-1", "--", BASE],
                         capture_output=True, text=True).stdout.strip()
    if not rev:
        return Wad(os.path.join(ROOT, BASE))     # not committed yet: it IS the original
    stamp = ORIGINAL_CACHE + ".rev"
    if not (os.path.exists(ORIGINAL_CACHE) and os.path.exists(stamp) and open(stamp).read() == rev):
        os.makedirs(os.path.dirname(ORIGINAL_CACHE), exist_ok=True)
        blob = subprocess.run(["git", "-C", ROOT, "show", "%s:%s" % (rev, BASE)],
                              capture_output=True, check=True).stdout
        with open(ORIGINAL_CACHE, "wb") as f:
            f.write(blob)
        with open(stamp, "w") as f:
            f.write(rev)
    return Wad(ORIGINAL_CACHE)


def declared_wads(b):
    m = re.search(r'"wad"\s+"([^"]*)"', b.entities)
    return [w.replace("\\", "/").split("/")[-1].lower() for w in (m.group(1) if m else "").split(";") if w]


def load_wads():
    return {os.path.basename(p).lower(): Wad(p) for p in glob.glob(os.path.join(ROOT, "*.wad"))}


def resolve(map_name, wads):
    """[(texture name, wad file, None if embedded)] in MapConverter's order: the declared WADs
    that exist, then ww_base.wad."""
    b = Bsp(os.path.join(ROOT, "maps", map_name + ".bsp"))
    d = b.lumps["textures"]
    index = {k: {norm(n) for n in w.names()} for k, w in wads.items()}
    order = [w for w in declared_wads(b) if w in wads] + [BASE]
    out = []
    for o in struct.unpack_from("<%di" % struct.unpack_from("<i", d, 0)[0], d, 4):
        if o < 0:
            continue
        name = bytes(d[o:o + 16]).split(b"\0", 1)[0].decode("latin1")
        if struct.unpack_from("<I", d, o + 24)[0]:
            out.append((name, None))
            continue
        out.append((name, next((w for w in order if norm(name) in index.get(w, ())), "MISSING")))
    return out


def maps():
    return sorted(os.path.basename(p)[:-4] for p in glob.glob(os.path.join(ROOT, "maps", "*.bsp")))


def to_image(tex, level=0):
    return Image.frombytes("RGBA", (tex.width >> level, tex.height >> level),
                           tex.rgba(level, norm(tex.name) in DECALS))


def replacements():
    return {norm(os.path.basename(p)[:-4]): p for p in glob.glob(os.path.join(ART, "*.png"))}


# --- encoding -----------------------------------------------------------------

def _fit(img, w, h, name):
    if img.width * h != img.height * w:
        raise ValueError("%s: %dx%d is not the aspect of the %dx%d original"
                         % (name, img.width, img.height, w, h))
    if img.width < w:
        raise ValueError("%s: %dx%d is smaller than the %dx%d original" % (name, img.width, img.height, w, h))
    if img.size == (w, h):
        return img
    # Resampled as the tile it will be drawn as, so the kernel wraps instead of clamping.
    big = Image.new(img.mode, (img.width * 3, img.height * 3))
    for i in range(9):
        big.paste(img, ((i % 3) * img.width, (i // 3) * img.height))
    return big.resize((w * 3, h * 3), Image.LANCZOS).crop((w, h, 2 * w, 2 * h))


def _mip_sources(img, w, h):
    """Full-colour sources for all four levels. Alpha is averaged, colour premultiplied, so a
    hole texture's mips don't pick up the colour hiding under its transparent pixels."""
    pre = img.convert("RGBa")
    levels = [img]
    for i in (1, 2, 3):
        levels.append(pre.resize((max(1, w >> i), max(1, h >> i)), Image.BOX).convert("RGBA"))
    return levels


def encode(img, original):
    name, w, h = original.name, original.width, original.height
    img = _fit(img.convert("RGBA"), w, h, name)
    levels = _mip_sources(img, w, h)
    if norm(name) in DECALS:
        # Coverage ramp: index = alpha, palette = the original's (white..black ramp + tint at 255).
        # 255 itself decodes as a hole, so coverage tops out at 254 as the shipped decals do.
        mips = [bytes(min(a, 254) for a in lv.getchannel("A").tobytes()) for lv in levels]
        return Texture(name, w, h, mips, original.palette)

    keyed = name.startswith("{")
    colors = 255 if keyed else 256
    rgb = img.convert("RGB")
    if keyed:
        # Holes must not vote in the palette: fill them with the opaque pixels' mean first.
        solid = img.getchannel("A").point(lambda a: 255 if a >= 128 else 0)
        fill = tuple(int(c) for c in ImageStat.Stat(rgb, solid).mean) if solid.getbbox() else (0, 0, 0)
        rgb = Image.composite(rgb, Image.new("RGB", rgb.size, fill), solid)
    q = rgb.quantize(colors=colors, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    pal = bytearray(q.getpalette()[:colors * 3]).ljust(768, b"\0")
    if keyed:
        pal[765:768] = b"\0\0\xff"
    # Mips are mapped onto the full level's palette; 255 is withheld from that search on a
    # hole texture by pointing it at entry 0's colour and remapping it back.
    search = bytes(pal[:765]) + (bytes(pal[:3]) if keyed else bytes(pal[765:768]))
    pimg = Image.new("P", (1, 1))
    pimg.putpalette(search)
    mips = []
    for lv in levels:
        idx = bytearray(lv.convert("RGB").quantize(palette=pimg, dither=Image.Dither.NONE).tobytes())
        if keyed:
            alpha = lv.getchannel("A").tobytes()
            for i, a in enumerate(alpha):
                idx[i] = 255 if a < 128 else (0 if idx[i] == 255 else idx[i])
        mips.append(bytes(idx))
    return Texture(name, w, h, mips, bytes(pal))


# --- commands -----------------------------------------------------------------

def cmd_usage(args):
    wads = load_wads()
    for m in [args.map] if args.map else maps():
        res = resolve(m, wads)
        by = {}
        for name, w in res:
            by.setdefault(w or "(embedded)", []).append(name)
        print("%s: %d textures" % (m, len(res)))
        for w in sorted(by):
            print("  %-18s %3d  %s" % (w, len(by[w]), " ".join(sorted(by[w], key=norm)) if args.map else ""))


def cmd_status(args):
    reps = replacements()
    todo = [t for t in original_wad().textures() if norm(t.name) not in reps and norm(t.name) not in KEEP]
    total = len(original_wad().names()) - len(KEEP)
    print("%s: %d of %d stock textures replaced (%s kept as WW's own)" % (BASE, total - len(todo), total, ", ".join(sorted(KEEP))))
    for label, group in (("still original", [t for t in todo if norm(t.name) not in SKIP]),
                         ("tool textures, still original", [t for t in todo if norm(t.name) in SKIP])):
        if group:
            print("\n%s (%d):" % (label, len(group)))
            for t in sorted(group, key=lambda t: norm(t.name)):
                print("  %-16s %dx%d" % (t.name, t.width, t.height))


def cmd_extract(args):
    orig = original_wad()
    want = None
    if args.map:
        want = {norm(n) for n, w in resolve(args.map, load_wads()) if w == BASE and norm(n) not in SKIP}
    os.makedirs(args.out, exist_ok=True)
    count = 0
    for tex in orig.textures():
        if want is None or norm(tex.name) in want:
            to_image(tex).save(os.path.join(args.out, tex.name + ".png"))
            count += 1
    print("extracted %d original textures to %s" % (count, args.out))


def cmd_build(args):
    wad = original_wad()
    names = {norm(n): n for n in wad.names()}
    reps = replacements()
    for key, path in sorted(reps.items()):
        if key not in names:
            raise SystemExit("%s: %s has no texture %r to replace" % (path, BASE, key))
        wad.put(encode(Image.open(path), wad.texture(key)))
    out = os.path.join(ROOT, BASE)
    wad.save(out)
    print("%s: %d of %d textures replaced" % (BASE, len(reps), len(names)))
    for m in maps():
        invalidate_cache(os.path.join(ROOT, "maps", m + ".bsp"), quiet=True)
    # Extracted decal PNGs are reused whenever they exist, so they never notice a new WAD.
    for p in glob.glob(os.path.join(USERDATA, "decals", "*.png")):
        os.remove(p)
    print("dropped every cached .scn and extracted decal")


def cmd_sheet(args):
    orig, built = original_wad(), Wad(os.path.join(ROOT, BASE))
    reps = replacements()
    rows = [(n, to_image(orig.texture(n)), to_image(built.texture(n)))
            for n, w in resolve(args.map, load_wads()) if w == BASE and norm(n) in reps]
    if not rows:
        raise SystemExit("no replaced textures on %s" % args.map)
    cell, pad, label, cols = 200, 8, 14, 3
    pair = 2 * cell + 3 * pad
    rows_n = (len(rows) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * pair, rows_n * (cell + label + pad) + pad), (40, 40, 40))
    draw = ImageDraw.Draw(sheet)
    for i, (name, a, b) in enumerate(rows):
        x0 = (i % cols) * pair
        y = pad + (i // cols) * (cell + label + pad)
        draw.text((x0 + pad, y), name, fill=(230, 230, 230))
        for j, im in enumerate((a, b)):
            s = cell / max(im.size)
            im = im.resize((max(1, int(im.width * s)), max(1, int(im.height * s))), Image.NEAREST)
            bg = Image.new("RGBA", im.size, (255, 0, 255, 255))
            sheet.paste(Image.alpha_composite(bg, im).convert("RGB"), (x0 + pad + j * (cell + pad), y + label))
    sheet.save(args.out)
    print("%d textures -> %s" % (len(rows), args.out))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("usage")
    p.add_argument("--map")
    sub.add_parser("status")
    p = sub.add_parser("extract")
    p.add_argument("--map")
    p.add_argument("--out", default=os.path.join(ROOT, "build", "textures"))
    sub.add_parser("build")
    p = sub.add_parser("sheet")
    p.add_argument("--map", required=True)
    p.add_argument("--out", default=os.path.join(ROOT, "build", "texture_sheet.png"))
    args = ap.parse_args()
    {"usage": cmd_usage, "status": cmd_status, "extract": cmd_extract, "build": cmd_build,
     "sheet": cmd_sheet}[args.cmd](args)


if __name__ == "__main__":
    main()
