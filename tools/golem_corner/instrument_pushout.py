#!/usr/bin/env python3
"""Add HOP_PUSHOUT_DBG tracing to hopbsp::hull_push_out, in place.

    tools/golem_corner/instrument_pushout.py extern/hop-godot/src/hop_bsp_traceable.h

With HOP_PUSHOUT_DBG set, every push-out query against a solid point prints its six axis
candidates and the answer it settled on, to stderr. It anchors on lines that are identical
on 007342f and on main, so ONE instrumentation measures both ends of the regression -- see
the next-measurement note in TODO.md. `git checkout -- src/` undoes it.
"""
import sys

HELPER = r'''
// --- HOP_PUSHOUT_DBG: temporary instrumentation, see tools/golem_corner/ ---
inline bool pushout_dbg() {
	// Re-read per call, not once at startup: a ride turns it on for the single tick under
	// the microscope (probe_golem_real's DBG_TICKS) and off again. Callers hoist it into a
	// local for the span of one query — the flag only changes between queries, and this is
	// a linear scan of environ.
	const char *v = std::getenv("HOP_PUSHOUT_DBG");
	return v != nullptr && v[0] == '1';
}
'''

# (anchor, where, text). where: "after" | "before".
EDITS = [
    ("#include <vector>", "after", "#include <cstdio>\n#include <cstdlib>"),
    ("inline bool hull_push_out(const hull &h, int root, const double p[3], int blocking,",
     "before", HELPER),
    ("""	if (in_solid) *in_solid = solid;
	if (!solid)
		return false;""", "after", r'''	const bool po_dbg = pushout_dbg();
	if (po_dbg) {
		std::fprintf(stderr, "[po] query p=(%.4f %.4f %.4f) extent=(%.3f %.3f %.3f)\n",
			p[0], p[1], p[2], extent[0], extent[1], extent[2]);
		if (prefer)
			std::fprintf(stderr, "[po]   prefer=(%.4f %.4f %.4f)\n",
				prefer[0], prefer[1], prefer[2]);
	}'''),
    ("		const double d = hull_inside_distance(h, root, p, dir, limit, blocking, &verified);",
     "after", r'''		if (po_dbg) {
			bool over = false;
			for (int oi = 0; oi < 3; ++oi) {
				const double omag = dir[oi] < 0 ? -dir[oi] : dir[oi];
				if (omag * d > extent[oi]) over = true;
			}
			std::fprintf(stderr,
				"[po]   cand dir=(%+.0f %+.0f %+.0f) limit=%.3f d=%.5f verified=%d"
				" over_extent=%d struck=%d\n",
				dir[0], dir[1], dir[2], limit, d, (int)verified, (int)over,
				(int)against_the_sweep(dir, d, prefer));
		}'''),
    ("		normal[0] = best_dir[0];", "before", r'''		if (po_dbg)
			std::fprintf(stderr, "[po] -> AXIS dir=(%+.0f %+.0f %+.0f) depth=%.5f\n",
				best_dir[0], best_dir[1], best_dir[2], best);'''),
    ("	double leaf_n[3], leaf_d = 0;", "before", r'''	if (po_dbg)
		std::fprintf(stderr, "[po]   no axis exit (found=%d), falling back to the leaf plane\n",
			(int)found);'''),
    ("	normal[0] = leaf_n[0]; normal[1] = leaf_n[1]; normal[2] = leaf_n[2];", "before",
     r'''	if (po_dbg)
		std::fprintf(stderr, "[po] -> LEAF n=(%+.3f %+.3f %+.3f) d=%.5f\n",
			leaf_n[0], leaf_n[1], leaf_n[2], leaf_d);'''),
    ("	if (!hull_nearest_leaf_plane(h, root, p, blocking, leaf_n, leaf_d))\n\t\treturn false;",
     "after", r'''	if (po_dbg)
		std::fprintf(stderr, "[po]   leaf candidate n=(%+.3f %+.3f %+.3f) d=%.5f slop=%.5f"
			" struck_by_prefer=%d\n", leaf_n[0], leaf_n[1], leaf_n[2], leaf_d, STUCK_SLOP,
			(int)against_the_sweep(leaf_n, leaf_d, prefer));'''),
]


def main() -> int:
    path = sys.argv[1]
    src = open(path).read()
    if "HOP_PUSHOUT_DBG" in src:
        print("already instrumented", file=sys.stderr)
        return 0
    for anchor, where, text in EDITS:
        n = src.count(anchor)
        if n != 1:
            print("anchor is not unique (%d): %r" % (n, anchor[:60]), file=sys.stderr)
            return 1
        ins = anchor + "\n" + text if where == "after" else text + "\n" + anchor
        src = src.replace(anchor, ins)
    open(path, "w").write(src)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
