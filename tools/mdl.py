#!/usr/bin/env python3
"""Shared GoldSrc MDL (IDST v10) access for the tools in this directory.

Like the .bsp maps, the view models under `models/` are shipped binaries we edit in place:
studiomdl is a Windows tool and the .qc/.smd sources live outside the repo, so a fix has to
be byte surgery on the compiled file. Everything here is therefore offset-preserving --
vertices, normals and their bone assignments are rewritten where they already sit, never
resized -- which keeps every other offset in the header valid. The one exception is `write()`,
which builds a static model from nothing (tools/model_art.py's replacements).

A GoldSrc skin is rigid: one bone per vertex, no weights. Vertex and normal coordinates are
stored in that bone's local space, relative to the bone's DEFAULT pose (`bone.value[]`), not
to any animation frame -- so rebinding a vertex to another bone means re-expressing its
position in the new bone's rest frame if the rest pose is to come out unchanged. `rebind()`
does both halves together for exactly that reason.
"""
import math
import struct

MAGIC = 0x54534449  # "IDST"
VERSION = 10

_BONE_SIZE = 112
_SEQ_SIZE = 176
_MODEL_SIZE = 112
_MESH_SIZE = 20
_HITBOX_SIZE = 32


def _mat_from_euler(x, y, z):
    """GoldSrc XYZ euler -> 3x3 rotation, matching the HL SDK's AngleQuaternion."""
    cx, sx = math.cos(x * 0.5), math.sin(x * 0.5)
    cy, sy = math.cos(y * 0.5), math.sin(y * 0.5)
    cz, sz = math.cos(z * 0.5), math.sin(z * 0.5)
    qx = sx * cy * cz - cx * sy * sz
    qy = cx * sy * cz + sx * cy * sz
    qz = cx * cy * sz - sx * sy * cz
    qw = cx * cy * cz + sx * sy * sz
    return (
        (1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw)),
        (2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw)),
        (2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)),
    )


def mat_mul(a, b):
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))


def mat_vec(a, v):
    return tuple(sum(a[i][k] * v[k] for k in range(3)) for i in range(3))


def mat_tvec(a, v):
    """Transpose (= inverse, these are pure rotations) times vector."""
    return tuple(sum(a[k][i] * v[k] for k in range(3)) for i in range(3))


def xform(tf, v):
    m = mat_vec(tf[0], v)
    return (m[0] + tf[1][0], m[1] + tf[1][1], m[2] + tf[1][2])


