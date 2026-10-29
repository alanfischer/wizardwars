# Solver-driven gib tumbling

> **Status (2026-09-09): SHIPPED — the solver tumbles gibs now.** `gib_body.gd` is
> deleted and `lock_rotation` is off. Two of the three bugs below are still open; see
> "What shipped and what it cost" for what that means in play. None of the three is in
> the BSP traceable, which is where this doc used to point.
>
> | | what | state |
> |---|---|---|
> | **1** | `integrate_angular` steps Euler's equation with forward Euler, so any anisotropic body gains rotational energy in free flight — no contacts involved | **FIXED** — energy-ellipsoid projection, `demo_gib_spin --spin` green |
> | **2** | A capsule resting on a floor creates spin from nothing | diagnosed (single witness point on a line contact); capsule-only, boxes are immune |
> | **3** | A thin box *landing* under the speculative contact mode runs away by five orders of magnitude | **FIXED** (2026-09-13) — by contact manifolds (hop #91), not by anything aimed at it; `demo_gib_spin --land` speculative column reads 1.00x on every row |
>
> Energy is not the whole story: even where the BSP path conserves it perfectly the
> gibs still never come to rest, for four reasons of their own. See
> [Why they never settle](#why-they-never-settle--a-separate-question-from-energy).
>
> Gibs used to be stable only because `lock_rotation` zeroed their inertia, which gated
> hop's whole angular path off. Unlocking it is what exposed all three.

## What shipped and what it cost

Three changes, in the order they have to land:

1. **hop** — bug 1 fixed (see below). Without this a gib gains energy on every lively
   landing and cruises at a solver constant.
2. **hop-godot** — the angular-damp loop now skips bodies already turning slower than
   the sleep threshold. `set_angular_velocity` calls `activate()`, so damping a
   nearly-stopped body reset its deactivation counter every step and it could never
   sleep. This is finding 4 below, and without it damping a gib makes it *never* settle.
3. **wizardwars** — `gib_body.gd` deleted (~95 lines). `gib_effect.gd` gives the body a
   random attitude, an end-over-end `angular_velocity` about an axis across the bone,
   `angular_damp = 3.0`, the gib's own bounding box as its collider, and a matching
   inertia tensor. `_roll_radius` is gone with the disc it sized.

The collider is the gib's **own bounding box** — the disc/slab proxy is gone. Because
the BSP trace reads that box unrotated whatever the body is doing (finding 1), its
vertical extent alone sets the resting height, so the mesh is turned once at spawn to
put its **thinnest** extent on body Y (`_flat_basis`). A fixed axis swap, not an
animation; the extents are the mesh's own, only reordered.

That is worth more than it sounds. Measured across all 54 shapes in the ten shipped gib
models, resting height vs. half the mesh's true thickness:

| | worst error |
|---|---|
| the old disc | **22.16 cm** |
| the gib's box, thin axis on Y | **0.00 cm** |

The disc was floating debris badly — a 1.3 cm glass shard rested 14.9 cm off the floor,
and cinder chunks were out by 22 cm. Every shape is now exact. A naive bounding box
without the axis swap would *not* be: most gib meshes are already flat in Y, but cinder
and ice chunks are tall in Y and would have hovered by half their length instead.

The inertia tensor is taken from the same box, so collider and tensor now agree rather
than describing two different shapes.

Damping was chosen by measurement, not taste — it has to survive a ~0.5 s flight and
still settle inside the 2–3 s gib lifetime:

| damp | ω at landing | settles | scatter |
|---|---|---|---|
| 0 | 11.8 | never | 2.6 m |
| 1.0 | 10.4 | 6.97 s | 0.96 m |
| 2.0 | 9.1 | 3.93 s | 0.76 m |
| **3.0** | **6.6** | **2.88 s** | **0.68 m** |

**What is still wrong — and which cause is which.** Do not attribute the rest-attitude
problem to the two open bugs; they are unrelated to it.

- **No rest attitude** is **finding 1**, not a bug in the table. The BSP trace never
  sees the gib's shape or orientation, so "on end" and "flat" are the same state and
  both rest at the same height. Fixing bugs 2 and 3 would not change this by one
  millimetre. What would change it is giving the trace real shape/orientation awareness
  — hop-godot#46 — which is still DO NOT MERGE precisely because it walks into bug 3.
- ~~**It stops by damping**, not by the floor taking its energy (findings 2 and 3).~~
  No longer true as of 2026-09-13. With `angular_damp = 0` a gib now settles in 1.2-2.0 s
  and hop deactivates it, on an `aa_box` floor and a BSP one alike, five launches each —
  the floor takes the energy. `GibEffect.ANGULAR_DAMP = 3.0` only shortens the tumble now;
  it is a look, not a prop.
- **Bug 2 does not affect gibs at all.** It is capsule-only; every box measured clean,
  and gib colliders are boxes.
- ~~**Bug 3 is a live hazard, but not an attitude one.**~~ Fixed — see the table above.
  A gib landing on an `info_clipbrush` StaticBox is no longer on a bad path.


## The goal

Delete `src/systems/gib_body.gd` (~95 lines) and let the physics solver tumble
gibs, instead of locking their rotation and hand-animating the pose: free tumble
in the air, log-roll about `(up × v)` on the ground. **Done** — see above.

## What gibs used to do (before the change above)

`GibEffect.spawn` sets `body.lock_rotation = true`. In hop that zeroes the body's
inertia, `rotates_dynamically()` goes false, and the entire angular path —
`integrate_angular`, the angular impulse response — never runs. The RigidBody3D
does **position only**. Everything you see turning is `gib_body.gd`:

- **airborne:** a fixed random axis leaning across the bone, at a rate picked once
  at spawn and never changed — no response to anything it hits.
- **grounded** (a down-ray finds floor within `roll_radius + 3 cm`): the long axis
  snaps to `up × v` and it turns at `w = v/r`, capped at 25 rad/s, blended in over
  80 ms.
- **collider:** the square slab, `span × (roll_radius·2) × span`, because the BSP
  trace reads the mover's unrotated AABB whatever its attitude, so only the
  vertical extent decides resting height.

This is not a stopgap someone picked over a better option. It is the only
configuration in which gibs are stable at all.

## Reproduction

`hop/examples/demo_gib_spin.cpp` (hop `main`, 9560f56). Headless, no raylib,
judges **energy only**, exits non-zero while anything gains:

    cmake -S . -B build -DHOP_BUILD_REPRO=ON
    cmake --build build --target demo_gib_spin && ./build/demo_gib_spin

`--spin` runs table 1 (bug 1) alone, `--land` table 2 (bug 3).

**Judge energy, never |w|.** A small body *rolling* legitimately spins fast — a
1 cm sphere rolling at 0.7 m/s turns at 70 rad/s — so a |w| threshold flags honest
rolling and misses a body quietly doubling its energy. An earlier pass of this
investigation judged |w| and reached wrong conclusions twice.

---

## Bug 1 — the angular integrator invents energy

**Root cause, confirmed.** `simulator::integrate_angular` steps Euler's equation
explicitly:

```cpp
cross(gyro, wb, Iw);          // w x (I.w)
sub(net, tb, gyro);
mul(dwb, inv_inertia_, net);
mul(dwb, dt);
add(wb, dwb);                 // forward Euler
```

The free top conserves `0.5*w.I.w`, which confines w to an ellipsoid in the body
frame; the gyroscopic term is the rotation carrying it around that surface. A
forward step goes along the **tangent**, which always lands outside — so it gains
energy every tick, without bound. The source comment calls the term "cheap and
stabilizing". It is cheap, and it is the opposite of stabilizing.

Give a body no gravity, no floor and `collide_with_scope(0)`, spin it, wait 30 s.
Rotational energy is conserved for a free rigid body, so every row must be 1.00x:

| body | Ix : Iy | w0 = 10 | w0 = 30 |
|---|---|---|---|
| cube 3x3x3 cm | 1 : 1.00 | **1.00x** | **1.00x** |
| chunk 5x4x3 cm | 1 : 1.56 | 4.46x | 7.43x |
| slab 12x3x12 cm | 1 : 1.94 | 48.87x | 5.43x |
| plate 9x2x7 cm | 1 : 2.04 | 53.95x | 6.00x |
| shard 10x1x6 cm | 1 : 4.23 | 58.80x | 6.36x |
| rod 18x2x2 cm | 1 : 41.0 | 65.54x | 7.34x |

Only the isotropic body survives, because there `w x (I.w)` is identically zero
and the term never fires. **That is why nothing caught it**: every hop demo body
that spins is a sphere, a cube, or does not spin long enough to notice. It is also
the real answer to "why does `demo_bounce` look fine" — its free box is a unit
cube.

### The fix (applied)

Two were measured at exactly 1.000x on every row:

1. Drop the gyroscopic term. Unconditionally stable, loses the tennis-racket
   effect. Several shipping engines do exactly this.
2. Keep it, and scale w back onto the energy ellipsoid after the step. Also
   1.000x, and the physics survives.

**(2) is what shipped.** `integrate_angular` now steps the two halves apart, because
they answer to different invariants:

- The **gyroscopic** half does exactly zero work — `d/dt(½ω·Iω) = ω·(−ω×Iω) = 0`,
  since `ω×Iω ⊥ ω`. So it only carries ω around the energy ellipsoid, and pinning the
  energy across it is the physical invariant rather than a fudge. Step it, then
  rescale ω by `sqrt(e0/e1)`.
- The **applied torque** half is the part that genuinely changes energy, so it is
  added after the projection rather than through it.

Isotropic bodies take the same path and fall out at the `e1 != e0` early-out. Cost is
one sqrt and one divide per rotating body per tick.

Verified: `demo_gib_spin --spin` all 1.00x and exits 0; all 14 hop tests pass;
precession survives (an intermediate-axis spin still flips 5 times in 30 s, the
tennis-racket effect, which is exactly what fix 1 would have lost).

**The residual, stated honestly.** The projection pins energy, not |L|. Over 60 s of
free spin, energy is 1.00000 on every body and |L| drifts up to 8%:

| body | Iy:Ix | E/E0 | \|L\|/\|L0\| |
|---|---|---|---|
| cube 3x3x3 cm | 1.00 | 1.00000 | 1.00000 |
| chunk 5x4x3 cm | 1.36 | 1.00000 | 0.99103 |
| plate 9x2x7 cm | 2.45 | 1.00000 | 0.91966 |
| shard 10x1x6 cm | 3.68 | 1.00000 | 0.95940 |
| rod 18x2x2 cm | 41.00 | 1.00000 | 1.00575 |

The drift is identical at |w0| = 10 and |w0| = 30, so it is a bounded orbit error,
not an instability. Pinning both invariants is Bullet's implicit gyroscopic solve,
which needs a 3x3 inverse — hop has none, and would not want one across its
fixed-point scalar types.

### What it did for gibs

A lot, and not enough. Same probe, before and after:

| | before | after |
|---|---|---|
| E60/E5, thrown flat spinning | 5.955 | 0.934 |
| E60/E5, tumbling hard | 1.292 | 0.636 |
| \|v\| at 60 s | 0.564 m/s (23 u/s) | 0.063 m/s (2.5 u/s) |
| roll speed set by the angular cap | yes, 1:1 | **no** — all four caps give 0.0629 |

Energy now *decays* instead of growing, the cruise speed drops ~9x, and it is no
longer a solver constant. But they still do not settle. At 300 s:

| launch | \|v\| @60s | \|v\| @300s | \|w\| @300s | dist | slept |
|---|---|---|---|---|---|
| thrown flat, spinning | 0.0629 | 0.0443 | 3.9581 | 16.0 m | never |
| tumbling hard | 0.0945 | 0.0370 | 3.9358 | 18.7 m | never |
| dropped, barely moving | 0.0155 | 0.0155 | 1.2931 | 4.7 m | never |

Findings 1-4 below are untouched by this fix: the contact is still a sphere, rolling
is still free, |w| never reaches the 0.2 rad/s sleep threshold, and the damp
catch-22 still stands.

## Bug 2 — a capsule at rest creates spin

Place a body **exactly** at its resting height with `v=0, w=0`, so there is
nothing to convert, and run 30 s:

| body | sweep_slide w | speculative w |
|---|---|---|
| sphere, cube, chunk | 0.00 | 0.00 |
| **rod CAPSULE 18 cm r=1 cm** | **13.73** | **5.12** |
| **BIG capsule 1 m r=10 cm** | **3.85** | **0.84** |
| rod BOX, shard BOX, slab BOX, big BOX | 0.00 | 0.00 |

**Every box is clean. Only capsules spin up**, and the bug 1 fix does not touch
it, so it is genuinely separate.

This is the single-witness-point problem: a capsule lying down touches along a
**line**, the support function has a tie, it breaks it arbitrarily, and the winner
flips end to end frame to frame — so the normal impulse acts on a lever that
swings the full half-length and changes sign with it. The per-frame trace is in
`probe_trace.cpp`.

The energy involved is small, bounded by roughly a millimetre of settling. It is a
spin bug, not an unbounded one, and it does not affect gibs, whose colliders are
boxes. Lowest priority of the three.

**Do not generalise this to boxes.** An earlier draft of this doc did ("a face is
the same degeneracy, worse") and built a contact manifold on that basis. The table
above says otherwise: a box resting on its face does not see-saw.

## Bug 3 — a thin box landing under speculative

**Not diagnosed.** Energy at 30 s over energy at 5 s, so growth after landing,
worst of three tumbling launches, **with bug 1 already fixed**:

| body | box floor, slide | box floor, **specul.** | BSP floor, slide | BSP floor, specul. |
|---|---|---|---|---|
| cube 3x3x3 | 1.00x | 1.34x | 1.06x | 1.00x |
| chunk 5x4x3 | 1.07x | 0.82x | 1.01x | 1.00x |
| slab 12x3x12 | 1.17x | **220145x** | 0.97x | 0.97x |
| rod 18x2x2 | 4.13x | **115575x** | 1.00x | 1.00x |

What is known:

- It needs the **speculative** contact mode. hop's own default `sweep_slide` is
  nearly clean, which is what every demo runs — and hop-godot gives dynamic bodies
  speculative.
- It tracks **flatness**. A cube and a chunk are fine on the same code path.
- It needs a **landing**. The same bodies placed at rest are clean (bug 2 table).
- It arrives as a **single frame injecting several joules** on first contact —
  `probe_traj.cpp` catches it: frame 25, `dE = +5.44 J`, `|w|` saturating the
  angular cap at 50 per component.
- Ablating restitution, friction, position iterations, solver iterations, the
  angular cap, and the speculative margin **each individually fails to fix it**.

## Why they never settle — a separate question from energy

The three bugs above are all about *energy*. Settling is a different failure: it does
not need any of them, and fixing them does not cure it. Take bug 1 out of the picture
(the isotropic row in the table below is 1.000x at every checkpoint) and the gib still
rolls forever. `probe_settle.cpp` measures it. Four findings, each on its own
sufficient.

Bug 1 *is* live on the BSP path, though, and it does more than the earlier table
suggests — it is not confined to free flight. Same `aa_box` shape, same launch, same
BSP contact; only the inertia tensor changes, and the contact cannot tell the two
apart (finding 1 below), so the difference is entirely `integrate_angular`:

| inertia | E@5s | E10/E5 | E20/E5 | E40/E5 | E60/E5 |
|---|---|---|---|---|---|
| box (anisotropic, 1:3.5) | 0.1082 | 5.057 | 5.188 | 6.706 | 5.689 |
| same box, isotropic I | 0.0670 | **1.000** | **1.000** | **1.000** | **1.000** |

It plateaus rather than running away only because the angular cap
(`max_angular_velocity_component`, 50 rad/s) clamps it. That clamp then sets the speed
a gib cruises at forever, because rolling without slipping ties `v` to `w`:

| cap (rad/s) | \|w\| @60s | \|v\| @60s | cap x half-height | GoldSrc u/s |
|---|---|---|---|---|
| 12.5 | 15.46 | 0.1612 | 0.1500 | 6.4 |
| 25.0 | 30.85 | 0.3327 | 0.3000 | 13.3 |
| 50.0 | 66.57 | 0.5644 | 0.6000 | 22.6 |
| 100.0 | 111.78 | 1.2579 | 1.2000 | 50.3 |

So the cruise speed is a solver constant, not anything about how the gib was thrown.
Gentle landings escape all of this — "dropped barely moving" and "dropped dead still"
both hold 1.000x, and the dead-still one does stop. The pump needs a lively landing to
seed it.

**1. The contact is a sphere, so there is no rest attitude.** `trace_solid` reads
only the mover's local AABB and walks the witness straight down the normal, so the
box's geometry reaches the solver *only* through its inertia tensor. A sphere handed
the box's inertia reproduces the box to every printed digit:

| body, same launch, 20 s | y end | \|v\| end | \|w\| end | dist |
|---|---|---|---|---|
| gib box | 0.0138 | 0.6610 | 58.5896 | 9.7767 |
| sphere, sphere inertia | 0.0138 | 0.7314 | 60.9838 | 14.9071 |
| **sphere, BOX's inertia** | **0.0138** | **0.6610** | **58.5896** | **9.7767** |

So resting height is orientation-independent — flat, on end, on edge and on a corner
all rest at half-Y, where a real box on end would rest at half-X, five times higher:

| dropped rotated about | rest y |
|---|---|
| nothing (flat) | 0.0138 |
| Z by 90 deg (on end) | 0.0138 |
| X by 90 deg (on edge) | 0.0138 |
| X by 45 deg (corner) | 0.0138 |

There is no orientation-dependent energy well, so "lying down settled" is not a state
the solver has. It is the same blindness that makes the BSP path clean on energy.

Two more numbers for scale. The gib is a ball of radius half-Y (1.2 cm) carrying a
whole 12 cm bone's rotational inertia — `I_long / (m r^2) = 3.17`, where a solid sphere
is 0.40 and a hoop is 1.00 — so **94% of its kinetic energy sits in spin**, and it
coasts like a flywheel. And 0.6 m/s is ~5 body-lengths a second, held indefinitely.

**2. Friction can only drive it to rolling, and rolling is free.** The measured lever
is `lever·n = -1.0000` at every sample — exactly antiparallel to the normal, which is
what PR #43 was for (a corner lever turns the support impulse into torque and spins a
flat-dropped box to 37 rad/s). The cost is that friction's only remaining torque is
the rolling torque of a wheel of radius `reach`. The body converges on rolling without
slipping — `|v| = w·r` to four decimals at every sample — and there the slip velocity
at the contact is zero, so friction does no further work. hop has no rolling resistance
and no spin/twist friction. Nothing is left to take the energy: **35.6 m travelled in
60 s, still doing 0.5–0.7 m/s, not decaying.**

**3. So it can never pass the sleep test.** `try_deactivate` requires
`|w| < deactivate_speed` = 0.2 rad/s (`simulator.h:1121`). A gib 2.4 cm thick rolling
at 0.7 m/s turns at ~60 rad/s; to get under the threshold it would have to be doing
2.4 mm/s. (The machinery itself is fine — a gib *placed* at rest sleeps at 0.87 s on
the BSP floor and 0.85 s on an `aa_box` floor.)

**4. The obvious fix is a catch-22.** hop-godot never applies Godot's project-default
angular damp: `angular_damp` defaults to 0 (`hop_body_data.h:56`), the damp loop
early-returns on `<= 0`, and it is deliberately "body damp only, no area override"
(`hop_physics_server.cpp:2324`). `GibEffect` sets none. But setting one does not help,
because `solid::set_angular_velocity` calls `activate()` (`solid.h:228-231`) and the
damp loop calls that setter *every step*. Sleep needs 32 consecutive still ticks; the
counter is reset before it can reach 2.

| angular damp applied | \|w\| @ 60s | \|v\| @ 60s | slept at |
|---|---|---|---|
| none (damp = 0, today's gib) | 61.4575 | 0.4653 | never |
| every tick (hop-godot's loop as written) | 0.0000 | 0.0000 | **never** |
| only while \|w\| > sleep speed | 0.1979 | 0.0000 | **3.37 s** |

Guarding that write is the smallest real lever in this whole investigation: one
condition in `hop_physics_server.cpp`, and a damped body sleeps. It does not fix 1 or
2 — a gib would still roll to a stop rather than lie down on a face, and would still
never choose an attitude — but it turns "rolls off the map" into "comes to rest".

Note that the rolling `|w| ≈ 60` here is *honest*: it equals `v/r`. This is exactly the
trap the probe README warns about, and it is not bug 1. Bug 1 governs the airborne
phase.

## What is cleared

- **The BSP traceable.** It was the prime suspect for this whole investigation and
  is implicated in nothing. Bug 1 has no floor at all; bugs 2 and 3 reproduce on a
  plain `aa_box` floor, and the BSP column above is the *clean* one. Not a virtue —
  the BSP trace reads the mover's unrotated AABB and puts the witness straight down
  the normal from the body centre, so a radial lever produces no torque and it
  cannot feed the path box-vs-box gets wrong. It is clean because it is blind.
- **hop-godot#46** (`bsp-oriented-capsule`) was quarantined DO NOT MERGE on the
  theory that its orientation-dependent hull expansion was the cause. **That reason
  is disproved.** It should still not be merged casually — giving the BSP trace
  real shape and orientation awareness is precisely what would walk it into bug 3 —
  but it is no longer accused of causing anything.
- **The contact-manifold theory.** Superseded. It was built on generalising bug 2
  to boxes, which the measurements contradict. The work is on hop's
  `contact-support-set` branch (753df56) and
  `plans/probes/rotating_gibs/persistent_manifold_prototype.patch`; both are kept
  for the record, neither should be built on.

## Order of work

1. ~~**Fix bug 1.**~~ **Done** — energy-ellipsoid projection in `integrate_angular`,
   `demo_gib_spin --spin` green. Not yet committed or PR'd to hop.
2. ~~**Diagnose bug 3.**~~ **Done, indirectly.** Contact manifolds (hop #91, Phase 14)
   closed it: the injection was a single contact point fabricating a lever arm, and a
   resting body is now held at four. Bisected on `demo_gib_spin --land`, worst
   speculative row by hop commit — 4.85x before #86, 1.91x after it, 1.50x after #87
   (friction's tangent mass), 1.00x at #91. The two aimed fixes only nibbled at it.
3. Bug 2 only if capsule colliders are ever wanted; gibs use boxes.
4. ~~Then unlock gib rotation, delete `gib_body.gd`.~~ **Done**, ahead of 2 and 3 —
   see "What shipped and what it cost". The damping was revisited once bug 3 went: it is
   no longer holding anything up (see the struck-through bullet above), and
   `angular_damp` now reaches hop as `solid::set_coefficient_of_angular_damping`
   rather than a post-step loop in hop-godot.

## What landed and is worth keeping

`goldsrc_mdl.cpp` built only `bodypart.models[0]` — its own comment said "first
model only for now". A bodypart's other submodels are its bodygroup alternatives,
and in gib models those are the debris shapes, so a burst of nine gibs was the same
bone nine times.

    bonegibs.mdl 5 shapes · metalplategibs 13 · cindergibs 9 · glassgibs 8
    icegibs 5 · fleshgibs 4 · bushgibs 4 · rockgibs 3 · woodgibs 3

Every other shipped `.mdl` has exactly one submodel per bodypart — verified by
parsing the bodypart table of all of them — so building them all changes those nine
and nothing else. Shipped in 2d49e8f3 (goldsrc-godot#52, 6960db1), independent of
everything above.

## Probes

`plans/probes/rotating_gibs/`, with a README giving the build line. All build
standalone against hop; `probe_gib_bsp.cpp` additionally needs hop-godot's `src/`
and `bsp_fixtures.h` from the `bsp-oriented-capsule` branch.

## Gotchas hit along the way

- `GibEffect.spawn` early-returns on headless, so **the game test suite never
  exercises `_launch`** — only the static helpers. Nothing automated can tell you
  whether gibs actually tumble. That is how a completely inert change passed a
  green suite.
- The BSP traceable is the only traceable with no shape awareness: everything
  becomes `s->get_local_bound()`, an AABB. The trimesh one has understood
  capsules all along (`mover_world_capsule`).
- Godot authors capsules along **Y**; the hop-godot test fixtures author along
  **X**. Reading a capsule's spine out of a fixed axis slot passes every test and
  does nothing in the game. `test_a_rod_falls_over_whichever_axis_its_spine_runs_along`
  is the guard.
- `clean_cache.sh` also wipes `res://.godot/imported/`, which a headless run
  cannot regenerate — 9 unrelated tests fail on missing `.spr`/`.mdl` imports.
  Fix with `Godot --headless --path . --import`.
- Rebuild **all** dylib variants (`./build_extension.sh`) or the game loads stale
  code; the editor loads the arm64 *debug* one.
