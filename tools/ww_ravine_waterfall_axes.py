#!/usr/bin/env python3
"""Turn ww_ravine's sideways and upside-down waterfall faces around, so the water falls.

A func_conveyor scrolls along its face's texture S axis (see FuncConveyor), which is how the
map steers its rivers: the flat pools carry S along the flow, and the falls carry S straight
down. Five of ww_ravine's texinfo entries are rotated a quarter turn from that:

  texinfo 126  S=(0, 1, 0)  T=(0, 0,-1)   36 faces
  texinfo 127  S=(1, 0, 0)  T=(0, 0,-1)   53 faces
  texinfo 135  S=(0, 1, 0)  T=(0, 0,-1)   12 faces
  texinfo 136  S=(1, 0, 0)  T=(0, 0,-1)    9 faces
  texinfo 149  S=(1, 0, 0)  T=(0, 0,-1)   12 faces

Every one of their 122 faces is VERTICAL, and every one has a horizontal S — so the water runs
across them instead of down them. These are the stream sides facing the red and blue bases, and
they have looked wrong since the map shipped. The neighbouring correct faces use texinfo 150,
S=(0,0,-1) with T=(0,-1,0), which is exactly these entries with S and T exchanged.

So that is the whole edit: swap S and T (offsets included) on those five entries. Both vectors
already lie in the faces' planes, so the swap cannot skew anything that was not skewed before,
and it needs no new texinfo and no reindexing — the lump is rewritten at the same size, in
place. The resulting T on the ±X faces comes out mirrored against texinfo 150's convention,
which is invisible on a tiling texture that is scrolling anyway.

A sixth entry is upside down rather than sideways. texinfo 152 is S=(0,0,1) with T=(0,1,0) —
texinfo 150 negated — and it dresses the 15 -X faces of *19, the LOWER fall (z 32..1024), whose
+X side uses 150 and falls correctly. So the back of the lower fall ran its water upwards while
its front ran down. The upper fall (*18, z 1280..1928) never uses 152, which is why only the
lower one was wrong. Negating both of its vectors makes it identical to 150, offsets included.

Every face using these six entries is a conveyor face and no other geometry shares them, so
nothing outside ww_ravine's water can be touched.

One caveat, deliberate: these faces are lit, and swapping the axes swaps their lightmap extents,
which leaves the baked lightmap block laid out for the old orientation. It goes unused — a
conveyor's material is rebuilt unshaded at runtime (EntityRender.convert_shader_to_standard keeps
only the albedo), so the lightmap is never sampled on these surfaces. If conveyors are ever
given their lighting back, these blocks need transposing.

The runtime map cache keys off map_converter.CACHE_VERSION rather than the BSP's contents,
so bsp.save_in_place drops the cached .scn for us; otherwise the stale scene silently wins.

Usage:
  ww_ravine_waterfall_axes.py <bsp> [--dry]
"""
import sys

from bsp import Bsp

# The rotated entries, with the axes they ship with, so a map that is not the one this was
# written for cannot be quietly rewritten.
EXPECTED = {
    126: ((0.0, 1.0, 0.0), (0.0, 0.0, -1.0)),
    127: ((1.0, 0.0, 0.0), (0.0, 0.0, -1.0)),
    135: ((0.0, 1.0, 0.0), (0.0, 0.0, -1.0)),
    136: ((1.0, 0.0, 0.0), (0.0, 0.0, -1.0)),
    149: ((1.0, 0.0, 0.0), (0.0, 0.0, -1.0)),
}
# Upside down rather than a quarter turn: texinfo 150 with both vectors negated.
EXPECTED_FLIPPED = {
    152: ((0.0, 0.0, 1.0), (0.0, 1.0, 0.0)),
}
WANTED_S = (0.0, 0.0, -1.0)  # down, matching texinfo 150 on the faces that already look right


def patch(path, dry=False):
    b = Bsp(path)
    texinfo = b.texinfo  # rows are [sx sy sz soff, tx ty tz toff, miptex, flags]

    changed = 0
    for ti, (want_s, want_t) in sorted(EXPECTED.items()):
        if ti >= len(texinfo):
            print("texinfo %d is past the end of the lump — wrong map?" % ti)
            return 1
        row = texinfo[ti]
        s, t = row[0:4], row[4:8]

        if tuple(round(v, 3) for v in s[:3]) == WANTED_S:
            print("texinfo %d: already upright" % ti)
            continue
        if (tuple(round(v, 3) for v in s[:3]) != want_s
                or tuple(round(v, 3) for v in t[:3]) != want_t):
            print("texinfo %d: axes are S=%s T=%s, expected S=%s T=%s -- refusing to guess"
                  % (ti, s[:3], t[:3], want_s, want_t))
            return 1

        # Swap, offsets and all: T already points down, S is the horizontal that should be T.
        row[0:4], row[4:8] = t, s
        print("texinfo %d: S %s -> %s (water now falls)" % (ti, want_s, want_t))
        changed += 1

    for ti, (want_s, want_t) in sorted(EXPECTED_FLIPPED.items()):
        if ti >= len(texinfo):
            print("texinfo %d is past the end of the lump — wrong map?" % ti)
            return 1
        row = texinfo[ti]
        s, t = row[0:4], row[4:8]

        if tuple(round(v, 3) for v in s[:3]) == WANTED_S:
            print("texinfo %d: already falling" % ti)
            continue
        if (tuple(round(v, 3) for v in s[:3]) != want_s
                or tuple(round(v, 3) for v in t[:3]) != want_t):
            print("texinfo %d: axes are S=%s T=%s, expected S=%s T=%s -- refusing to guess"
                  % (ti, s[:3], t[:3], want_s, want_t))
            return 1

        # Negate both, which lands exactly on texinfo 150 and keeps the handedness.
        row[0:4] = [-s[0], -s[1], -s[2], s[3]]
        row[4:8] = [-t[0], -t[1], -t[2], t[3]]
        print("texinfo %d: S %s -> %s (was flowing UP)"
              % (ti, want_s, tuple(-v for v in want_s)))
        changed += 1

    if changed == 0:
        print("nothing to do")
        return 0
    if dry:
        print("--- (dry run, not written) ---")
        return 0

    b.save_in_place(quiet=True)
    print("wrote %s (%d texinfo entries, same size)" % (path, changed))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    sys.exit(patch(sys.argv[1], dry="--dry" in sys.argv))
