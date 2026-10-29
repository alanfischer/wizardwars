#!/usr/bin/env python3
"""Turn a recorded match into a top-down video (or GIF) over the map's own floorplan.

    # once per map — needs a real renderer, so no --headless
    MAP=ww_ravine SHOT=/tmp/ww_ravine.png godot --path . res://tools/map_top.tscn

    # in game: /record   ... play ...   /stoprecord
    tools/match_gif.py --csv ~/Library/.../replays/ww_ravine-....csv \
                       --backdrop /tmp/ww_ravine.png --out /tmp/match.mp4

mp4 by default: a four-minute match at 10 Hz is ~2400 frames, which is a very large GIF and a
small video, and a video gets you scrubbing. --gif when you want something to paste somewhere.
"""
import argparse, json, os, subprocess, sys, tempfile
from collections import defaultdict
from PIL import Image, ImageDraw

# Team colours match the game's own; state colours are for the ring drawn around a bot, and are
# deliberately loud because the whole point is spotting the odd one out at a glance.
TEAM = {1: (80, 140, 255), 2: (255, 80, 80), 3: (110, 220, 110), 4: (240, 210, 70)}
STATE = {
    "route":    None,                 # the normal case draws no ring
    "fighting": (255, 255, 255),
    "local":    (255, 170, 40),
    "rescue":   (255, 90, 200),
    "unstick":  (255, 40, 40),
    "lift":     (90, 230, 230),
    "roam":     (170, 170, 170),
    "player":   (255, 255, 255),
}
TRAIL = 40      # samples of tail behind each body


def load(csv_path, want_times=False):
    frames = defaultdict(list)
    with open(csv_path) as fh:
        for line in fh:
            if line.startswith("#") or line.startswith("t,"):
                continue
            p = line.rstrip("\n").split(",")
            if len(p) < 13:
                continue
            frames[round(float(p[0]), 1)].append({
                "id": int(p[1]), "name": p[2], "team": int(p[3]),
                "pos": (float(p[4]), float(p[6])), "yaw": float(p[7]),
                "alive": p[8] == "1", "carry": p[9] == "1",
                "state": p[10], "tgt": (float(p[11]), float(p[12])),
                "element": int(p[13]) if len(p) > 13 else -1,
            })
    keys = sorted(frames)
    if want_times:
        return [frames[k] for k in keys], keys
    return [frames[k] for k in keys]


def _tracks(frames, times):
    """Per-body timeline, so a marker can be placed BETWEEN samples.

    The recorders run at different rates (10Hz positions, 12Hz frames), so without this a
    marker is up to half a sample stale — about 30cm at running speed. Small next to the 11s
    drift this tool started with, but the point of the overlay is that you can trust where the
    dot is."""
    tr = defaultdict(list)
    for t, bodies in zip(times, frames):
        for b in bodies:
            tr[b["id"]].append((t, b))
    return tr


def _at(track, t):
    """The body at time `t`, position interpolated between the bracketing samples."""
    lo, hi = 0, len(track) - 1
    if t <= track[0][0]:
        return track[0][1]
    if t >= track[hi][0]:
        return track[hi][1]
    while lo + 1 < hi:
        mid = (lo + hi) // 2
        if track[mid][0] <= t:
            lo = mid
        else:
            hi = mid
    t0, a = track[lo]
    t1, b = track[hi]
    if t1 <= t0 or not (a["alive"] and b["alive"]):
        return a
    f = (t - t0) / (t1 - t0)
    out = dict(b)
    out["pos"] = (a["pos"][0] + (b["pos"][0] - a["pos"][0]) * f,
                  a["pos"][1] + (b["pos"][1] - a["pos"][1]) * f)
    return out


def _projector(meta):
    """World (x, z) -> pixel, from the transform the renderer published alongside the frames.

    The camera is rotated -90 about X, so screen right is world +X and screen down is world +Z.
    Orthographic, which is why this is a plain linear map.
    """
    scale, half = meta["scale_px_per_m"], meta["pixels"] / 2.0
    cx, cz = meta["centre"]
    return lambda p: (half + (p[0] - cx) * scale, half + (p[1] - cz) * scale)


