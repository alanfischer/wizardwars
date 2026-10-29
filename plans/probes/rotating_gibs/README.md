# Probes for the three gib bugs

Evidence behind `plans/rotating_gibs.md`. Kept because the first round of this
investigation threw its harness away and the next person had to rebuild it.

Most build standalone against hop:

    c++ -std=c++17 -O2 -UNDEBUG \
        -I extern/hop-godot/extern/hop/include \
        -o /tmp/p plans/probes/rotating_gibs/<probe>.cpp

**Judge energy, never |w|.** A small body rolling legitimately spins fast (a 1 cm
sphere rolling at 0.7 m/s turns at 70 rad/s). The probes that predate this rule
(`probe_core`, `probe_sweep`, `probe_caps`, `probe_dt`, `probe_iters`,
`probe_reach`, `probe_gib_bsp`) report |w| and their verdicts are unreliable;
their numbers are still real.

| probe | what it shows |
|---|---|
| `probe_freespin.cpp` | **bug 1.** No gravity, no floor, no collision scope. Rotational energy must be conserved and is not — up to 65x. The whole root cause in one table. |
| `probe_at_rest.cpp` | **bug 2.** Bodies placed exactly at rest, v=0 w=0. Every box is clean; only capsules spin up. |
| `probe_trajectory.cpp` | **bug 3.** Frame-by-frame absolute state of a landing rod, with per-touch normals, levers, separations and accumulated impulses. Catches the single frame that injects +5.44 J. |
| `probe_ablate.cpp` | **bug 3.** Turns off restitution, friction, position/solver iterations, the angular cap and the speculative margin one at a time. None of them fixes it. |
| `probe_bsp_vs_box.cpp` | The BSP traceable is clean and box-vs-box is not. Needs hop-godot `src/` and `bsp_fixtures.h`. |
| `probe_trace.cpp` | The bug-2 mechanism: the contact witness flipping end to end under a resting capsule. |
| `probe_settle.cpp` | **Why they never settle**, which is a different question from energy. Sphere equivalence, the rolling lock, the sleep threshold, and the damp catch-22. Needs the extra include paths below. |

`probe_bsp_vs_box.cpp` and `probe_gib_bsp.cpp` need extra include paths, and
`bsp_fixtures.h` lives only on hop-godot's `bsp-oriented-capsule` branch:

    git -C extern/hop-godot show origin/bsp-oriented-capsule:tests/bsp_fixtures.h > /tmp/bsp_fixtures.h
    c++ -std=c++17 -O2 -UNDEBUG -I extern/hop-godot/extern/hop/include \
        -I extern/hop-godot/src -I /tmp -o /tmp/p plans/probes/rotating_gibs/probe_bsp_vs_box.cpp

`probe_bsp_vs_box.cpp` and `probe_ablate.cpp` respond to `-DHOP_PROBE_ENERGY_PROJECT`
if you build them against a hop copy carrying the bug-1 fix.

`persistent_manifold_prototype.patch` is **superseded**, along with hop's
`contact-support-set` branch. Both were built on generalising bug 2 to boxes,
which the measurements contradict. Kept because the failure is instructive.

The maintained reproduction now lives in hop itself as
`examples/demo_gib_spin.cpp` — headless, energy-judged, exits non-zero.