class Mdl:
    def __init__(self, path, data=None):
        self.path = path
        self.data = bytearray(data if data is not None else open(path, "rb").read())
        magic, version = struct.unpack_from("<ii", self.data, 0)
        if magic != MAGIC or version != VERSION:
            raise ValueError("%s is not a GoldSrc MDL v10" % path)
        off = 76  # id, version, name[64], length
        off += 4 * 15  # eyeposition + min/max + bbmin/bbmax
        (self.flags, self.numbones, self.boneindex, self.numbonecontrollers,
         self.bonecontrollerindex, self.numhitboxes, self.hitboxindex, self.numseq,
         self.seqindex) = struct.unpack_from("<9i", self.data, off)
        off += 36
        off += 8  # seqgroups
        self.numtextures, self.textureindex = struct.unpack_from("<ii", self.data, off)
        off += 12  # textures
        off += 12  # skins
        self.numbodyparts, self.bodypartindex = struct.unpack_from("<ii", self.data, off)
        self.bones = self._read_bones()
        self.bodyparts = self._read_bodyparts()

    # -- reading ----------------------------------------------------------------

    def _read_bones(self):
        out = []
        for i in range(self.numbones):
            o = self.boneindex + i * _BONE_SIZE
            name = self.data[o:o + 32].split(b"\0")[0].decode("latin1")
            parent = struct.unpack_from("<i", self.data, o + 32)[0]
            value = struct.unpack_from("<6f", self.data, o + 64)
            out.append({"index": i, "name": name, "parent": parent, "value": value})
        return out

    def _read_bodyparts(self):
        out = []
        for i in range(self.numbodyparts):
            o = self.bodypartindex + i * 76
            name = self.data[o:o + 64].split(b"\0")[0].decode("latin1")
            nummodels, _base, modelindex = struct.unpack_from("<iii", self.data, o + 64)
            models = []
            for mi in range(nummodels):
                mo = modelindex + mi * _MODEL_SIZE
                sm = {"name": self.data[mo:mo + 64].split(b"\0")[0].decode("latin1")}
                (sm["nummesh"], sm["meshindex"], sm["numverts"], sm["vertinfoindex"],
                 sm["vertindex"], sm["numnorms"], sm["norminfoindex"],
                 sm["normindex"]) = struct.unpack_from("<8i", self.data, mo + 72)
                models.append(sm)
            out.append({"name": name, "models": models})
        return out

    def hitboxes(self):
        """The hit boxes, in file order. `group` is the HL hit group the engine reports as
        TraceResult.iHitgroup; 0 is HITGROUP_GENERIC, 1 is HITGROUP_HEAD."""
        out = []
        for i in range(self.numhitboxes):
            o = self.hitboxindex + i * _HITBOX_SIZE
            bone, group = struct.unpack_from("<ii", self.data, o)
            out.append({"index": i, "bone": bone, "group": group,
                        "bone_name": self.bones[bone]["name"] if 0 <= bone < self.numbones else "?"})
        return out

    def textures(self):
        """Each skin as (name, flags, width, height, rgb bytes)."""
        out = []
        for i in range(self.numtextures):
            o = self.textureindex + i * 80
            name = self.data[o:o + 64].split(b"\0")[0].decode("latin1")
            flags, w, h, index = struct.unpack_from("<4i", self.data, o + 64)
            pixels = self.data[index:index + w * h]
            pal = self.data[index + w * h:index + w * h + 768]
            out.append((name, flags, w, h, b"".join(pal[p * 3:p * 3 + 3] for p in pixels)))
        return out

    def vert_bone(self, sm):
        return list(self.data[sm["vertinfoindex"]:sm["vertinfoindex"] + sm["numverts"]])

    def norm_bone(self, sm):
        return list(self.data[sm["norminfoindex"]:sm["norminfoindex"] + sm["numnorms"]])

    def verts(self, sm):
        return [struct.unpack_from("<3f", self.data, sm["vertindex"] + i * 12)
                for i in range(sm["numverts"])]

    def norms(self, sm):
        return [struct.unpack_from("<3f", self.data, sm["normindex"] + i * 12)
                for i in range(sm["numnorms"])]

    def meshes(self, sm):
        out = []
        for i in range(sm["nummesh"]):
            o = sm["meshindex"] + i * _MESH_SIZE
            numtris, triindex, skinref = struct.unpack_from("<iii", self.data, o)
            out.append({"numtris": numtris, "triindex": triindex, "skinref": skinref})
        return out

    def tris(self, mesh):
        """Expand a mesh's strips and fans into (vi, ni, s, t) triples, three per triangle."""
        o = mesh["triindex"]
        out = []
        while True:
            cmd = struct.unpack_from("<h", self.data, o)[0]
            o += 2
            if cmd == 0:
                break
            fan = cmd < 0
            n = abs(cmd)
            run = []
            for _ in range(n):
                run.append(struct.unpack_from("<4h", self.data, o))
                o += 8
            for v in range(2, n):
                if fan:
                    out.append((run[0], run[v - 1], run[v]))
                elif v % 2 == 0:
                    out.append((run[v - 2], run[v - 1], run[v]))
                else:
                    out.append((run[v - 1], run[v - 2], run[v]))
        return out

    # -- poses ------------------------------------------------------------------

    def bone_world(self, pos, rot):
        """Model-space transform per bone for one frame, walking the hierarchy."""
        world = [None] * self.numbones
        for b in self.bones:
            local = (_mat_from_euler(*rot[b["index"]]), tuple(pos[b["index"]]))
            if b["parent"] < 0:
                world[b["index"]] = local
            else:
                p = world[b["parent"]]
                world[b["index"]] = (mat_mul(p[0], local[0]), xform(p, local[1]))
        return world

    def rest_world(self):
        return self.bone_world([b["value"][:3] for b in self.bones],
                               [b["value"][3:] for b in self.bones])

    def sequences(self):
        out = []
        for i in range(self.numseq):
            o = self.seqindex + i * _SEQ_SIZE
            label = self.data[o:o + 32].split(b"\0")[0].decode("latin1")
            numframes = struct.unpack_from("<i", self.data, o + 56)[0]
            numblends, animindex = struct.unpack_from("<ii", self.data, o + 120)
            seqgroup = struct.unpack_from("<i", self.data, o + 156)[0]
            out.append({"index": i, "label": label, "numframes": numframes,
                        "numblends": numblends, "animindex": animindex, "seqgroup": seqgroup})
        return out

    def frames(self, seq):
        """Decode one sequence's blend-0 animation into per-frame (pos, rot) per bone.

        Channels are RLE'd int16 deltas scaled by bone.scale and added to bone.value; a
        channel with offset 0 holds the rest value for the whole sequence.
        """
        n = seq["numframes"]
        pos = [[[0.0] * 3 for _ in range(self.numbones)] for _ in range(n)]
        rot = [[[0.0] * 3 for _ in range(self.numbones)] for _ in range(n)]
        for b in range(self.numbones):
            o = self.boneindex + b * _BONE_SIZE
            base = struct.unpack_from("<6f", self.data, o + 64)
            scale = struct.unpack_from("<6f", self.data, o + 88)
            anim = seq["animindex"] + b * 12
            offsets = struct.unpack_from("<6H", self.data, anim)
            for ch in range(6):
                dst, idx = (pos, ch) if ch < 3 else (rot, ch - 3)
                if offsets[ch] == 0:
                    for f in range(n):
                        dst[f][b][idx] = base[ch]
                    continue
                p = anim + offsets[ch]
                frame = 0
                while frame < n:
                    valid, total = self.data[p], self.data[p + 1]
                    p += 2
                    if total == 0:
                        break
                    for k in range(total):
                        if frame >= n:
                            break
                        if valid == 0:
                            dst[frame][b][idx] = base[ch]
                        else:
                            at = k if k < valid else valid - 1
                            raw = struct.unpack_from("<h", self.data, p + at * 2)[0]
                            dst[frame][b][idx] = base[ch] + raw * scale[ch]
                        frame += 1
                    p += valid * 2
        return pos, rot

    # -- writing ----------------------------------------------------------------

    def rebind(self, sm, vert_indices, new_bone, world=None):
        """Move vertices (and the normals they own) to another bone, rest pose unchanged.

        Returns the normal indices that moved. Raises if a normal is shared with a vertex
        that is staying put, since such a normal cannot follow both bones.
        """
        world = world or self.rest_world()
        moving = set(vert_indices)
        owned = {}
        for mesh in self.meshes(sm):
            for tri in self.tris(mesh):
                for vi, ni, _s, _t in tri:
                    owned.setdefault(ni, set()).add(vi)
        norm_indices = set()
        for ni, verts in owned.items():
            if verts & moving:
                if verts - moving:
                    raise ValueError("normal %d is shared with vertices outside the set" % ni)
                norm_indices.add(ni)

        vbone = self.vert_bone(sm)
        nbone = self.norm_bone(sm)
        verts = self.verts(sm)
        norms = self.norms(sm)
        dst = world[new_bone]
        for vi in sorted(moving):
            model = xform(world[vbone[vi]], verts[vi])
            rel = (model[0] - dst[1][0], model[1] - dst[1][1], model[2] - dst[1][2])
            struct.pack_into("<3f", self.data, sm["vertindex"] + vi * 12, *mat_tvec(dst[0], rel))
            self.data[sm["vertinfoindex"] + vi] = new_bone
        for ni in sorted(norm_indices):
            model = mat_vec(world[nbone[ni]][0], norms[ni])
            struct.pack_into("<3f", self.data, sm["normindex"] + ni * 12, *mat_tvec(dst[0], model))
            self.data[sm["norminfoindex"] + ni] = new_bone
        return sorted(norm_indices)

    def set_hitbox_group(self, index, group):
        """Retag one hit box. Four bytes in place -- no offset in the file moves."""
        struct.pack_into("<i", self.data, self.hitboxindex + index * _HITBOX_SIZE + 4, group)

    def save(self, path=None):
        open(path or self.path, "wb").write(bytes(self.data))