def _encode(srcdir, ext, n, fps, out, gif):
    """Frames on disk -> one file. GIF holds every frame open at once, so it streams them."""
    if gif:
        paths = [os.path.join(srcdir, "f%05d.%s" % (i, ext)) for i in range(n)]
        first = Image.open(paths[0])
        first.save(out, save_all=True,
                   append_images=(Image.open(q) for q in paths[1:]),
                   duration=int(1000 / fps), loop=0, optimize=True)
    else:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(fps),
                        "-i", os.path.join(srcdir, "f%05d." + ext), "-pix_fmt", "yuv420p",
                        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", out], check=True)


def _overlay(src, dst, csv_path, meta, fps, n, routes):
    """Draw team markers from a /record CSV over /topview's real frames."""
    to_px = _projector(meta)
    frames, times = load(csv_path, want_times=True)
    tracks = _tracks(frames, times)
    # Match each rendered frame to when it was actually taken, not to frame_index / fps. The two
    # recorders run off different clocks at different rates, so anything else drifts.
    tpath = os.path.join(src, "times.csv")
    stamps = None
    if os.path.exists(tpath):
        stamps = {}
        for line in open(tpath):
            if line.startswith("frame"):
                continue
            a_, b_ = line.split(",")
            stamps[int(a_)] = float(b_)
    for i in range(n):
        img = Image.open(os.path.join(src, "f%05d.jpg" % i)).convert("RGB")
        d = ImageDraw.Draw(img, "RGBA")
        # The two recorders run at different rates, so index the CSV by TIME, not frame number.
        now = stamps[i] if (stamps is not None and i in stamps) else i / fps
        bodies = [_at(tr, now) for tr in tracks.values() if tr]
        for b in bodies:
            if b["state"] == "grail":
                x, y = to_px(b["pos"])
                r = 9 if b["carry"] else 7
                d.polygon([(x, y - r), (x + r, y), (x, y + r), (x - r, y)],
                          fill=(255, 225, 120, 230), outline=(120, 90, 0, 255))
                continue
            if not b["alive"]:
                continue
            x, y = to_px(b["pos"])
            col = TEAM.get(b["team"], (200, 200, 200))
            if routes and b["tgt"] != (0.0, 0.0):
                d.line([(x, y), to_px(b["tgt"])], fill=col + (70,), width=1)
            ring = STATE.get(b["state"])
            if ring:
                d.ellipse([x - 11, y - 11, x + 11, y + 11], outline=ring + (220,), width=2)
            d.ellipse([x - 5, y - 5, x + 5, y + 5], fill=col + (235,),
                      outline=(0, 0, 0, 180), width=1)
        d.text((8, 8), "%s   t=%5.1fs" % (meta.get("map", ""), now), fill=(255, 255, 255))
        img.save(os.path.join(dst, "f%05d.jpg" % i), quality=88)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", help="positions from /record (schematic mode)")
    ap.add_argument("--frames", help="directory of JPEGs from /topview (real-render mode)")
    ap.add_argument("--backdrop", help="PNG from tools/map_top.gd (schematic mode)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--fps", type=int, default=20)
    ap.add_argument("--gif", action="store_true")
    ap.add_argument("--routes", action="store_true", help="draw each bot's current target")
    a = ap.parse_args()

    # Real-render mode: /topview already produced actual frames of the game, so there is nothing
    # to composite — just encode them.
    if a.frames:
        meta_p = os.path.join(a.frames, "meta.json")
        fps = a.fps
        meta = {}
        if os.path.exists(meta_p):
            meta = json.load(open(meta_p))
            fps = int(round(meta.get("fps", a.fps)))
        n = len([f for f in os.listdir(a.frames) if f.endswith(".jpg")])
        if not n:
            sys.exit("no frames in %s" % a.frames)
        tp = os.path.join(a.frames, "times.csv")
        if os.path.exists(tp):
            last = [float(l.split(",")[1]) for l in open(tp) if not l.startswith("frame")]
            if last and last[-1] > 1.0:
                fps = round(n / last[-1], 2)   # real average, so the video runs at real speed
        # With a CSV too, draw the markers ON the real render: the render carries the spells and
        # effects, the markers make six 6px bodies findable. Best of both, and they already agree
        # on the transform because both writers emit the same one.
        if a.csv and meta:
            src = a.frames
            a.frames = tempfile.mkdtemp(prefix="matchover")
            _overlay(src, a.frames, a.csv, meta, fps, n, a.routes)
        _encode(a.frames, "jpg", n, fps, a.out, a.gif)
        print("%d frames -> %s" % (n, a.out))
        return
    if not a.csv or not a.backdrop:
        sys.exit("give either --frames <dir>, or --csv with --backdrop")

    meta_path = a.backdrop + ".json"
    if not os.path.exists(meta_path):
        sys.exit("missing %s — re-run tools/map_top.gd, it writes the transform alongside the PNG"
                 % meta_path)
    meta = json.load(open(meta_path))
    to_px = _projector(meta)

    base = Image.open(a.backdrop).convert("RGB")
    frames = load(a.csv)
    if not frames:
        sys.exit("no samples in %s" % a.csv)
    trails = defaultdict(list)
    tmp = tempfile.mkdtemp(prefix="matchgif")

    for i, bodies in enumerate(frames):
        img = base.copy()
        d = ImageDraw.Draw(img, "RGBA")
        for b in bodies:
            if b["state"] == "grail":
                continue
            if b["alive"]:
                trails[b["id"]].append(to_px(b["pos"]))
                del trails[b["id"]][:-TRAIL]
            else:
                trails[b["id"]].clear()
        # Trails first so the bodies sit on top of them.
        for b in bodies:
            if b["state"] == "grail":
                continue
            t = trails[b["id"]]
            col = TEAM.get(b["team"], (200, 200, 200))
            for j in range(1, len(t)):
                al = int(200 * j / len(t))
                d.line([t[j - 1], t[j]], fill=col + (al,), width=2)
        # Grails last-but-one so they sit above trails, below nothing that matters.
        for b in bodies:
            if b["state"] != "grail":
                continue
            x, y = to_px(b["pos"])
            col = TEAM.get(b["team"], (230, 210, 120))
            r = 9 if b["carry"] else 7
            d.polygon([(x, y - r), (x + r, y), (x, y + r), (x - r, y)],
                      fill=(255, 225, 120, 255), outline=col + (255,))
            if b["carry"]:
                d.ellipse([x - 13, y - 13, x + 13, y + 13],
                          outline=(255, 235, 140, 200), width=2)
        for b in bodies:
            if not b["alive"] or b["state"] == "grail":
                continue
            x, y = to_px(b["pos"])
            col = TEAM.get(b["team"], (200, 200, 200))
            if a.routes and b["tgt"] != (0.0, 0.0):
                d.line([(x, y), to_px(b["tgt"])], fill=col + (90,), width=1)
            ring = STATE.get(b["state"])
            if ring:
                d.ellipse([x - 7, y - 7, x + 7, y + 7], outline=ring + (230,), width=2)
            d.ellipse([x - 4, y - 4, x + 4, y + 4], fill=col + (255,))
            if b["carry"]:
                d.ellipse([x - 10, y - 10, x + 10, y + 10], outline=(255, 255, 90, 255), width=2)
        d.text((8, 8), "%s   t=%5.1fs" % (meta["map"], i / 10.0), fill=(255, 255, 255))
        img.save(os.path.join(tmp, "f%05d.png" % i))

    _encode(tmp, "png", len(frames), a.fps, a.out, a.gif)
    print("%d frames -> %s" % (len(frames), a.out))


if __name__ == "__main__":
    main()
