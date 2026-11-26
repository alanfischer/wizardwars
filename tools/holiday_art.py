#!/usr/bin/env python3
"""Draw the holiday props' detail layers into models/holiday/detail.png.

One strip of square layers, left to right in LAYERS order (HolidayProps.LAYER_* indexes it). A
layer's colour is a multiplier in gamma space, averaging about 0.8 so the shader's 1.25 gain leaves
a prop's vertex colour where it was. Where its alpha falls below 1 its colour is painted on instead,
whatever the vertex colour: gold dots on any paper, red stripes on a white cane. Everything is drawn
here from tileable noise and shapes; no photos.

  holiday_art.py        (needs Pillow and numpy)
"""

import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "models", "holiday", "detail.png")
S = 256
MEAN = 0.8
LAYERS = ["plain", "pumpkin", "gourd", "kernel", "husk", "wicker", "stem", "apple",
          "needles", "snow", "paper_dots", "paper_stripes", "candy", "bark"]

_yy, _xx = np.mgrid[0:S, 0:S] / S  # v down the rows, u across


def noise(seed, su, sv=None):
    """Tileable noise in 0..1; su, sv are feature sizes across u and v as fractions of the tile."""
    sv = su if sv is None else sv
    white = np.random.default_rng(seed).standard_normal((S, S))
    fy = np.fft.fftfreq(S)[:, None] * S
    fx = np.fft.fftfreq(S)[None, :] * S
    low = np.exp(-((fx * su) ** 2 + (fy * sv) ** 2) * 2.0)
    n = np.real(np.fft.ifft2(np.fft.fft2(white) * low))
    return (n - n.min()) / (n.max() - n.min())


def dots(seed, count, radius, soft=0.6):
    """Round spots scattered with wrap-around, 0 outside, 1 at a spot's middle."""
    rng = np.random.default_rng(seed)
    out = np.zeros((S, S))
    for _ in range(count):
        cx, cy = rng.random(2)
        r = radius * rng.uniform(0.6, 1.4)
        dx = (_xx - cx + 0.5) % 1.0 - 0.5
        dy = (_yy - cy + 0.5) % 1.0 - 0.5
        d = np.sqrt(dx * dx + dy * dy) / r
        out = np.maximum(out, np.clip((1.0 - d) / soft, 0.0, 1.0))
    return out


def bump_shade(height, k=6.0):
    """Light from up-left across a height field: a cheap emboss, centred on 0."""
    gx = np.roll(height, -1, 1) - np.roll(height, 1, 1)
    gy = np.roll(height, -1, 0) - np.roll(height, 1, 0)
    return np.clip(-(gx + gy) * k, -1.0, 1.0)


def rgb(lum, tint=(1.0, 1.0, 1.0)):
    return np.stack([lum * tint[0], lum * tint[1], lum * tint[2]], -1)


def plain():
    return rgb(np.full((S, S), MEAN))


def pumpkin():
    # Fine streaks down the meridians (v), a soft mottle, pale freckles.
    streaks = noise(11, 0.004, 0.08)
    mottle = noise(12, 0.08)
    lum = MEAN * (0.82 + 0.32 * streaks + 0.12 * (mottle - 0.5))
    out = rgb(lum)
    freckles = dots(13, 90, 0.008)
    out += freckles[..., None] * np.array([0.10, 0.10, 0.02])
    return out


def gourd():
    warts = dots(21, 55, 0.025, soft=1.0) ** 1.5
    mottle = noise(22, 0.05)
    lum = MEAN * (0.9 + 0.18 * (mottle - 0.5)) + 0.08 * warts
    lum += 0.10 * bump_shade(warts, 8.0)
    return rgb(lum)


def kernel():
    # One kernel per quad: u across it, v along the ear. Rounded, glossy, a pale crown at the base end.
    u = (_xx - 0.5) * 2.0
    v = (_yy - 0.5) * 2.0
    edge = np.clip(1.0 - np.maximum(np.abs(u) ** 3, np.abs(v) ** 3), 0.0, 1.0)
    lum = MEAN * (0.55 + 0.5 * edge ** 0.5)
    hl = np.exp(-(((u + 0.25) / 0.28) ** 2 + ((v + 0.3) / 0.35) ** 2))
    lum += 0.25 * hl
    crown = np.exp(-((u / 0.5) ** 2 + ((v - 0.75) / 0.22) ** 2))
    out = rgb(lum)
    out += crown[..., None] * np.array([0.12, 0.11, 0.06])
    return out


def husk():
    fibres = noise(41, 0.002, 0.2)
    veins = noise(42, 0.006, 0.5)
    lum = MEAN * (0.82 + 0.25 * fibres + 0.12 * (veins > 0.62))
    return rgb(lum)


def wicker():
    # Eight coils down the tile (v), each a round rod wrapped in slanted strands.
    coils = 8
    band = (_yy * coils) % 1.0
    rod = np.sin(band * np.pi) ** 0.6
    strands = 0.5 + 0.5 * np.sin((_xx * 24 + band * 0.9 + np.floor(_yy * coils) * 0.37) * 2 * np.pi)
    grain = noise(51, 0.003, 0.02)
    lum = MEAN * (0.45 + 0.55 * rod) * (0.82 + 0.22 * strands) * (0.9 + 0.2 * grain)
    lum /= lum.mean() / MEAN
    return rgb(lum, (1.0, 0.98, 0.94))


