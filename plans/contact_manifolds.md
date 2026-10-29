# A corpse that never stops moving

> **Status: IMPLEMENTED, with one deviation (the traceable interface was not changed) and
> one known regression (stacks of dynamic bodies) — see "What actually landed" at the foot
> of this file before reading any of the rest as current. The regression is characterised
> there in full, including what was ruled out and what the candidate fixes are worth.**
> This is the phase `docs/rotation_plan.md` deferred at the end of Phase 12 and again at
> the end of Phase 13, in the terms it deferred it: *"The fix is a contact manifold — two
> or four points under a resting face — and that is a phase of its own."* It is hop
> Phase 14.
>
> Read `plans/one_corpse_ragdoll.md` and `plans/ragdoll_joint_limits.md` first. This one
> assumes the 21-body corpse they built and the cone-twists that hold its shape.

## What is actually wrong

Nothing in the solver. It is arithmetic, and `examples/demo_ragdoll.cpp`'s control measures
it with no joints and no ragdoll anywhere — one box, dropped on a floor:

```
      half (m)  tilt (rad)      mean |w|
         0.040        0.00        0.0000     <- sleeps
         0.040        0.05        5.0631     <- never sleeps
         0.160        0.05        1.3259
         0.640        0.05        0.3200
```

**hop resolves a pair at ONE point, and `support()` on a tilted box returns a CORNER.** The
face centre it collapses to for an axis-aligned box is exactly why the tilt-0.00 rows sleep.
One tick of gravity's impulse on a corner lever is worth several rad/s on a 0.35 kg bone, so
the box tips, catches the next corner, and rocks there forever. |ω| goes as 1/size, and a
ragdoll bone is the smallest thing in the game. Damping does not touch it — the spin is
handed out fresh every tick rather than accumulating, which is why Phase 13 tried angular
damping on the bones and rejected it.

Three consequences, all shipped and all live today:

1. **No corpse ever sleeps.** `demo_ragdoll` Table 2: still awake after 600 ticks (9.6 s).
   Table 3's `asleep` column is `0/1, 0/2, 0/4, 0/8` — every body, every count.
2. **The game stops corpses on a timer instead.** `src/weapons/tumbling_corpse.gd:45-67`
   measures the busiest bone's *displacement* over a 0.5 s window, bakes the pose when it
   travelled under 0.10 m, and hard-stops at 8 s. That entire mechanism exists because hop
   cannot answer "is it resting". It costs the player up to 0.5 s of window granularity on
   top of the 1.86 s the corpse genuinely takes (Table 4), and 2 corpses in 32 never satisfy
   the bar at all and ride the cap.
3. **Loose gibs never sleep either.** Nobody had noticed, because they are destroyed before
   anyone watches one long enough. They are costing a full solve each, forever.

And the cost lands where it hurts: Table 3 says 8 corpses cost **4.48 ms/tick at rest** and
only 2.83 ms/tick while falling. Resting is the expensive state, because resting is the state
hop cannot leave.

## What modern engines do

This was the open question and it is worth answering properly, because the field is split and
the split is chronological rather than a matter of taste.

**The older answer: persist the geometry.** Bullet's `btPersistentManifold` takes the single
point GJK/EPA returns each tick, adds it to a cache of up to 4, and reduces the set by
maximizing the quadrilateral area it spans. PhysX's PCM (persistent contact manifold, the
default since PhysX 4) is the same idea with better face detection. The manifold *fills up
over several ticks* as the body moves. This was the right trade when narrowphase dominated
the frame.

**The newer answer: regenerate every tick, persist only the impulses.** Box2D (Erin Catto,
both v2 and v3) and Jolt (Jorrit Tyberghein — the engine Horizon shipped on) both pick the
reference face, pick the incident face on the partner, clip one polygon against the other's
side planes, and keep the survivors within the contact slop. The manifold is complete on the
first tick of contact. Nothing geometric is cached; what *is* cached, keyed by a feature ID
packed from the face and vertex indices, is the accumulated normal and friction impulse, so
warm-starting still works across ticks. Jolt's `ManifoldBetweenTwoFaces` is a page of code.

**The trend is towards the second, and the reason is exactly our bug.** An incremental
manifold's defect is that it needs the body to *move* to discover points, and it degrades
under rotation — the cached points were witnesses to an orientation the body has since left.
Our failing body is one that has nearly stopped and is rotating slightly. It is the worst
case for the incremental approach and the ordinary case for clipping.

**So: clip every tick.** That also settles a question the "accumulate" option would have left
open — how many ticks a corpse spends filling its manifolds before it can settle — which,
given that the entire complaint is settle *time*, is not a question worth having.

## Key decisions

1. **Manifolds are generated per tick by face clipping; only impulses persist.** Jolt/Box2D
   model. A point carries a `uint32` feature ID; next tick's freshly-clipped point with the
   same ID inherits `accum_n` / `accum_t`. No geometric cache, no "is this cached point still
   valid" tolerance, nothing to go stale under rotation.
2. **A manifold lives inside one touch slot, as sub-points.** `solid<T>::touch` keeps its one
   slot per partner and gains `point points[max_manifold_points]`. `find_touch`'s
   one-slot-per-partner contract is load-bearing in five places — the stale-partner compaction
   (`simulator.h:196`), the sustained-contact test (`:1129`, `:1467`), the support test in
   `try_deactivate` (`:1261`), the pair dedup and the gravity-aligned eviction heuristic
   (`:2061`) — and none of them want rewriting in the same phase as a new narrowphase.
