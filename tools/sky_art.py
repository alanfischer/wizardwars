#!/usr/bin/env python3
"""Make GoldSrc skyboxes (sky/<name>{rt,bk,lf,ft,up,dn}.tga) from CC0 panoramas or code.

  sky_art.py [NAME ...]    build the named skies (all of them when none are given)
  sky_art.py --check NAME  measure how well an existing sky's faces meet at their edges

Panoramas come from Poly Haven (CC0, cached under build/polyhaven/), as their tonemapped
equirectangular JPGs, and are projected onto the six faces. Each sky is pulled toward the
colour statistics of the one it replaces, so a map keeps its lighting: SkyPreset measures the
sky art for ambient fill. sky/CREDITS.md says where each came from. Needs Pillow.

Face orientation follows GoldSrc's MakeSkyVec (Quake 2's st_to_vec / skytexorder): a face
pixel (u, v) in [0, 1] maps to s = 2u - 1, t = 1 - 2v, and the axis table below gives the
direction in Quake coordinates (x forward, y left, z up).
"""

import math
import os
import random
import sys
import urllib.request

from PIL import Image, ImageStat

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKY = os.path.join(ROOT, "sky")
CACHE = os.path.join(ROOT, "build", "polyhaven")
SIZE = 256
FACES = ("rt", "bk", "lf", "ft", "up", "dn")


def direction(face, u, v):
    s, t = 2 * u - 1, 1 - 2 * v
    return {
        "rt": (1, -s, t),
        "lf": (-1, s, t),
        "bk": (s, 1, t),
        "ft": (-s, -1, t),
        "up": (-t, -s, 1),
        "dn": (t, -s, -1),
    }[face]


def face_at(d):
    """The face and (u, v) a direction lands on: the inverse of direction()."""
    x, y, z = d
    ax, ay, az = abs(x), abs(y), abs(z)
    if ax >= ay and ax >= az:
        face, s, t = ("rt", -y / ax, z / ax) if x > 0 else ("lf", y / ax, z / ax)
    elif ay >= az:
        face, s, t = ("bk", x / ay, z / ay) if y > 0 else ("ft", -x / ay, z / ay)
    else:
        face, s, t = ("up", -y / az, -x / az) if z > 0 else ("dn", -y / az, x / az)
    return face, (s + 1) / 2, (1 - t) / 2


def from_panorama(pano, yaw=0.0, size=SIZE):
    """Project an equirectangular panorama onto the six faces. yaw turns it (degrees)."""
    W, H = pano.size
    src = pano.convert("RGB").load()
    out = {}
    for f in FACES:
        img = Image.new("RGB", (size, size))
        px = []
        for j in range(size):
            for i in range(size):
                x, y, z = direction(f, (i + 0.5) / size, (j + 0.5) / size)
                lon = math.atan2(y, x) + math.radians(yaw)
                lat = math.atan2(z, math.hypot(x, y))
                u = (0.5 - lon / math.tau) % 1.0
                v = min(max(0.5 - lat / math.pi, 0.0), 1.0)
                px.append(src[min(int(u * W), W - 1), min(int(v * H), H - 1)])
        img.putdata(px)
        out[f] = img
    return out


def starfield(seed, stars=12000, size=SIZE):
    """Stars scattered over the sphere, so the faces meet by construction."""
    rnd = random.Random(seed)
    faces = {f: Image.new("RGB", (size, size), (0, 0, 1)) for f in FACES}
    for _ in range(stars):
        z = rnd.uniform(-1, 1)
        a = rnd.uniform(0, math.tau)
        r = math.sqrt(1 - z * z)
        f, u, v = face_at((r * math.cos(a), r * math.sin(a), z))
        b = int(255 * rnd.random() ** 4)
        tint = rnd.choice([(1, 1, 1), (1, 1, 1), (0.8, 0.9, 1), (1, 0.9, 0.75)])
        x, y = min(int(u * size), size - 1), min(int(v * size), size - 1)
        faces[f].putpixel((x, y), tuple(int(b * c) for c in tint))
    return faces