def write(path, name, textures, submodels):
    """Build a static model from nothing: one bone at the origin, one bodypart whose submodels
    are alternatives (a gib model's debris shapes), a single-frame idle.

    `textures` are (name, flags, width, height, pixels, palette): 8-bit indices and 768 bytes
    of RGB. A submodel is (name, verts, norms, skinref, tris), each triangle three
    (vi, ni, s, t) corners in texel units, wound as GoldSrc winds them -- against the normal.
    """
    lo = [min(v[i] for sm in submodels for v in sm[1]) for i in range(3)]
    hi = [max(v[i] for sm in submodels for v in sm[1]) for i in range(3)]
    out = bytearray(244)

    def here():
        return len(out)

    def pad():
        out.extend(b"\0" * (-len(out) % 4))

    def label(text, size):
        return text.encode("latin1")[:size - 1].ljust(size, b"\0")

    bone = here()
    out += label("root", 32) + struct.pack("<ii6i6f6f", -1, 0, *[-1] * 6, *[0.0] * 6,
                                           *[1 / 32.0] * 3, *[math.pi / 32768] * 3)
    hitbox = here()
    out += struct.pack("<ii6f", 0, 0, *lo, *hi)
    seq = here()
    out += bytearray(_SEQ_SIZE)
    seqgroup = here()
    out += label("default", 32) + bytearray(64 + 8)
    anim = here()
    out += bytearray(12)  # every channel offset 0: the bone holds its rest value
    seq_fields = label("idle", 32) + struct.pack("<f9i", 30.0, 0, 0, 0, 0, 0, 1, 0, 0, 0)
    seq_fields += struct.pack("<i3fii6fii", 0, 0, 0, 0, 0, 0, *lo, *hi, 1, anim)
    out[seq:seq + len(seq_fields)] = seq_fields

    texindex = here()
    out += bytearray(80 * len(textures))
    skin = here()
    out += b"".join(struct.pack("<h", i) for i in range(len(textures)))
    pad()
    bodypart = here()
    out += label("gibs", 64) + struct.pack("<iii", len(submodels), 1, bodypart + 76)
    models = here()
    out += bytearray(_MODEL_SIZE * len(submodels))
    for i, (sm_name, verts, norms, skinref, tris) in enumerate(submodels):
        vertinfo = here()
        out += bytearray(len(verts))
        pad()
        norminfo = here()
        out += bytearray(len(norms))
        pad()
        vertindex = here()
        out += b"".join(struct.pack("<3f", *v) for v in verts)
        normindex = here()
        out += b"".join(struct.pack("<3f", *n) for n in norms)
        triindex = here()
        for tri in tris:
            out += struct.pack("<h", 3) + b"".join(struct.pack("<4h", *c) for c in tri)
        out += struct.pack("<h", 0)
        pad()
        mesh = here()
        out += struct.pack("<5i", len(tris), triindex, skinref, len(norms), 0)
        radius = max(math.sqrt(sum(c * c for c in v)) for v in verts)
        struct.pack_into("<64sif10i", out, models + i * _MODEL_SIZE, label(sm_name, 64), 0, radius,
                         1, mesh, len(verts), vertinfo, vertindex, len(norms), norminfo,
                         normindex, 0, 0)
    for i, (tex_name, flags, w, h, pixels, palette) in enumerate(textures):
        struct.pack_into("<64s4i", out, texindex + i * 80, label(tex_name, 64), flags, w, h, here())
        out += bytes(pixels) + bytes(palette)
    pad()

    struct.pack_into("<ii64si", out, 0, MAGIC, VERSION, label(name, 64), len(out))
    struct.pack_into("<15fi", out, 76, *[0.0] * 9, *lo, *hi, 0)
    struct.pack_into("<26i", out, 140, 1, bone, 0, bone, 1, hitbox, 1, seq, 1, seqgroup,
                     len(textures), texindex, texindex, len(textures), 1, skin, 1, bodypart,
                     0, 0, 0, 0, 0, 0, 0, 0)
    open(path, "wb").write(bytes(out))