3. **`traceable::trace_solid` changes signature outright.** It reports 0..N contacts. There
   are four implementors, all in hop-godot (`hop_bsp_traceable.h:767`,
   `hop_trimesh_traceable.h:103`, `hop_heightfield_traceable.h:107`, `hop_plane_traceable.h:48`)
   and they move in the same PR. No legacy single-point path to maintain, and no way for an
   implementor to silently keep returning one point and quietly keep the bug. **This is the
   decision that matters most for the game**: a corpse lies on BSP world geometry, which is a
   `shape_type::traceable` on a solid, so the BSP path *is* the ragdoll path. Fixing
   solid-vs-solid alone would not move the game a millimetre.
4. **Every shape that can rest is in scope — but a sphere does not get a manifold, it gets
   rolling resistance.** Honesty about the geometry: a box or convex resting on a face has a
   3–4 point manifold, a capsule lying on its side has a genuine 2-point manifold (its segment
   endpoints), and a **sphere, or a capsule stood on its end, touches at exactly one point and
   always will**. No clipping scheme changes that. Those shapes need a different mechanism —
   resistance to spin at the contact — and it ships in this phase because "everything that can
   rest" is the goal, but it is separate code with a separate test. See 14e.
5. **Each manifold point carries its own normal and its own separation.** The per-point
   separation is the whole point of the exercise: it is what tells a tilted box that one
   corner is 3 mm deep and the opposite one 8 mm clear, which is what levels it. Per-point
   normals additionally fix a smaller existing wart — a compound body wedged into two faces of
   the same partner currently has both normals *averaged* into one slot by
   `merge_intra_pair`'s `intra_merge::average` (`collide.h:1143`). The slot keeps a
   representative normal for the existing consumers in decision 2.
6. **Callbacks and the `collision_response` hook stay per-partner, not per-point.** They are
   already gated on `!sustained` (`simulator.h:1469`), i.e. on a partner having no touch slot
   yet. A resting body whose four points churn must not fire four impact sounds a tick. This
   is not hypothetical: gib and ragdoll impact audio in the game hangs off that callback.

## hop Phase 14

### 14a — the narrowphase produces a manifold

New in `collide.h`, and the bulk of the phase:

```
int clip_manifold(contact_point * out, int max_out,
                  const world_polytope<T> & A, const world_polytope<T> & B,
                  const vec3<T> & n, T slop);
```

Given the separating normal the existing GJK/SAT path already computes, pick A's face most
anti-parallel to `n` as the reference, pick B's most parallel as the incident, clip the
incident polygon against the reference face's side planes (Sutherland–Hodgman), keep the
survivors whose gap along `n` is `<= slop`, and reduce to at most 4 by the standard rule:
keep the deepest, then the point furthest from it, then the two that maximize the area of the
quadrilateral. `build_world_polytope` (`collide.h:924`) already gives the world-space faces,
so the inputs exist.

The reduction **must be deterministic** — ties broken by index, never by float comparison
order. hop already cares about this (`solid::solve_id_` exists because a raw pointer compare
reorders under ASLR, `simulator.h:2401`), and a manifold that reduces differently run to run
would desync the server from a client replaying the same tick.

Feature ID: pack `(reference face index, incident face index, clipped vertex index)` into a
`uint32`, plus a bit saying which body was the reference. Box2D's scheme. It must be stable
across ticks for an unchanging contact — that is the entire warm-start contract — and it must
be *different* for genuinely different points, or two points trade accumulators and buzz.

`test_solid` (`collide.h:1290`) and `merge_intra_pair` (`:1143`) both change shape: they now
merge *sets* of points across the shape pairs of a compound solid rather than reducing to one
collision. Cap per solid pair at `max_manifold_points`, applying the same area reduction —
a compound body resting on two distinct shapes of one partner must keep points from both, so
the reduction runs over the union, not per shape pair.

### 14b — the traceable interface

```
virtual int trace_solid(collision<T> * out, int max_out, solid<T> * s,
                        const vec3<T> & position, const mat3<T> & orientation,
                        const segment<T> & seg, T margin) = 0;
```

Returns the number written. The doc comment in `traceable.h` — which is the real
specification for this interface, and unusually good — needs its CONTACT POINT paragraph
rewritten to say what the contract is for N points: every point on the traceable's surface,
every one carrying its own normal and its own `depth` measured against the *inflated* surface,
and `time` shared across the set (a swept hit is one TOI; only a resting/overlap hit is
multi-point).

Per implementor:

