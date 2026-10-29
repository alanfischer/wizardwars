#!/usr/bin/env python3
"""Shared GoldSrc WAD3 access for the tools in this directory.

A WAD3 texture lump (type 0x43, miptex) is a 16-byte name, width, height, four mip offsets,
the four mip levels as 8-bit indices (full, 1/2, 1/4, 1/8), then a 256-entry RGB palette.
Every level indexes the SAME palette, so a mip can't introduce a colour the full level lacks.

Name prefixes carry meaning the engine reads off the name alone:
  {    alpha-tested: index 255 is a hole (its palette entry is conventionally 0,0,255)
  !    liquid (also * in Quake-derived maps)
  +0…  animation frames +0..+9; +a..+j are the alternate set a toggle switches to
  -0…  random tiling variants
In decals.wad a `{` texture is not a hole mask but a coverage ramp: the index IS the alpha
and palette[255] is the one colour the decal is drawn in.
"""

import struct

MIPTEX = 0x43
NAME_LEN = 16


def norm(name):
    return name.lower()


class Texture:
    """One miptex lump. `mips` are four bytes objects of palette indices, `palette` 768 bytes."""

    def __init__(self, name, width, height, mips, palette):
        self.name, self.width, self.height = name, width, height
        self.mips, self.palette = mips, palette

    @classmethod
    def parse(cls, data):
        name = data[:NAME_LEN].split(b"\0", 1)[0].decode("latin1")
        w, h = struct.unpack_from("<II", data, NAME_LEN)
        offs = struct.unpack_from("<4I", data, NAME_LEN + 8)
        mips = [bytes(data[o:o + (w >> i) * (h >> i)]) for i, o in enumerate(offs)]
        pal_at = offs[3] + (w >> 3) * (h >> 3)
        count = struct.unpack_from("<H", data, pal_at)[0]
        palette = bytes(data[pal_at + 2:pal_at + 2 + count * 3]).ljust(768, b"\0")
        return cls(name, w, h, mips, palette)

    def pack(self):
        head = 40
        offs, at = [], head
        for m in self.mips:
            offs.append(at)
            at += len(m)
        out = bytearray(self.name.encode("latin1")[:NAME_LEN - 1].ljust(NAME_LEN, b"\0"))
        out += struct.pack("<II4I", self.width, self.height, *offs)
        for m in self.mips:
            out += m
        out += struct.pack("<H", 256) + self.palette + b"\0\0"
        return bytes(out)

    def rgba(self, level=0, decal=False):
        """RGBA bytes of one mip level, applying the `{` (or decal) alpha convention."""
        w, h = self.width >> level, self.height >> level
        p = self.palette
        out = bytearray(w * h * 4)
        keyed = self.name.startswith("{")
        for i, c in enumerate(self.mips[level]):
            if decal:
                out[i * 4:i * 4 + 4] = bytes((p[765], p[766], p[767], c))
            else:
                a = 0 if keyed and c == 255 else 255
                out[i * 4:i * 4 + 4] = bytes((p[c * 3], p[c * 3 + 1], p[c * 3 + 2], a))
        return bytes(out)


class Wad:
    """Lumps in file order. Non-miptex lumps are kept as raw (type, bytes) and written back."""

    def __init__(self, path=None):
        self.path = path
        self.entries = []      # [name, type, bytes]
        if path:
            with open(path, "rb") as f:
                raw = f.read()
            magic, count, dir_at = struct.unpack_from("<4sii", raw, 0)
            if magic not in (b"WAD3", b"WAD2"):
                raise ValueError("%s: not a WAD (%r)" % (path, magic))
            for i in range(count):
                pos, disk, size, typ, comp, _, name = struct.unpack_from(
                    "<iiibbh16s", raw, dir_at + i * 32)
                if comp:
                    raise ValueError("%s: compressed lump %r" % (path, name))
                self.entries.append([name.split(b"\0", 1)[0].decode("latin1"), typ,
                                     raw[pos:pos + disk]])

    def names(self):
        return [e[0] for e in self.entries]

    def texture(self, name):
        for n, typ, data in self.entries:
            if norm(n) == norm(name) and typ == MIPTEX:
                return Texture.parse(data)
        return None

    def textures(self):
        return [Texture.parse(d) for _, typ, d in self.entries if typ == MIPTEX]

    def put(self, tex):
        """Replace the lump of the same name in place, or append one."""
        data = tex.pack()
        for e in self.entries:
            if norm(e[0]) == norm(tex.name):
                e[1], e[2] = MIPTEX, data
                return
        self.entries.append([tex.name, MIPTEX, data])

    def save(self, path):
        body = bytearray(b"WAD3" + b"\0" * 8)
        dirs = []
        for name, typ, data in self.entries:
            while len(body) % 4:
                body += b"\0"
            dirs.append((len(body), len(data), name, typ))
            body += data
        dir_at = len(body)
        for pos, size, name, typ in dirs:
            body += struct.pack("<iiibbh16s", pos, size, size, typ, 0, 0,
                                name.encode("latin1")[:NAME_LEN - 1].ljust(NAME_LEN, b"\0"))
        struct.pack_into("<ii", body, 4, len(dirs), dir_at)
        with open(path, "wb") as f:
            f.write(body)
