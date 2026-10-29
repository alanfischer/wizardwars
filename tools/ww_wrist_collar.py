#!/usr/bin/env python3
"""Stop the hand view models folding through themselves at the wrist.

The ray poses (`icerayshoot`, `liferayshoot`, and the poke/updraft ones beside them) roll the
wrist ~95 degrees, and 91% of that rotation is twist about the forearm's own axis. On a rigid
GoldSrc skin that twist lands entirely on the one band of triangles bridging `Bip01 ? Arm2` to
`Bip01 ? Hand` -- a collar barely 0.9 units long joining two flat ovals. Twisted 95 degrees, the
oval's long corners sweep outside the forearm's and the collar passes through itself: the
folded triangles you see around the wrist whenever a beam is up.

The fix is the anatomy. Forearm pronation belongs to the forearm, not to a one-ring collar at
its end, so the collar is rebound from the forearm bone to the hand bone. The hand and its
collar then turn as one rigid piece and the twist is spread over the 5+ units of forearm below
it, which has room for it. Nothing moves in the rest pose -- `Mdl.rebind` re-expresses each
vertex in the hand's frame -- so the model looks identical in every pose that was already fine.

Models whose forearm mesh reaches PAST the wrist joint have a sleeve covering the seam and are
left alone: the sleeve already hides the twist, and they measure clean. That is what the
`t < 0` guard in `collar_ring` is for, and it is why this only touches ice/life/fire/lightning/
wind, not the archmage/death/earth/nature family.

Usage:
  ww_wrist_collar.py report [mdl...]        # fold counts per sequence, no writes
  ww_wrist_collar.py patch  [mdl...] [--dry]

With no paths given, both act on models/hands/*.mdl. `patch` measures before and after and
refuses to write if any sequence came out worse.
"""
import glob
import os
import sys

from mdl import Mdl, xform

# How far back from the wrist joint a forearm vertex can sit and still count as the collar's
# last ring. The rings in these models are ~0.3 thick and ~0.9 from the joint.
RING_DEPTH = 0.6
# A forearm whose last vertex sits further than this behind the wrist joint has already had
# its collar rebound; what is left is mid-arm and must not be dragged onto the hand.
MAX_COLLAR_DEPTH = 2.0
# Triangle pairs further apart than this (model units) cannot touch; skips the O(n^2) test.
NEAR = 6.0


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _norm(a):
    return _dot(a, a) ** 0.5


def tris_intersect(t1, t2):
    """Moller's interval overlap test. Coplanar pairs read as non-intersecting, which is what
    we want here -- a shared seam edge is not a fold."""
    def plane(t):
        n = _cross(_sub(t[1], t[0]), _sub(t[2], t[0]))
        return n, -_dot(n, t[0])

    n1, d1 = plane(t1)
    n2, d2 = plane(t2)
    if _norm(n1) < 1e-12 or _norm(n2) < 1e-12:
        return False
    dv = [_dot(n1, v) + d1 for v in t2]
    if all(x > 1e-6 for x in dv) or all(x < -1e-6 for x in dv):
        return False
    du = [_dot(n2, v) + d2 for v in t1]
    if all(x > 1e-6 for x in du) or all(x < -1e-6 for x in du):
        return False
    axis = max(range(3), key=lambda i: abs(_cross(n1, n2)[i]))

    def span(t, d):
        pv = [v[axis] for v in t]
        out = []
        for i in range(3):
            j = (i + 1) % 3
            if d[i] * d[j] < 0:
                out.append(pv[i] + (pv[j] - pv[i]) * (d[i] / (d[i] - d[j])))
            if abs(d[i]) < 1e-9:
                out.append(pv[i])
        return (min(out), max(out)) if len(out) >= 2 else None

    a = span(t1, du)
    b = span(t2, dv)
    if not a or not b:
        return False
    return a[0] <= b[1] - 1e-7 and b[0] <= a[1] - 1e-7


def bone_index(m, name):
    for b in m.bones:
        if b["name"] == name:
            return b["index"]
    return None


def collar_ring(m, sm, side, world=None):
    """The forearm's last vertex ring before the wrist.

    Returns {"hand", "arm", "ring"} for a rebindable collar, or {"skip": why} otherwise. Two
    things disqualify a ring, and both have to: a forearm reaching PAST the joint is a sleeve
    covering the seam, which needs no help and must not be pulled onto the hand; and a forearm
    ending well short of the joint has already been rebound, so the ring on offer is mid-arm.
    The second is what makes a second run of this tool a no-op instead of a disaster.
    """
    hand = bone_index(m, "Bip01 %s Hand" % side)
    arm = bone_index(m, "Bip01 %s Arm2" % side)
    if hand is None or arm is None:
        return {"skip": "no arm"}
    world = world or m.rest_world()
    axis = _sub(world[hand][1], world[arm][1])
    length = _norm(axis)
    if length < 1e-6:
        return {"skip": "degenerate forearm"}
    axis = tuple(c / length for c in axis)

    vbone = m.vert_bone(sm)
    verts = m.verts(sm)
    depths = {}
    for i, vb in enumerate(vbone):
        if vb == arm:
            depths[i] = _dot(_sub(xform(world[arm], verts[i]), world[hand][1]), axis)
    if not depths:
        return {"skip": "no forearm vertices"}
    top = max(depths.values())
    if top >= 0.0:
        return {"skip": "sleeve covers the joint"}
    if top < -MAX_COLLAR_DEPTH:
        return {"skip": "forearm ends %.1f short of the wrist, already rebound" % -top}
    ring = sorted(i for i, t in depths.items() if t >= top - RING_DEPTH)
    return {"hand": hand, "arm": arm, "ring": ring}


