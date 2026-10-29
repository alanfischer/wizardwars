# Giving the BSP trace a shape and an attitude

> **Status: not started.** Everything below is analysis, and the measurements it
> quotes are already done — see `plans/rotating_gibs.md` and
> `plans/probes/rotating_gibs/probe_settle.cpp`. Do not re-derive them.

## The problem, precisely

`HopBspTraceable::trace_solid` reads exactly one thing off a mover: its **local
axis-aligned bound** (`s->get_local_bound()`, `hop_bsp_traceable.h:1047`). The mover's
shape and its orientation never reach the trace. The contact witness it reports
(`result.impact`) is then placed straight **down the normal** from the body centre.

Two consequences, both measured:

- **A body is a sphere.** A sphere handed the box's inertia reproduces the box's
  trajectory to every printed digit. Shape reaches the solver *only* through the
  inertia tensor.
- **There is no rest attitude.** A gib dropped flat, on end, on edge and on a corner
  all settle at the same height, because resting height is half the body-frame Y
  extent whatever the body is doing. A real box on end rests five times higher.

So "lying on a face" is not a state the solver can distinguish, let alone prefer.

## See it first

`hop/examples/demo_gib_floor.cpp` (alanfischer/hop#84) is this bug on screen. Toggle
the floor between an `aa_box` and a BSP hull, throw gibs at it, and press `G` to draw
the axis-aligned box the trace actually reads alongside the shape the gib really is.

    cmake -S . -B build -DHOP_BUILD_EXAMPLES=ON
    cmake --build build --target demo_gib_floor && ./build/demo_gib_floor

`--selftest` runs it headless and prints one box dropped from four attitudes on both
floors. Against the hull all four rest at the same height and none of them falls over:

| dropped | BSP rest y | BSP tilt | box rest y | box tilt |
|---|---|---|---|---|
| flat | 0.0138 | 0 | 0.0210 | 0 |
| on end (Z by 90) | 0.0138 | **90** | 0.0097 | 1 |
| on edge (X by 90) | 0.0138 | **90** | 0.0093 | 9 |
| corner (X by 45) | 0.0138 | **45** | 0.0071 | 7 |

The `tilt` column is the sharpest single signal this project has: on the BSP floor a
box comes to rest still standing on its end. That is the acceptance test below, already
wired up — when the trace learns about orientation, those tilts collapse toward 0 and
the heights stop being one number four times.

(The `aa_box` column is orientation-aware, which is the point of the comparison, but its
absolute values are not ground truth — that is bug 3 bedding a thin box in too deep.)

## Decide this first, before writing any code

**Log-rolling is not physical for a box.** A 12 x 2.4 x 7 cm bone pushed along a floor
tumbles over its edges; it does not roll like a cylinder. The old `gib_body.gd` faked a
cylinder, and that is the look people remember.

Fixing this trace gives you a box that **tips onto a face and stops**. It does not give
you log-rolling, and no amount of work here will. If the log-roll is the look you want,
that is a cosmetic decision to re-add on purpose — cheap, and independent of everything
below. Decide which you are actually chasing, because only one of them is this project.

## Why this is more tractable than `rotating_gibs.md` implies

That doc says an oriented shape "is not expressible" because a clipnode hull is a
precomputed Minkowski expansion for one fixed box. That is true **only of the sized
hulls**, and gibs do not use them.

`hull_for_size` (`hop_bsp_traceable.h:84`) sends anything under 32 GoldSrc units to
**hull 0**, the real node tree, and inflates it by the mover's own box at trace time. A
12 cm gib is 4.8 GoldSrc units. **Every gib is hull 0.** On that path the expansion is
live, so it can be made orientation-aware exactly.

The hook is one function:

```cpp
inline double plane_offset(const hop_bsp::BSPPlane &pl, const double half[3]) {
	if (pl.type < 3) return half[pl.type];          // axial fast path
	return |nx|*half[0] + |ny|*half[1] + |nz|*half[2];
}
```

That is the support function of an **axis-aligned** box along the plane normal. The
oriented form is the same shape of expression and just as cheap:

    support = |n·ax|*hx + |n·ay|*hy + |n·az|*hz

with `ax/ay/az` the box's own axes in the traceable's frame. Exact for an OBB, three
dot products instead of three `abs`. This is the whole geometric content of the change.

## What has to change

1. **`plane_offset` takes the mover's rotation**, per above. Precompute the rotated
   axes once per trace, not per plane.
2. **The axial fast path must go** for rotated movers — `pl.type < 3` reads one extent
   directly, which is only valid when the box is axis-aligned. Keep it for the
   unrotated case; it is the overwhelming majority of planes and of movers.
3. **The witness point has to move.** This is the part that actually changes behaviour,
   and the part to be most careful with. Today `result.impact` walks back down the
   normal by the box's reach, which makes the lever arm exactly antiparallel to the
   normal (measured: `lever·n = -1.0000`). That is deliberate — it is what hop-godot#43
   fixed, because taking the box's **corner** made the support impulse a torque and
   spun a flat-dropped box to 37 rad/s. An oriented trace has to produce the real
   contact **feature** (face / edge / vertex), not a corner and not a centre.
4. **Gate it on hull 0 and on a rotating body.** Sized hulls genuinely cannot express
   it, and their movers — players, monsters — do not rotate. `inv_inertia == 0` is
   already hop's marker for "never spins".

## What this will not fix, and what it will break

- **It walks straight into bug 3.** A thin box *landing* under speculative contacts on
  a non-BSP static box gains five orders of magnitude, undiagnosed. The BSP path is
  clean today **because it is blind** — give it real shape and it joins the bad path.
  Bug 3 should be diagnosed **before** this, not after.
- **hop-godot#46** (`bsp-oriented-capsule`, 2 commits, +966/-228) already attempted the
  oriented expansion and is quarantined DO NOT MERGE. Its original accusation — that it
  caused the runaway — was disproved. Read it before starting; it is a real head start,
  and its `tests/bsp_fixtures.h` is what every probe in this investigation builds on.
- **Sized hulls stay blind.** Fine, but it means the trace has two behaviours and the
  tests need to cover both.

## Order of work

1. **Diagnose bug 3 first.** It is the actual blocker, and doing this project ahead of
   it means debugging two unknowns at once.
2. Revive hop-godot#46, rebased, gated to hull 0 + `rotates_dynamically()`.
3. Fix the witness point to report a real contact feature.
4. Then reconsider the gib damping: `ANGULAR_DAMP = 3.0` in `gib_effect.gd` is
   currently covering for the contact model. If the floor starts taking the energy
   honestly, that number should come down.

## Acceptance

- A box dropped on end must rest **higher** than the same box dropped flat. That single
  assertion is the whole point of the project and nothing today can pass it.
- `demo_gib_spin` stays green, including `--land`.
- `demo_gib_floor --selftest`: the BSP height spread must stop being 0.0000 and the
  worst resting tilt must stop being 90 degrees.
- `probe_settle.cpp` section C (four attitudes, four resting heights) must stop
  reporting one number four times.
- No regression in resting height for players: they are hull 1/3 and must be untouched.

## Already measured — do not redo

| | |
|---|---|
| the trace is orientation-blind | sphere-with-box-inertia matches the box to every digit |
| no rest attitude | flat / on end / on edge / on corner all rest at 0.0138 |
| the lever is radial | `lever·n = -1.0000` every sample |
| rolling is free | `\|v\| = w·r` to 4 dp; 35.6 m in 60 s, not decaying |
| the BSP path is clean on energy | but only because it is blind |
| bug 1 | fixed, alanfischer/hop#83 |
| the damp/sleep catch-22 | fixed, alanfischer/hop-godot#47 |