- **BSP** (`hop_bsp_traceable.h`). The one that matters. The hull walk already ends at the
  plane the mover stopped against, and Phase "oriented BSP trace" (hop #88) taught it to
  report *the box feature that actually touches*. Extend that: after the walk, take the
  mover's support face against the contact plane and clip it to the leaf's plane set. A
  GoldSrc hull leaf is already a convex plane intersection, so this is the same clip as 14a
  with the leaf standing in for the reference face.
- **Trimesh / heightfield** (`hop_triangle_collision.h:585`, `trace_solid_rotated`). These
  already iterate candidate triangles and merge to one result. The merge becomes a collect:
  each triangle within slop contributes a point, then the shared reduction runs. Feature ID is
  the triangle index plus the mover's vertex index. Watch the seam logic (`seam_tol_`) —
  today it suppresses duplicate normals at shared edges, and with manifolds a shared edge
  legitimately produces two points.
- **Plane** (`hop_plane_traceable.h`). Trivial: clip the mover's support face to the plane.

`simulator::trace_solid` (`simulator.h:1780`) is also the **public query API**, used at eight
sites in `hop_physics_server.cpp` for shape casts, overlap tests and unstick probes, all of
which want one hit. Keep a single-result overload that forwards and returns the deepest, so
those call sites do not move.

### 14c — storage and warm-starting

```
struct touch {
    solid<T> * partner;
    vec3<T>    normal;          // representative; the deepest point's
    T          impact_speed;
    int        last_tick, pair_built_tick;
    struct point {
        vec3<T> impact, lever, normal, accum_t;
        T       accum_n, separation, vn0;
        uint32_t id;
    };
    point points[max_manifold_points];
    int   point_count;
};
```

`add_or_refresh_touch` (`simulator.h:2004`) becomes `add_or_refresh_manifold`: same
partner-slot logic, but the inner loop matches this tick's points to last tick's **by ID** and
carries `accum_n`/`accum_t` across, zeroing them for any ID that is new. The existing
"stale slot, wipe the accumulators" rule (`:2019`) generalizes to per-point.

**Memory.** A touch grows from ~80 bytes to ~280, and 12 slots per solid from ~1 KB to ~3.3 KB.
For 168 ragdoll bodies that is 560 KB, which is nothing on a PC and is *not* nothing on the
fixed16 targets hop supports. Make `max_manifold_points` a compile-time constant defaulting to
4; setting it to 1 must restore today's footprint and today's behaviour exactly, and there
should be a test that says so.

`try_deactivate`'s support scan (`:1261`) walks points instead of slots — a body is supported
if *any* point of any fresh slot is load-bearing, same `separation <= spec_slop_ || accum_n > 0`
test. The eviction heuristic (`:2061`) keeps scoring on the slot's representative normal.

### 14d — the solver

`build_contact_pairs` (`:2388`) emits **one `contact_pair` per manifold point**, sharing `a`,
`b` and the per-point normal, each with its own `r_a`/`r_b`, `separation`, `eff_n` and
accumulators, and `slot_a`/`slot_b` pointing at the sub-point rather than the slot. The
Gauss–Seidel sweep at `:2837` needs no structural change — four rows under a box level it
because each row sees its own gap, and that is the entire fix.

Three things to watch:

- **Restitution.** `target` is precomputed per pair from `impact_speed`, which is per-partner
  today. It must become per-point from that point's own `vn0`, or a box landing flat on four
  points applies restitution four times and bounces like a superball.
- **Shock propagation** (`:2911`) sorts the pair list by support depth. With ~4× the pairs the
  sort grows; it is `O(n log n)` on a vector that is already reused, so measure before
  optimizing.
- **Position correction.** The NGS pass (`correct_positions`, `:1595`) is what actually levels
  a tilted box out of penetration, via `rot_correction_`. It already handles rotation, and
  four points will simply feed it a torque that the one point could not express.

**The cost story, stated up front so the perf table is not a surprise:** contact rows go up
roughly 4×, so a *falling* pile gets more expensive. A *resting* pile gets radically cheaper,
because it sleeps and stops being solved at all. Table 3's 4.48 ms/tick at rest for 8 corpses
should collapse towards zero, and that is the number to judge the phase on. If the falling
number regresses badly, `max_manifold_points = 3` is the dial — three points hold a plane.

### 14e — the shapes a manifold cannot help

A sphere resting on a floor touches at one point. So does a capsule on its end, a cone on its
tip, and a box balanced on a corner it genuinely is balanced on. Clipping returns one point
because there *is* one point, and that single point still hands out a corner-lever impulse
every tick.

- **A capsule on its side is a real 2-point manifold** — the two endpoints of its inner
  segment, where the segment is near-parallel to the surface. Generate it in `collide.h`
  alongside 14a: if `|dot(segment_dir, n)|` is under a threshold, emit both endpoints'
  witnesses; otherwise emit the one. `trace_capsule_capsule` (`:107`) already has the segment
  math.
- **A sphere gets rolling resistance.** Not a manifold — a torque opposing ω at the contact,
  bounded by `mu_roll * lambda_n * contact_radius` and clamped so it can only *remove* spin,
  never reverse it. This is the standard treatment and it is the only thing that stops a ball
  rolling forever on a flat floor. It is a new per-material coefficient
  (`coefficient_of_rolling_friction_`, defaulting to 0 so nothing existing changes), applied
  in the friction sweep next to the tangent clamp at `:2880`.

Keep these two clearly separate from 14a in the code and in the tests. They are a different
mechanism that happens to fix an adjacent symptom, and conflating them is how a phase turns
into two phases wearing one commit message.

## hop-godot

- The four traceables move with the interface (14b).
- **`body->sleeping` is write-only today and must start reporting.** `hop_body_data.h:64` is
  set from the game (`hop_physics_server.cpp:1040`) and read back by
  `BODY_STATE_SLEEPING` (`:1060`) and `HopDirectBodyState::_is_sleeping`
  (`hop_body_state.cpp:204`), but **nothing ever mirrors hop's own `solid::active()` into it**.
  So today, a body hop has genuinely slept still reports `sleeping == false` to Godot. Mirror
  `!hop_solid->active()` into it each tick in the post-step sync and emit Godot's
  `sleep_state_changed` when it flips. Without this line the entire payoff is invisible to the
  game, and it is worth landing *first*, before any of Phase 14 — it is independently correct.
- Check `BODY_PARAM_ANGULAR_DAMP`, which `solid.h` stores and ignores. Phase 13 established
  damping is not the answer here and this phase does not change that, but a rolling-resistance
  coefficient is a plausible place to map it if a mapping is wanted.

## The game side

Small, and the whole reason for the phase.

`src/weapons/tumbling_corpse.gd` stops guessing. `_physics_process` (`:374-394`) currently
runs the window/displacement estimator; it should instead ask the bodies:

```gdscript
func _all_bones_asleep() -> bool:
    for b in _bones:
        if not PhysicsServer3D.body_get_state(b.get_rid(), PhysicsServer3D.BODY_STATE_SLEEPING):
            return false
    return true
```

Bake on that. **Keep `MAX_SIM_TIME` and keep the window estimator as the fallback** — a corpse
half-inside a brush may genuinely never sleep, and the 8 s cap is what stops it flailing
through its whole linger. The estimator becomes the safety net it should have been, rather
than the primary mechanism.

Expected: corpses bake within a tick or two of actually stopping instead of 0–0.5 s later,
and the 2-in-32 that never satisfy the displacement bar settle like the rest.

`plans/rotating_gibs.md` bug 2 ("a capsule resting on a floor creates spin from nothing")
closes with 14e. Gibs will start sleeping, which is free server CPU nobody budgeted for.

## Order of work

1. hop-godot: mirror `solid::active()` into `body->sleeping`. Independent, one line plus a
   signal, ship it alone.
2. hop 14c: the storage change, with `max_manifold_points = 1`. **Everything must be
   bit-identical** — this is pure plumbing and the test suite is the proof.
3. hop 14a: clipping for polytope pairs, `max_manifold_points = 4`. Box-on-box sleeps.
4. hop 14b: the traceable interface and the four implementors, BSP first. Box-on-BSP sleeps;
   `demo_ragdoll`'s control table goes to zero.
5. hop 14d: per-point restitution and the solver audit. (3 and 4 will appear to work before
   this; the bouncing is what gives it away.)
6. hop 14e: capsule 2-point, sphere rolling resistance.
7. The game side.

Steps 3 and 4 are each independently demonstrable on the control table, which is the reason
to keep them apart.

## Tests and the demo

`demo_ragdoll.cpp` already has the instrument; it needs no new tables, only different numbers.

- **Table 2's control: every row sleeps.** All six, mean |ω| 0.0000. This is the phase's
  headline and it is a table that exists today.
- **Table 2's corpse sleeps** inside its 600 ticks, where today it is awake at the end.
- **Table 3's `asleep` column reads `1/1 … 8/8`**, and `ms/tick rest` falls below
  `ms/tick fall` — the inversion is the proof that resting became cheap.
- **Table 4: `settled` under 1.0 s, 0 never**, against 1.86 s and 2 never.
- `demo_pile.cpp` and `demo_settling.cpp` are the regression guards: piles must not jitter,
  sink, or go rigid-and-wrong. Run both before and after.

New `tests/test_manifold.cpp`:

- a box flat on a plane reports 4 points; on an edge, 2; on a corner, 1.
- a box tilted 0.05 rad on a plane is asleep within N ticks and its |ω| stays under a
  threshold throughout — the bug, as a test.
- feature IDs are stable across ticks for a body that does not move, and `accum_n` is
  therefore carried rather than rebuilt.
- `max_manifold_points = 1` reproduces the pre-phase behaviour exactly.
- the reduction is deterministic: same inputs, same four points, same order, across runs.
- a compound solid resting on two shapes of one partner keeps points from both.
- rolling resistance stops a sphere on a flat floor and does not reverse its spin.

hop-godot: extend `test_bsp_traceable.cpp` for multi-point returns against a flat floor brush
and a corner, and `test_trimesh_traceable.cpp` for the seam case where a shared edge should
now legitimately yield two points.

## Not this phase

- **Ragdoll self-collision.** Still `collision_layer = 0` (`src/systems/ragdoll_builder.gd:76`).
  A limb still passes through the torso. Manifolds make self-collision *affordable to think
  about* but do not enable it, and turning it on is its own playtest.
- **Continuous manifolds through a swept TOI.** A swept hit stays one point; only resting and
  overlapping contacts are multi-point. Fast-moving bodies do not have a settling problem.
- **`max_touches` (12 partners).** Unchanged. The complaint is points per partner.
- **The `manager` interface's single merged contact** (`simulator.h:1542`). WizardWars does not
  use manager-injected geometry for the world — the BSP is a traceable shape on a solid, which
  is why 14b is where the game's fix lives. Leave the manager path alone; note in
  `manager.h`'s doc comment that it remains a single-contact interface *by design*, so the next
  reader does not assume it was overlooked.

## Risks, and what to measure

- **A stack that used to settle by sinking now holds, and holds wrong.** Four points make
  contacts much stiffer. `demo_pile` is the guard; watch for piles that stand rigid at a
  visible gap, which means the slop and the reduction disagree.
- **Feature ID instability produces buzzing that looks exactly like today's bug.** If a box
  sleeps on a plane but not on a triangle mesh, suspect the triangle index in the ID changing
  as the body shifts between coplanar triangles. Coplanar-triangle merging may be needed on
  the trimesh side.
- **The falling-pile cost.** Measure Table 3's `ms/tick fall` at 8 corpses before and after.
  A 4× row count for a 1.5× wall-clock cost is a good trade given what happens to the resting
  number; a 3× wall-clock cost is not, and `max_manifold_points = 3` is the dial.
- **Fixed-point.** `test_fixed16.cpp` / `test_fixed32.cpp` must stay green. The area-maximizing
  reduction multiplies cross products of differences of positions — easy to overflow in
  fixed16. Normalize into a smaller range or reduce on squared lengths only.
- **Tuning on one drop is worthless.** Established by Phase 13 and it applies here twice over:
  a ragdoll on a floor is chaos and one corpse's settle time swings by seconds on a change that
  means nothing. Table 4 runs 32 corpses thrown 32 ways and reports means. Use it.

## Open questions

- **Does the clip want the *incident* face from the traceable side at all for BSP?** A GoldSrc
  hull leaf gives a plane set, not a face polygon. Clipping the mover's face to the leaf's
  planes is the natural formulation and needs no polygon from the BSP — but it means the
  contact points lie on the mover's face, not on the world surface, and `traceable.h`'s
  contract currently says `impact` is the point ON the traceable. Projecting each clipped
  point onto the contact plane resolves it; confirm that is what the lever-arm math wants.
- **Should `spec_slop_` grow with manifolds?** A tilted box's second point may sit a few mm
  clear at the moment the first touches. Too tight and the manifold is a single point again
  for the first several ticks; too loose and bodies float. Start at the current slop and
  measure the point count in Table 2's control.


---

# What actually landed

## The headline

`demo_ragdoll`'s Table 2 control — one box, no joints, dropped on a floor — is the
measurement the phase was written against, and it reads zero now:

```
      half (m)  tilt (rad)      mean |w|   asleep        before
         0.040        0.00        0.0000      yes        0.0000
         0.040        0.05        0.0000      yes        5.2088   <- never slept
         0.160        0.00        0.0000      yes        0.0000
         0.160        0.05        0.0000      yes        1.3259   <- never slept
         0.640        0.00        0.0000      yes        0.0000
         0.640        0.05        0.0000      yes        0.3200   <- never slept
```

Every row sleeps, tilted or not. The same holds through the path the GAME uses: a tilted
box dropped on a **BSP floor** gets four contact points and is asleep at tick 86 with
|ω| exactly zero, and so does one on a **trimesh** floor.

Alongside it:

- **A sliding box now stops.** With one point it kept `vx = -0.08`, `ωz = 0.81` forever
  and never slept; it now stops dead and sleeps.
- **`demo_gib_spin` went from 9 failing checks to 4.** The whole speculative-collider
  column is clean (1.46x / 1.07x / 1.50x / 0.91x / 1.16x / 1.23x energy growth after
  landing, all now 1.00x). That is `plans/rotating_gibs.md` bug 2, on the path hop-godot
  actually gives dynamic bodies. The remaining 4 are the sweep_slide column, untouched.
- **Corpses settle sooner and hold together better.** Table 1's joint error fell from a
  mean of 0.0061 m to 0.0044 m, Table 4's settle time from 2.03 s to 1.62 s, and the
  "never settled" count for the limited corpse from 4 in 32 to 0.
- **Resting stopped being the expensive state.** Eight corpses cost 0.40 ms/tick falling
  and 0.46 ms/tick at rest, against 0.31 / 0.52 before — the 1.7x penalty for resting is
  gone, because 90 of 168 bones now genuinely sleep where **none** did before. The
  falling column rose ~1.3x for roughly 4x the contact rows, which is the trade the plan
  asked for.

## Deviation 1: `traceable::trace_solid` was NOT changed

Decision 3 said to change the signature outright so no implementor could quietly keep
returning one point. It is not changed, and the interface is untouched.

Instead `collide.h` grew `manifold_for_traceable`, which **probes** each corner of the
mover's contacting face straight down the contact normal using the traceable's existing
`trace_segment`. That answers exactly the question the clip was going to ask — "is there
surface under this corner, and how far down" — and it answers it for all four
implementors at once, with no per-traceable work and no churn on the swept path that
players move on.

It also solves the plan's own open question better than the clip would have. Clipping the
mover's face to a contact plane holds an OVERHANGING body up on nothing; a probe finds
nothing under a corner past a ledge and drops it. `test_corners_over_a_ledge_are_not_reported`
pins that: a box astride the edge of a BSP floor brush reports two points, not four.

The cost is one short point-trace per face corner per resting contact.

## Deviation 2: none — the capsule got its two points everywhere

14e's two-point capsule manifold works against a solid partner's face
(`witnesses_against_face`) **and** against a traceable (`manifold_for_traceable`), so a rod
lying on level geometry is held at both ends of its spine.

This was briefly disabled for traceables on a wrong diagnosis, and the correction is worth
recording because the real cause was a bug elsewhere. A rod on a BSP floor sank and span at
2.5 rad/s, and that was read as the probe mismeasuring a curved surface. It is not: the
probe is EXACT, verified against ground truth from 2 mm clear to 5 mm penetrating, error
0.00000 at every depth. What was actually wrong is in the next section.

Rolling resistance (the other half of 14e) shipped in full and is on for every shape:
`coefficient_of_rolling_friction_`, defaulting to 0, applied once per tick from the
converged normal impulse and clamped so it can only remove spin.

```
capsule dropped on a floor, 15 s, at four tilts     before        after
  BSP floor (traceable), level                      asleep        asleep
  BSP floor (traceable), 20 / 60 / 85 deg           |w| 1.5 fixed  ASLEEP, |w| 0.000
  aa_box floor (solid),  level                      |w| 19.5      ASLEEP, |w| 0.000
  aa_box floor (solid),  20 / 60 / 85 deg           |w| 21-22     ASLEEP, |w| 0.000
```

Before the phase a capsule dropped on a floor NEVER came to rest unless it happened to
land already level on a traceable; it held 19-22 rad/s indefinitely on a solid and drifted
up to 1.3 m doing it. That is `plans/rotating_gibs.md` bug 2, and it is closed.

## The pair is built from the richer side

Found while chasing the capsule, and it is the subtler half of the phase.

Both bodies of a contact discover it independently, and **they need not agree on how many
points it has**. A capsule resting on level geometry clips to two points from its own side
while the geometry's side of the same contact is a single one; a body whose partner cannot
produce a manifold at all is the ordinary case. `solve_contacts` built the pair from
whichever side the iteration happened to reach first — and since `update()` flips the
traversal order every tick, the row count for one physical contact ALTERNATED between two
and one, tick after tick. A contact that is two rows on one tick and one row on the next
cannot hold anything still.

The build loop first deferred to the partner when the partner's slot was fresher in
points, unbuilt this tick, and its owner awake (so its slots would actually be walked).
One line of predicate; it is what made the capsule path work, and it is a correctness fix
independent of capsules.

**Superseded — see "One manifold per pair" below.** The disagreement it arbitrated was
itself a bug: the generator answered for whoever asked rather than for the pair. Both
sides now hold the same points, and the build loop picks between them by a rule
(richer, ties to `a`) that reads nothing about traversal order or sleep state.

## One manifold per pair

The two sides of a contact did not merely differ in COUNT, they were separately generated:
each body asked `manifold_for_solids` with ITSELF as the mover, and the dispatch inside
picked its branch from whichever shape arrived first. Measured asymmetries: a rod resting
under a slab reported **two points asked from the capsule's side and none asked from the
box's** (`clip_manifold` wants two faces and a capsule has none), and a traceable could
only ever be the partner, never the mover. Two disagreeing answers to one question, which
the solver then had to arbitrate — with a float comparison pairing each row to "the
partner's nearest point", and with four rows able to alias onto one partner slot when the
counts differed.

The generator now orders the two solids by `solve_id` before it does anything else and
answers for the PAIR: each shape-pair case is written once and the roles are swapped into
it (a traceable is probed whichever side it sits on; a capsule brings witnesses and the
polytope brings the reference face). A caller whose own solid sorts second gets the same
points back with the normals reversed. Then, in the discovery pass, whichever body reaches
the contact second MIRRORS the first's points instead of clipping its own — so the two
touch slots hold the same manifold, in the same order, under the same feature ids, and the
solver pairs rows to partner points by ID. Only the lever arms stay per-side, since each is
measured from its own body's swept centre.

It did NOT move the dynamic-stack regression below (0.800 m -> 0.799 m of walk over 20 s),
which is worth stating plainly: asymmetric rows between two free bodies looked like the
right shape for a slow walk and is not the cause.

## The known regression: a stack of DYNAMIC bodies

**A stack of dynamic boxes resting on each other walks itself apart over ten to twenty
seconds, where the single-point contact held it indefinitely.** It is characterised below
in enough detail that whoever picks it up does not have to re-derive any of it.

### The mechanism: two independent quantities, and both matter

It is tempting to read this as one bug. It is two, multiplied together.

**The ramp** is the resting tilt, and it comes from the slop band being a DEAD ZONE with
no restoring term. A manifold point's velocity target becomes 0 once its gap is within
`spec_slop_`, and `correct_positions` only corrects penetration BEYOND the slop. So a body
does not have an equilibrium, it has a continuum: any pose whose four gaps all fall inside
the band is stable, tilted ones included. Measured, the resting separations sit at exactly
+-slop, which for a 0.2 m box on a 1 mm slop is ~0.01 rad off level.

**The walk rate** is how fast the body above travels down that ramp, and it is
proportional to the solver's per-tick residual. Because the creep is a ROLL about
alternating edges rather than a slide, the contact never slips and friction has nothing to
oppose — verified at mu = 50, which changes nothing.

The two are cleanly separable in measurement. Sweeping the iteration budget for two equal
boxes moves one and not the other:

```
two equal boxes, bottom box at 10 s
  iters 16 -> tilt 0.0112   drift 0.0499     <- walking
  iters 20 -> tilt 0.0104   drift 0.0251
  iters 24 -> tilt 0.0102   drift 0.0137
  iters 28 -> tilt 0.0101   drift 0.0084
  iters 32 -> tilt 0.0000   drift 0.0001     <- asleep
```

The tilt is FLAT at ~0.010 rad across the whole range — no iteration count touches it,
because it is geometry, not convergence. The drift falls as 1/iterations. And the snap to
zero at 32 is not convergence finally arriving: it is the residual dropping below the sleep
threshold, so the body sleeps before it can walk anywhere. Raising the budget is
mitigation-by-sleep, not a cure.

A mass ratio of roughly a half is the trigger. At 16 iterations a top/bottom ratio of 0.4
is stable and 0.6 walks.

### Neither lever alone is enough; together they reach depth 3

```
depth 3, final y (want 0.1 / 0.3 / 0.5)
  iters 16, slop 1e-3 (today)   0.100  0.101  0.101   collapsed
  iters 16, slop 1e-5           0.100  0.100  0.100   collapsed
  iters 32, slop 1e-5           0.100  0.100  0.100   collapsed
  iters 64, slop 1e-3           0.099  0.106  0.159   collapsed
  iters 64, slop 1e-4           0.100  0.300  0.500   HOLDS
```

Shrinking the slop alone does not fix it at any value tried (down to 2e-5), and raising the
iteration budget alone does not fix it at any count tried. Both together, and it holds
perfectly. That is exactly what the two-quantity model predicts: shrink one and the other
still gets the body to the edge eventually.

### ...and there was a third problem behind both, at depth 4 — it was shock propagation

Originally recorded here as a cliff that failed at every combination tried:

```
  NB=4, iters 64, slop 1e-4, shock 2 / 8 / 32   all collapsed
  NB=5, iters 128, slop 1e-5                    collapsed
```

...with the note that **shock propagation makes no measurable difference at all**, flagged
as the cheap lead to pull first. Pulled, 2026-09-16, and the note was wrong: every sweep
above held shock at its default of 2 and varied everything else. **Nobody tried 0.** The
phase is not inert, it is the wrecking ball:

```
  worst y error after 20 s        shock 2            shock 0
  two boxes,  16 iters / 1e-3     0.200  toppled     0.0014  a stack
  four boxes, 64 iters / 1e-4     0.600  collapsed   0.0003  holds
  five boxes, 128 iters / 1e-5    0.800  collapsed   0.0001  holds
```

So there is no third problem: the depth-4 cliff WAS the shock phase. One pass is enough to
cause it. Ordering is not it (reversing the walk on alternate ticks, the way the GS sweeps
flip, changes nothing) and neither is the half-freeze that still torques a frozen anchor
(zeroing its angular response too changes nothing). Magnitude is: under-relaxing the shock
impulse 16x recovers the shock-off numbers exactly.

The cause is an assumption the phase makes. Freezing the anchor means a row solves as if
the free body's whole weight bore on it ALONE — right for one point carrying one load path,
N times over-driven for a manifold, whose coplanar rows sit at different lever arms, so the
excess lands as torque rather than lift. And a manifold needs none of it: spreading one
contact's load across the surface is what shock propagation exists to arrange in a pile of
point contacts, and a manifold arrives with that already done.

Fixed in hop PR #97 — `contact_pair` carries the authoritative slot's `point_count`, and
the shock walk skips any row that is one of several. Better than sharing the load across
the rows (`eff_shock *= rows`), also tried: that recovers two boxes but not four at 64/1e-4.
The 6859-ball pile the phase was added for is every-contact-single-point and is identical
to the digit; `demo_ragdoll` improves (106/168 bones asleep at rest against 96, resting cost
for 8 corpses 0.405 -> 0.297 ms/tick).

What this does NOT fix: the ramp and the residual are untouched, so the shipping 16 iters /
1 mm slop still loses a stack three boxes deep. Soft contacts remain candidate 1.

### What is left, re-measured after the shock fix

The two-quantity model in this section was measured with the shock phase running, so it is
worth restating post-fix. The RAMP is confirmed and is exactly geometric — resting tilt of a
loaded box against slop, at 32 iterations so it is fully settled:

```
  slop 4e-3 -> 0.0378 rad     2*slop/width = 0.040
  slop 2e-3 -> 0.0202                        0.020
  slop 1e-3 -> 0.0103                        0.010
  slop 5e-4 -> 0.0053                        0.005
  slop 1e-4 -> 0.0012                        0.001
```

`2 * slop / width`, across a 40x range. But the claim that BOTH quantities have to shrink is
now wrong: the ramp can stay at its full 0.0103 rad and the stack still holds, because a
ramp only moves something that has residual velocity to spend. **The walk is the solver
residual alone.** With sleep disabled to isolate convergence from mitigation-by-sleep:

```
  depth   iterations to stop walking (slop 1e-3)
    2        32
    3        64
    4       128
    5       256
    6       512
```

Those same budgets hold with sleep on, at the shipping 1 mm slop: 0.0001 / 0.0009 / 0.0012 /
0.0012 / 0.0022 m of error after 20 s. So the slop never had to shrink at all (depth 3 holds
at 64 iterations and 1 mm, where this plan says it needs 64 AND 1e-4), and "raising the
budget is mitigation-by-sleep, not a cure" is no longer true — it is a cure, at 2x per
layer, against a shipping budget of 16. Two boxes need twice what they get and survive only
because they sleep first; three do not and are off in under five seconds.

### What was ruled out, so nobody re-treads it

(`shock_iterations` at 2, 8 and 32 was on this list and has been taken off it — see above.)

Each of these was implemented or swept and measured to make no difference: friction
(mu to 50); the NGS position pass entirely (`pos_iterations = 0`); warm-start seeding
(zeroed, and kept); **warm-start impulse APPLICATION**, Box2D/Jolt style, written and
tested — hop's design note says applying it would double-count, which is wrong since
gravity is re-added every tick, but applying it does not help either; the per-tick sweep
order flip; making the pair source deterministic (canonical `a` side) instead of
iteration-order dependent; generating ONE manifold per pair and mirroring it into both
sides, so the two never disagree (see "One manifold per pair" — a real bug, no effect
here); and `max_manifold_points` at 2, 3 and 4 — the plan's own dial does not help, all
three collapse.

### What the old stability actually was

A single contact between two boxes resolves at the FACE CENTRE, so it cannot torque either
body at all. That is why it never tipped. It was inertness, not stability.

Restricting manifolds to immovable partners does not help, and is worth recording because
it is the obvious thing to try: mixing a manifold under a body with a single point above it
is WORSE than either alone, because `support()` on a body whose contact normal is no longer
an exact axis snaps to a CORNER — so the moment the lower body acquires any tilt, the
contact above it gains a lever arm it does not have.

### The candidate fixes, honestly ranked

1. **Soft contacts** (Box2D v3 soft step / TGS Soft, Jolt spring settings) — replace the
   hard target plus dead zone with a spring-damper at a fixed frequency and damping ratio.
   Attractive because it is the one change that moves BOTH quantities: a restoring term
   everywhere kills the ramp, and better conditioning lowers the residual per iteration.
   Necessary, and on the evidence above not sufficient.
2. ~~**Block-solve the manifold's normal rows**~~ — TRIED IN THE SHOCK WALK, 2026-09-16,
   and it buys nothing for the stack. Three variants, all measured against the budget table
   below (iterations needed to stop walking, sleep off, slop 1e-3; skipping the manifold
   entirely is 32 / 64 / 128 / 256 / 512 for depth 2..6):
   - *Inner projected Gauss-Seidel over one manifold's rows*, so they agree on the load
     split instead of each driving the free body as if it carried all of it. Swept at 1, 2,
     4, 8, 16, 50 and 200 inner sweeps: **identical at every count**, and identical to one
     sweep. The rows disagreeing was never the mechanism.
   - *Linear-only per row* — answer torque-free, which is the property that made a
     single-point contact hold a stack. Best budgets anyone has got out of this: 16 / 32 /
     32 / 64 / 128. But it breaks the warm-start contract outright — 102 of 180 ticks churn
     the manifold's feature ids, because four rows each driving their own point's velocity
     with translation alone is an inconsistent system and they fight. That is the buzzing
     the whole phase exists to remove, so the budget was bought by half-reverting to
     pre-manifold behaviour.
   - *One aggregated row* (mean normal velocity to mean target, one linear impulse shared
     across the rows' accumulators) — consistent, ids stable 0/180, whole suite green. And
     the budget is **exactly the skipped one**, 32 / 64 / 128 / 256 / 512. It also costs the
     headline case unless paired with a further rule to leave contacts whose anchor was
     already immovable alone: a box on static geometry rests at 0.00957 rad rather than
     0.00000.

   The aggregate row genuinely does carry load to the floor, torque-free, and changes
   nothing. So the depth budget is **not limited by support propagation** — which is the
   one thing shock propagation exists to supply. It is limited by the tilt-and-roll
   dynamics, and that sends everything back to candidate 1.

   (The original note, for whoever wants the numerics: the diagonal is already `eff_n`, a
   manifold's rows are already contiguous in `contact_pairs_`, and for four coplanar points
   the block matrix is rank 3 and singular — not a physics problem, since `A = J M^-1 J^T`
   means a null-space lambda produces zero net wrench, but it needs a rank-tolerant solve, a
   diagonal compliance, or a cap at 3 points. Might still be worth doing for conditioning in
   the main GS loop. It is not a stack fix.)
3. **Raise `solver_iterations_`, or scale it with row count** — the default of 16 predates
   the manifold quadrupling the rows. Verified to fully settle a two-body stack, and worth
   doing regardless, but it works by reaching sleep sooner rather than by fixing anything.

### Why it is acceptable to ship, and the recommendation

Nothing in WizardWars reaches this path. A ragdoll's bones (`ragdoll_builder.gd:151`) and a
gib (`gib_effect.gd:131`) both carry `collision_mask = MASK_WORLD` and nothing else, so they
only ever rest on static geometry, which is where the manifold is an unambiguous win. The
only bodies that could stack on each other are satchels and rolling stones, and both are
SPHERES — a sphere gets one point plus rolling resistance and never a manifold at all.

So the recommendation is to do none of it yet. If a feature ever needs dynamic bodies
stacking: soft contacts first, and measure. The depth-4 cliff that used to be listed here as
a separate investigation is closed — it was the shock phase (above).

`tests/test_manifold.cpp` REPORTS the five-box stack rather than asserting on it, so the
number moves in plain sight the day it is fixed; it asserts only that nothing is pushed
through the floor. The two-box stack DOES assert, since the shock fix holds it.

## Things the plan got wrong, found on the way

- **"The NGS position pass already handles rotation, via `rot_correction_`."** It did not:
  `rot_correction_` was written only by the rigid-joint rows, and the contact pass was
  translation-only. It has one now — a pseudo-impulse at the contact's lever arms — which
  is right for a manifold (a corner 3 mm deep wants TURNING out, not shoving) even though
  it turned out not to be what the stack needed.
- **"Restitution is precomputed per pair from `impact_speed`."** It is precomputed from
  `vn0`, and `impact_speed` explicitly must not drive it (there is a comment saying so).
  Since each manifold point becomes its own pair, per-point restitution came for free and
  no work was needed.
- **"`body->sleeping` is write-only and must start reporting."** It has mirrored
  `!hop_solid->active()` since February (`hop_body_data.cpp:81`), and
  `HopDirectBodyState::_is_sleeping` reads it, so Godot already saw it. What WAS
  write-only and is now wired is `can_sleep`: a body Godot says must stay awake is pinned
  with `set_stay_active`, which mattered for the first time once bodies actually slept.
- **"Table 2's corpse will sleep."** It does not, and contacts are not why. What is still
  turning at ten seconds is bones touching NOTHING: on a pin-only corpse the neck sits
  between two coincident ball-sockets and swivels at a perfectly steady 12.5 rad/s with
  nothing to damp it (correct physics for a frictionless chain), and on a limited corpse a
  limb pinned under the torso is outside its cone and cannot get back in, so the
  velocity-level recovery fires, is refused by the contact in the way, and fires again —
  which Phase 13 already recorded as permanent. Whole-corpse sleep is a JOINT problem.
  Table 3's sleeping-bone count (90/168, from 0/168) is the measurement that moved.

## Two fixes that fell out and are independently correct

- **`solid::deactivate()` now zeroes angular velocity.** The sleep test tolerates ω up to
  `deactivate_speed_`, so a body that settled while still turning froze that turn and read
  as moving forever. Until resting bodies could sleep at all, the residual had no way to
  show.
- **A SLEEPING joint endpoint is an anchor.** `build_joint_rows` zeroes its inverse mass
  and its spin response, as `correct_positions` and the shock phase already did. Without
  it a corpse lay still with bones hop had decided were asleep turning at 2.5 rad/s
  inside it — unreachable before, because nothing slept.
- **`solve_contacts` wakes a body on SPIN as well as translation.** A contact can torque a
  sleeping body without shifting it.

## Tests

- `hop/tests/test_manifold.cpp`, compiled **twice** — once at `max_manifold_points = 4`
  and once at 1. The parity build is the proof that the storage change is pure plumbing:
  at one point per partner the engine reproduces the pre-phase numbers exactly (the demo
  control table reads 5.2088 / 1.3259 / 0.3200 again, to the digit).
- `hop-godot/tests/test_bsp_traceable.cpp`: a tilted box on a BSP floor gets four points
  and sleeps; corners over a ledge are not reported.
- `hop-godot/tests/test_trimesh_traceable.cpp`: a box astride a mesh seam is held at four
  points and sleeps.
- `demo_ragdoll` asserts the control table is zero, that every control box sleeps, that
  resting does not cost more than 1.3x falling, and that at least a third of a pile's
  bones are asleep at rest.
- 16/16 hop tests, 3/3 hop-godot tests, 3552/3552 WizardWars tests.

## Not done from the plan

- `max_touches` is unchanged at 12, as the plan intended.
- `manager.h`'s doc comment was not annotated as single-contact-by-design.
- `demo_pile` / `demo_settling` were not run (they are interactive raylib demos); the
  headless stack tests above cover the same ground and are what found the regression.
