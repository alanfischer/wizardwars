#!/usr/bin/env python3
"""Shared GoldSrc BSP access for the tools in this directory.

These maps have no .map sources -- `maps/` is 30 shipped .bsp files and nothing else -- so
every edit is byte surgery on an irreplaceable artifact. The whole design follows from that:
lumps are held as opaque bytes and only the ones a tool actually touches are ever rewritten.

Three save modes, weakest to strongest, each with a different guarantee. Prefer the weakest
one that does the job:

  save_entities()  entity lump only. Lumps are laid back to back in their existing order, so
                   every other lump's bytes are unchanged and no dead space builds up.
                   This is what almost every tool here wants.
  save_in_place()  modified lumps spliced back at their original offsets; sizes must match.
  save_repack()    rebuilds the directory. The only way to resize a non-entity lump, and the
                   only mode that re-serializes typed lumps.

Typed lumps are parsed lazily and verified on first access: the parsed rows are packed back
and compared against the original bytes, raising on any mismatch. A struct-format bug fails
loudly at load instead of quietly corrupting a map at save.

Hand-editing a .bsp does NOT invalidate the runtime conversion cache -- MapConverter gates
purely on CACHE_VERSION, and the .hash sidecar is the md5 of the OUTPUT .scn, not the source.
The save helpers call invalidate_cache() for you. The editor's own .godot/imported copy keys
on the source file, so `Godot --headless --path . --import` picks an edit up on its own.
"""

import os
import re
import shutil
import struct

LUMP_NAMES = ["entities", "planes", "textures", "vertexes", "visibility", "nodes", "texinfo",
              "faces", "lighting", "clipnodes", "leafs", "marksurfaces", "edges", "surfedges",
              "models"]
LUMP = {name: i for i, name in enumerate(LUMP_NAMES)}
NUM_LUMPS = len(LUMP_NAMES)

# name -> (struct format, record size). Anything absent stays an opaque blob.
SPECS = {
    "planes":       ("<3ffi",      20),
    "vertexes":     ("<3f",        12),
    "edges":        ("<2H",         4),
    "surfedges":    ("<i",          4),
    "texinfo":      ("<4f4fIi",    40),
    "faces":        ("<HHiHH4Bi",  20),
    "nodes":        ("<i8h2H",     24),
    "leafs":        ("<ii6h2H4B",  28),
    "models":       ("<9f7i",      64),
    "marksurfaces": ("<H",          2),
    "clipnodes":    ("<i2h",        8),
}

# Single-field lumps are held as flat lists of ints, not 1-tuples, so a tool can append to
# them directly -- a derived list would silently swallow the write.
SCALARS = {"surfedges", "marksurfaces"}

CONTENTS_EMPTY, CONTENTS_SOLID = -1, -2

CACHE_DIR = os.path.expanduser(
    "~/Library/Application Support/Godot/app_userdata/Wizard Wars/resources/maps")


def dot(a, b): return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]


def _lump(name):
    """A typed lump as a property: mutate the list in place, or assign a whole new one."""
    return property(lambda s: s.typed(name),
                    lambda s, rows: s._set_typed(name, rows))