def stem():
    ridges = 0.5 + 0.5 * np.sin(_xx * 10 * 2 * np.pi)
    fibres = noise(61, 0.003, 0.15)
    knots = noise(62, 0.1)
    lum = MEAN * (0.72 + 0.2 * ridges + 0.2 * fibres + 0.1 * (knots - 0.5))
    return rgb(lum)


def apple():
    streaks = noise(71, 0.006, 0.12)
    lenticels = dots(72, 160, 0.004, soft=1.0)
    lum = MEAN * (0.88 + 0.24 * streaks)
    out = rgb(lum)
    out += lenticels[..., None] * np.array([0.18, 0.16, 0.06])
    return out


def painted(base, color, mask):
    """`color` painted over `base` where `mask` (0..1) is up: alpha 1 - mask."""
    out = np.concatenate([base, np.ones((S, S, 1))], -1)
    out[..., :3] = out[..., :3] * (1.0 - mask[..., None]) + np.array(color) * mask[..., None]
    out[..., 3] = 1.0 - mask
    return out


def strokes(seed, count, length, width, angle=None):
    """Short lines scattered with wrap-around, 0..1, drawn at 3x and filtered down."""
    rng = np.random.default_rng(seed)
    big = Image.new("L", (S * 3, S * 3), 0)
    d = ImageDraw.Draw(big)
    for _ in range(count):
        x, y = rng.random(2) * S
        a = rng.uniform(0, np.pi) if angle is None else angle + rng.normal(0, 0.25)
        ln = length * S * rng.uniform(0.6, 1.3)
        dx, dy = np.cos(a) * ln * 0.5, np.sin(a) * ln * 0.5
        shade = int(rng.uniform(120, 255))
        for ox in (0, S, 2 * S):
            for oy in (0, S, 2 * S):
                d.line([(x + ox - dx, y + oy - dy), (x + ox + dx, y + oy + dy)], fill=shade, width=width)
    tile = big.crop((S, S, 2 * S, 2 * S)).filter(ImageFilter.GaussianBlur(0.6))
    return np.asarray(tile, dtype=np.float64) / 255.0


def needles():
    # Layered fir needles: dark gaps, lit tips, slanting down the branch (v).
    dark = strokes(81, 900, 0.07, 2)
    light = strokes(82, 500, 0.05, 1)
    lum = MEAN * (0.6 + 0.4 * dark + 0.15 * light) + 0.1 * (noise(83, 0.1) - 0.5)
    return rgb(lum / (lum.mean() / MEAN), (0.95, 1.05, 0.95))


def snow():
    lumps = noise(91, 0.06)
    sparkle = dots(92, 140, 0.004, soft=1.0)
    lum = MEAN * (0.92 + 0.16 * (lumps - 0.5)) + 0.25 * sparkle
    return rgb(lum, (0.97, 0.99, 1.03))


def paper_dots():
    base = rgb(MEAN * (0.95 + 0.1 * noise(101, 0.02)))
    grid = np.zeros((S, S))
    for row in range(6):
        for col in range(6):
            cx = (col + 0.5 * (row % 2) + 0.25) / 6
            cy = (row + 0.5) / 6
            dx = (_xx - cx + 0.5) % 1.0 - 0.5
            dy = (_yy - cy + 0.5) % 1.0 - 0.5
            grid = np.maximum(grid, np.clip((0.035 - np.sqrt(dx * dx + dy * dy)) / 0.006, 0.0, 1.0))
    return painted(base, (0.93, 0.80, 0.35), grid)


def paper_stripes():
    band = ((_xx + _yy) * 5) % 1.0
    lum = MEAN * np.where(band < 0.5, 1.08, 0.86)
    pin = np.clip(1.0 - np.abs(band - 0.5) / 0.03, 0.0, 1.0)
    return painted(rgb(lum), (0.95, 0.90, 0.78), pin)


def candy():
    # Helical red stripes, a broad one and a thin one, round a white cane: u round it, v along.
    band = (_xx + _yy * 2) % 1.0
    broad = np.clip(1.0 - np.abs(band - 0.25) / 0.14, 0.0, 1.0) ** 0.3
    thin = np.clip(1.0 - np.abs(band - 0.62) / 0.035, 0.0, 1.0) ** 0.3
    red = np.clip(broad + thin, 0.0, 1.0)
    return painted(rgb(np.full((S, S), MEAN)), (0.78, 0.07, 0.08), red)


def bark():
    cracks = noise(121, 0.004, 0.06)
    lum = MEAN * (0.7 + 0.45 * cracks) + 0.08 * (noise(122, 0.05) - 0.5)
    return rgb(lum / (lum.mean() / MEAN))


def main():
    layers = []
    for name in LAYERS:
        layer = globals()[name]()
        if layer.shape[-1] == 3:
            layer = np.concatenate([layer, np.ones((S, S, 1))], -1)
        layers.append(layer)
    strip = np.concatenate(layers, axis=1)
    img = Image.fromarray((np.clip(strip, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8), "RGBA")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.save(OUT, optimize=True)
    print("wrote %s (%d layers)" % (OUT, len(LAYERS)))


if __name__ == "__main__":
    main()
