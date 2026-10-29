#!/usr/bin/env python3
"""GoldSrc sprite (.spr, IDSP version 2) read/write for the tools in this directory.

Header: IDSP, version, type, texture format, bounding radius, width, height, frame count,
beam length, sync type; then a u16 palette count and that many RGB entries (always 256).
Each frame is an int frame type: 0 is one image (origin x/y, width, height, 8-bit indices),
anything else a group (count, a float interval per image, then the images without types).

Texture formats, which decide what an index means:
  normal      opaque
  additive    added to the scene, so black (whatever the colours are) is invisible
  indexalpha  the index IS the alpha; palette[255] is the one colour drawn
  alphatest   index 255 is a hole (its palette entry is conventionally 0,0,255)

  spr.py info FILE...           print each header
  spr.py extract FILE OUTDIR    write every frame as OUTDIR/NN.png (needs Pillow)
  spr.py check [FILE...]        unpack and repack, and require the same bytes (sprites/ by default)
"""

import glob
import os
import struct
import sys

TYPES = ("parallel_upright", "facing_upright", "parallel", "oriented", "parallel_oriented")
FORMATS = ("normal", "additive", "indexalpha", "alphatest")
HEADER = "<4siiifiiifi"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Frame:
    """One image. `pixels` are palette indices, row by row."""

    def __init__(self, width, height, pixels, origin=None):
        self.width, self.height, self.pixels = width, height, pixels
        self.origin = origin if origin is not None else (-(width // 2), height // 2)


class Sprite:
    """`frames` holds a Frame per entry, or a list of (interval, Frame) for a group."""

    def __init__(self, type=2, format=1, frames=None, palette=None, radius=None,
                 beam_length=0.0, sync=0):
        self.type, self.format = type, format
        self.frames = frames or []
        self.palette = palette or bytes(768)
        self.radius, self.beam_length, self.sync = radius, beam_length, sync

    @classmethod
    def load(cls, path):
        with open(path, "rb") as f:
            return cls.parse(f.read())

    @classmethod
    def parse(cls, data):
        magic, ver, typ, fmt, radius, _, _, count, beam, sync = struct.unpack_from(HEADER, data, 0)
        if magic != b"IDSP" or ver != 2:
            raise ValueError("not a version 2 sprite (%r, %d)" % (magic, ver))
        at = struct.calcsize(HEADER)
        ncolors = struct.unpack_from("<H", data, at)[0]
        palette = bytes(data[at + 2:at + 2 + ncolors * 3])
        at += 2 + ncolors * 3

        def image(at):
            ox, oy, w, h = struct.unpack_from("<4i", data, at)
            return Frame(w, h, bytes(data[at + 16:at + 16 + w * h]), (ox, oy)), at + 16 + w * h

        frames = []
        for _ in range(count):
            kind = struct.unpack_from("<i", data, at)[0]
            at += 4
            if kind == 0:
                frame, at = image(at)
                frames.append(frame)
                continue
            n = struct.unpack_from("<i", data, at)[0]
            intervals = struct.unpack_from("<%df" % n, data, at + 4)
            at += 4 + 4 * n
            group = []
            for t in intervals:
                frame, at = image(at)
                group.append((t, frame))
            frames.append(group)
        return cls(typ, fmt, frames, palette, radius, beam, sync)

    def images(self):
        """Every Frame, groups flattened."""
        out = []
        for f in self.frames:
            out.extend([g for _, g in f] if isinstance(f, list) else [f])
        return out

    def pack(self):
        imgs = self.images()
        w = max(f.width for f in imgs)
        h = max(f.height for f in imgs)
        radius = self.radius if self.radius is not None else ((w / 2) ** 2 + (h / 2) ** 2) ** 0.5
        out = bytearray(struct.pack(HEADER, b"IDSP", 2, self.type, self.format, radius, w, h,
                                    len(self.frames), self.beam_length, self.sync))
        out += struct.pack("<H", len(self.palette) // 3) + self.palette

        def image(f):
            return struct.pack("<4i", f.origin[0], f.origin[1], f.width, f.height) + f.pixels

        for f in self.frames:
            if isinstance(f, list):
                out += struct.pack("<ii", 1, len(f)) + struct.pack("<%df" % len(f), *[t for t, _ in f])
                for _, g in f:
                    out += image(g)
            else:
                out += struct.pack("<i", 0) + image(f)
        return bytes(out)

    def save(self, path):
        with open(path, "wb") as f:
            f.write(self.pack())

    def rgba(self, frame):
        """RGBA bytes of one Frame, applying this sprite's texture format."""
        p = self.palette
        out = bytearray(frame.width * frame.height * 4)
        for i, c in enumerate(frame.pixels):
            if self.format == 2:
                px = (p[765], p[766], p[767], c)
            else:
                a = 0 if self.format == 3 and c == 255 else 255
                px = (p[c * 3], p[c * 3 + 1], p[c * 3 + 2], a)
            out[i * 4:i * 4 + 4] = bytes(px)
        return bytes(out)

    def to_images(self):
        from PIL import Image
        return [Image.frombytes("RGBA", (f.width, f.height), self.rgba(f)) for f in self.images()]

    def set_images(self, images):
        """Replace every frame's pixels with PIL images, quantised to one shared palette.

        normal/additive use all 256 colours. alphatest keeps index 255 for pixels with alpha
        under 128. indexalpha takes the alpha as the index and the mean opaque colour as
        palette[255]. Frame origins are kept when the frame count and sizes match.
        """
        from PIL import Image
        old = self.images()
        keep = len(old) == len(images) and all(
            (o.width, o.height) == im.size for o, im in zip(old, images))
        frames = []
        if self.format == 2:
            colour = _mean_colour(images)
            self.palette = bytes(765) + bytes(colour)
            for im in images:
                frames.append(Frame(im.width, im.height, im.convert("RGBA").getchannel("A").tobytes()))
        else:
            ncolors = 255 if self.format == 3 else 256
            sheet = Image.new("RGB", (max(im.width for im in images), sum(im.height for im in images)))
            y = 0
            for im in images:
                sheet.paste(im.convert("RGB"), (0, y))
                y += im.height
            q = sheet.quantize(ncolors, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
            pal = bytes(q.getpalette()[:ncolors * 3]).ljust(768, b"\0")
            if self.format == 3:
                pal = pal[:765] + bytes((0, 0, 255))
            self.palette = pal
            y = 0
            for im in images:
                idx = bytearray(q.crop((0, y, im.width, y + im.height)).tobytes())
                if self.format == 3:
                    alpha = im.convert("RGBA").getchannel("A").tobytes()
                    for i, a in enumerate(alpha):
                        if a < 128:
                            idx[i] = 255
                frames.append(Frame(im.width, im.height, bytes(idx)))
                y += im.height
        if keep:
            for f, o in zip(frames, old):
                f.origin = o.origin
        self.frames = frames


def _mean_colour(images):
    total, n = [0, 0, 0], 0
    for im in images:
        px = im.convert("RGBA").tobytes()
        for i in range(0, len(px), 4):
            r, g, b, a = px[i:i + 4]
            if a >= 128:
                total[0] += r
                total[1] += g
                total[2] += b
                n += 1
    return [round(c / max(n, 1)) for c in total]


def describe(path, s):
    imgs = s.images()
    groups = sum(isinstance(f, list) for f in s.frames)
    return "%-28s %-17s %-10s %3dx%-3d %2d frames%s" % (
        os.path.relpath(path, ROOT), TYPES[s.type], FORMATS[s.format],
        imgs[0].width, imgs[0].height, len(imgs), " (%d groups)" % groups if groups else "")


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "info":
        for p in args:
            print(describe(p, Sprite.load(p)))
    elif cmd == "extract":
        s = Sprite.load(args[0])
        os.makedirs(args[1], exist_ok=True)
        for i, im in enumerate(s.to_images()):
            im.save(os.path.join(args[1], "%02d.png" % i))
    elif cmd == "check":
        paths = args or sorted(glob.glob(os.path.join(ROOT, "sprites", "**", "*.spr"), recursive=True))
        bad = 0
        for p in paths:
            with open(p, "rb") as f:
                data = f.read()
            if Sprite.parse(data).pack() != data:
                print("MISMATCH", os.path.relpath(p, ROOT))
                bad += 1
        print("%d/%d sprites repack byte-identical" % (len(paths) - bad, len(paths)))
        return 1 if bad else 0
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