class Bsp:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.raw = bytearray(f.read())
        self.version = struct.unpack_from("<i", self.raw, 0)[0]
        self.dir = [struct.unpack_from("<ii", self.raw, 4 + i * 8) for i in range(NUM_LUMPS)]
        self.lumps = {}
        for i, name in enumerate(LUMP_NAMES):
            off, ln = self.dir[i]
            self.lumps[name] = bytearray(self.raw[off:off + ln])
        self._typed = {}
        self._ents = None

    # --- typed lumps --------------------------------------------------------

    def typed(self, name):
        """Rows of `name` as mutable lists. Verified round-trippable on first access."""
        if name not in self._typed:
            fmt, size = SPECS[name]
            d = self.lumps[name]
            if name in SCALARS:
                rows = [struct.unpack_from(fmt, d, i * size)[0] for i in range(len(d) // size)]
            else:
                rows = [list(struct.unpack_from(fmt, d, i * size)) for i in range(len(d) // size)]
            if self._pack(name, rows) != bytes(d):
                raise ValueError("%s: lump %r does not round-trip through %r -- refusing to "
                                 "risk a save" % (os.path.basename(self.path), name, fmt))
            self._typed[name] = rows
        return self._typed[name]

    def _pack(self, name, rows):
        fmt, _ = SPECS[name]
        if name in SCALARS:
            return b"".join(struct.pack(fmt, r) for r in rows)
        return b"".join(struct.pack(fmt, *r) for r in rows)

    def _set_typed(self, name, rows):
        self.typed(name)          # validate the original before replacing it
        self._typed[name] = rows

    planes = _lump("planes")
    verts = _lump("vertexes")
    edges = _lump("edges")
    texinfo = _lump("texinfo")
    faces = _lump("faces")
    nodes = _lump("nodes")
    leafs = _lump("leafs")
    models = _lump("models")
    clipnodes = _lump("clipnodes")
    surfedges = _lump("surfedges")
    marks = _lump("marksurfaces")

    @property
    def lighting(self):
        return self.lumps["lighting"]

    @lighting.setter
    def lighting(self, data):
        self.lumps["lighting"] = bytearray(data)

    def texnames(self):
        d = self.lumps["textures"]
        if not d:
            return []
        nummip = struct.unpack_from("<i", d, 0)[0]
        out = []
        for o in struct.unpack_from("<%di" % nummip, d, 4):
            if o < 0 or o + 16 > len(d):
                out.append("")
            else:
                out.append(bytes(d[o:o + 16]).split(b"\0", 1)[0].decode("latin1"))
        return out

    # --- geometry helpers ---------------------------------------------------

    def face_verts(self, fi):
        f = self.faces[fi]
        out = []
        for k in range(f[3]):
            se = self.surfedges[f[2] + k]
            e = self.edges[abs(se)]
            out.append(tuple(self.verts[e[0] if se >= 0 else e[1]]))
        return out

    def _descend(self, p, head):
        n = head
        while n >= 0:
            nd = self.nodes[n]
            pl = self.planes[nd[0]]
            n = nd[1] if dot(p, pl[:3]) - pl[3] >= 0 else nd[2]
        return ~n

    def leaf_index(self, p, head):
        return self._descend(p, head)

    def leaf_contents(self, p, head):
        return self.leafs[self._descend(p, head)][0]

    # --- entity lump --------------------------------------------------------

    @property
    def entities(self):
        if self._ents is None:
            self._ents = bytes(self.lumps["entities"]).decode("latin1").rstrip("\x00")
        return self._ents

    @entities.setter
    def entities(self, text):
        self._ents = text

    def blocks(self, text=None):
        return re.findall(r"\{.*?\}", self.entities if text is None else text, re.S)

    def find(self, classname, text=None):
        """Entity blocks whose classname matches `classname` (a plain name or a regex)."""
        pat = r'"classname"\s+"(?:%s)"' % classname
        return [b for b in self.blocks(text) if re.search(pat, b)]

    @staticmethod
    def key(block, name, default=None):
        m = re.search(r'"%s"\s+"([^"]*)"' % re.escape(name), block)
        return m.group(1) if m else default

    # --- saving -------------------------------------------------------------

    def _payload(self):
        # Only the NUL is stripped on read, so text that already ended in a newline keeps it.
        # That is what every tool here has written into the shipped maps; trailing whitespace
        # in the entity lump is insignificant, and matching it keeps edits byte-comparable.
        return (self.entities + "\n\x00").encode("latin1")

    def _backup(self):
        if not os.path.exists(self.path + ".bak"):
            shutil.copyfile(self.path, self.path + ".bak")

    def save_entities(self, path=None, dry=False, quiet=False):
        """Rewrite lump 0 only: repack in the current physical order, other lumps' bytes as-is."""
        path = path or self.path
        payload = self._payload()
        if dry:
            if not quiet:
                print("--- dry run, not written (%d entity bytes) ---" % len(payload))
            return False
        self._backup()
        out = bytearray(self.raw[:4 + NUM_LUMPS * 8])
        for i in sorted(range(NUM_LUMPS), key=lambda i: self.dir[i]):
            off, ln = self.dir[i]
            data = payload if i == LUMP["entities"] else self.raw[off:off + ln]
            while len(out) % 4:
                out.append(0)
            struct.pack_into("<ii", out, 4 + i * 8, len(out), len(data))
            out += data
        with open(path, "wb") as f:
            f.write(out)
        invalidate_cache(path)
        if not quiet:
            print("wrote %s (entity lump %d bytes); backup at %s.bak"
                  % (path, len(payload), self.path))
        return True

    def save_in_place(self, path=None, dry=False, quiet=False):
        """Splice modified lumps back at their original offsets. Sizes must be unchanged."""
        path = path or self.path
        raw = bytearray(self.raw)
        changed = []
        for i, name in enumerate(LUMP_NAMES):
            data = self._pack(name, self._typed[name]) if name in self._typed \
                else bytes(self.lumps[name])
            off, ln = self.dir[i]
            if data == bytes(raw[off:off + ln]):
                continue
            if len(data) != ln:
                raise ValueError("%s: lump %r changed size (%d -> %d); use save_repack()"
                                 % (os.path.basename(path), name, ln, len(data)))
            raw[off:off + ln] = data
            changed.append(name)
        if dry:
            if not quiet:
                print("--- dry run, not written (lumps: %s) ---" % (", ".join(changed) or "none"))
            return False
        if not changed:
            if not quiet:
                print("nothing changed, not written")
            return False
        self._backup()
        with open(path, "wb") as f:
            f.write(raw)
        invalidate_cache(path)
        if not quiet:
            print("wrote %s (in place: %s); backup at %s.bak"
                  % (path, ", ".join(changed), self.path))
        return True

    def save_repack(self, path=None, dry=False, quiet=False):
        """Rebuild the lump directory. The only mode that can resize a non-entity lump."""
        path = path or self.path
        for name in self._typed:
            self.lumps[name] = bytearray(self._pack(name, self._typed[name]))
        if self._ents is not None:
            self.lumps["entities"] = bytearray(self._payload())
        out = bytearray(struct.pack("<i", self.version) + b"\0" * (NUM_LUMPS * 8))
        for i, name in enumerate(LUMP_NAMES):
            while len(out) % 4:
                out += b"\0"
            struct.pack_into("<ii", out, 4 + i * 8, len(out), len(self.lumps[name]))
            out += self.lumps[name]
        if dry:
            if not quiet:
                print("--- dry run, not written (%d bytes) ---" % len(out))
            return False
        self._backup()
        with open(path, "wb") as f:
            f.write(out)
        invalidate_cache(path)
        if not quiet:
            print("wrote %s (repacked, %d bytes); backup at %s.bak"
                  % (path, len(out), self.path))
        return True


def invalidate_cache(bsp_path, quiet=False):
    """Drop the runtime-converted .scn for this map; it is gated on CACHE_VERSION, not source."""
    name = os.path.basename(bsp_path)
    if name.endswith(".bsp"):
        name = name[:-4]
    dropped = []
    for ext in (".scn", ".hash"):
        p = os.path.join(CACHE_DIR, name + ext)
        if os.path.exists(p):
            os.remove(p)
            dropped.append(os.path.basename(p))
    if dropped and not quiet:
        print("  invalidated cached %s" % ", ".join(dropped))
    return dropped