def wrist_tris(m, sm, bones):
    out = []
    vbone = m.vert_bone(sm)
    for mesh in m.meshes(sm):
        for tri in m.tris(mesh):
            idx = tuple(c[0] for c in tri)
            if all(vbone[v] in bones for v in idx):
                out.append(idx)
    return out


def fold_counts(m, sm, tris, samples=7):
    """Worst self-intersecting triangle-pair count per sequence, over sampled frames."""
    verts = m.verts(sm)
    vbone = m.vert_bone(sm)
    used = sorted({v for t in tris for v in t})
    out = {}
    for seq in m.sequences():
        if seq["seqgroup"] != 0 or seq["numframes"] < 1:
            continue
        pos, rot = m.frames(seq)
        n = seq["numframes"]
        frames = sorted({round(k * (n - 1) / max(samples - 1, 1)) for k in range(samples)})
        worst = 0
        for f in frames:
            world = m.bone_world(pos[f], rot[f])
            p = {v: xform(world[vbone[v]], verts[v]) for v in used}
            count = 0
            for a in range(len(tris)):
                ta = tris[a]
                ca = tuple(sum(p[v][k] for v in ta) / 3 for k in range(3))
                for b in range(a + 1, len(tris)):
                    tb = tris[b]
                    if set(ta) & set(tb):
                        continue
                    cb = tuple(sum(p[v][k] for v in tb) / 3 for k in range(3))
                    if _norm(_sub(ca, cb)) > NEAR:
                        continue
                    if tris_intersect([p[v] for v in ta], [p[v] for v in tb]):
                        count += 1
            worst = max(worst, count)
        out[seq["label"]] = worst
    return out


def arm_region(m, side):
    return {b for b in (bone_index(m, "Bip01 %s Hand" % side),
                        bone_index(m, "Bip01 %s Arm2" % side),
                        bone_index(m, "Bip01 %s Arm1" % side)) if b is not None}


def measure(m, sm, side):
    return fold_counts(m, sm, wrist_tris(m, sm, arm_region(m, side)))


def report(paths):
    for path in paths:
        m = Mdl(path)
        sm = m.bodyparts[0]["models"][0]
        print(os.path.basename(path))
        for side in ("L", "R"):
            collar = collar_ring(m, sm, side)
            counts = measure(m, sm, side)
            folds = {k: v for k, v in sorted(counts.items(), key=lambda kv: -kv[1]) if v}
            print("  %s collar=%s folds=%s" % (
                side,
                collar["ring"] if "ring" in collar else collar["skip"],
                folds or "none"))


def patch(paths, dry=False):
    changed = 0
    for path in paths:
        m = Mdl(path)
        sm = m.bodyparts[0]["models"][0]
        name = os.path.basename(path)
        plan = []
        skips = []
        for side in ("L", "R"):
            collar = collar_ring(m, sm, side)
            if collar.get("ring"):
                plan.append((side, collar))
            else:
                skips.append("%s: %s" % (side, collar["skip"]))
        if not plan:
            print("%-16s skipped (%s)" % (name, "; ".join(skips)))
            continue

        before = {side: measure(m, sm, side) for side, _ in plan}
        world = m.rest_world()
        rest_before = [xform(world[b], v) for b, v in zip(m.vert_bone(sm), m.verts(sm))]
        moved_norms = 0
        for _side, collar in plan:
            moved_norms += len(m.rebind(sm, collar["ring"], collar["hand"], world=world))

        world_after = m.rest_world()
        rest_after = [xform(world_after[b], v) for b, v in zip(m.vert_bone(sm), m.verts(sm))]
        drift = max(_norm(_sub(a, b)) for a, b in zip(rest_before, rest_after))
        after = {side: measure(m, sm, side) for side, _ in plan}

        worse = [(side, k) for side in after for k in after[side]
                 if after[side][k] > before[side][k]]
        if worse or drift > 1e-3:
            print("%-16s REFUSED (rest drift %.5f, regressions %s)" % (name, drift, worse))
            continue

        moved = sum(len(collar["ring"]) for _side, collar in plan)
        gains = {("%s/%s" % (side, k)): (before[side][k], after[side][k])
                 for side in after for k in after[side] if after[side][k] < before[side][k]}
        print("%-16s %d verts + %d normals -> hand bone, rest drift %.5f" % (
            name, moved, moved_norms, drift))
        for k, (b, a) in sorted(gains.items()):
            print("    %-28s %2d -> %2d folds" % (k, b, a))
        if not dry:
            m.save()
            changed += 1
    if dry:
        print("\n(dry run, nothing written)")
    else:
        print("\n%d model(s) rewritten" % changed)


def main(argv):
    if len(argv) < 2 or argv[1] not in ("report", "patch"):
        print(__doc__)
        return 1
    dry = "--dry" in argv
    paths = [a for a in argv[2:] if not a.startswith("--")]
    if not paths:
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir)
        paths = sorted(glob.glob(os.path.join(root, "models", "hands", "*.mdl")))
    if argv[1] == "report":
        report(paths)
    else:
        patch(paths, dry)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