def match_set(faces, mean, stddev, spread=0.7):
    """Pull the whole set toward a per-channel mean and (spread of) a contrast."""
    strip = Image.new("RGB", (SIZE * len(faces), SIZE))
    for i, f in enumerate(FACES):
        strip.paste(faces[f].convert("RGB").resize((SIZE, SIZE)), (i * SIZE, 0))
    a = ImageStat.Stat(strip)
    out = {}
    for f in FACES:
        bands = []
        for ch, band in enumerate(faces[f].split()):
            k = 1 + spread * (stddev[ch] / max(a.stddev[ch], 1e-3) - 1)
            bands.append(band.point(lambda v, k=k, ma=a.mean[ch], mb=mean[ch]:
                                    max(0, min(255, int(round((v - ma) * k + mb))))))
        out[f] = Image.merge("RGB", bands)
    return out


def load_set(name):
    return {f: Image.open(os.path.join(SKY, "%s%s.tga" % (name, f))).convert("RGB") for f in FACES}


def polyhaven(asset):
    path = os.path.join(CACHE, asset + ".jpg")
    if not os.path.exists(path):
        os.makedirs(CACHE, exist_ok=True)
        url = "https://dl.polyhaven.org/file/ph-assets/HDRIs/extra/Tonemapped%%20JPG/%s.jpg" % asset
        req = urllib.request.Request(url, headers={"User-Agent": "wizardwars-sky-art"})
        with urllib.request.urlopen(req) as r, open(path, "wb") as f:
            f.write(r.read())
    return Image.open(path)


def seam_check(name):
    """Mean colour step across face edges, against the mean step between neighbouring pixels
    inside a face. Near 1 means the faces meet; a wrong orientation table reads far above it."""
    faces = load_set(name)
    px = {f: faces[f].load() for f in FACES}
    n = faces["rt"].width
    across = inside = count = 0
    for f in FACES:
        for k in range(n):
            for (i, j, di, dj) in ((k, 0, 0, -1), (k, n - 1, 0, 1), (0, k, -1, 0), (n - 1, k, 1, 0)):
                d = direction(f, (i + 0.5 + di) / n, (j + 0.5 + dj) / n)
                g, u, v = face_at(d)
                a = px[f][i, j]
                b = px[g][min(int(u * n), n - 1), min(int(v * n), n - 1)]
                c = px[f][min(max(i - di, 0), n - 1), min(max(j - dj, 0), n - 1)]
                across += sum(abs(x - y) for x, y in zip(a, b))
                inside += sum(abs(x - y) for x, y in zip(a, c))
                count += 1
    return across / count, inside / count


# The colour statistics (per-channel mean, stddev over all six faces) of the stock skies these
# replace, measured once, so the maps keep the light they were built under.
NIGHT = ((15.6, 14.9, 38.9), (15.4, 14.9, 18.7))
AVANTI = ((21.6, 23.0, 34.1), (12.6, 12.7, 21.8))

# name -> (how to make it, credit)
SKIES = {
    "night": (lambda: match_set(from_panorama(polyhaven("rogland_clear_night")), *NIGHT),
              "Poly Haven rogland_clear_night (CC0)"),
    "avanti": (lambda: match_set(from_panorama(polyhaven("moonlit_golf")), *AVANTI),
               "Poly Haven moonlit_golf (CC0)"),
    "space": (lambda: starfield(7), "drawn: starfield"),
}


def write_credits(done):
    path = os.path.join(SKY, "CREDITS.md")
    known = {}
    if os.path.exists(path):
        for line in open(path):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if line.startswith("| `") and len(cells) == 2:
                known[cells[0].strip("`")] = cells[1]
    known.update(done)
    with open(path, "w") as f:
        f.write("# Sky sources\n\nSkies made by tools/sky_art.py. Poly Haven panoramas are CC0 "
                "(https://polyhaven.com); \"drawn\" skies are generated by the script. The other sets "
                "here carry their own credit files.\n\n| sky | source |\n|---|---|\n")
        for name, src in sorted(known.items()):
            f.write("| `%s` | %s |\n" % (name, src))


def main():
    args = sys.argv[1:]
    if args[:1] == ["--check"]:
        for name in args[1:]:
            a, b = seam_check(name)
            print("%s: step across edges %.1f, inside faces %.1f" % (name, a, b))
        return
    done = {}
    for name, (make, credit) in SKIES.items():
        if args and name not in args:
            continue
        for f, img in make().items():
            img.convert("RGB").save(os.path.join(SKY, "%s%s.tga" % (name, f)))
        done[name] = credit
        print(name)
    write_credits(done)


if __name__ == "__main__":
    main()
