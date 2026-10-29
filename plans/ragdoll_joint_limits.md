# The corpse folds into a heap

> **Status: SHIPPED.** hop Phase 13, the hop-godot wiring and the builder's table are all in.
> A dead wizard lands with his head 0.57 m from his pelvis where a pin-only corpse folded to
> 0.36 m, and settles sooner than the pin-only one did (`demo_ragdoll`, Table 4). Three things
> below did not survive contact with the code — one of them the plan's central claim about
> which solver pass matters. See *What actually shipped* at the end, and read it before
> trusting the body of the plan.
>
> This is the phase `plans/one_corpse_ragdoll.md` deferred, in the exact terms it deferred
> it: *"Pin joints only to start — knees bending backwards is acceptable; we look at it
> first and add angular limits to hop only if the look demands it."* It was looked at. It
> demands it. Read that document first; this one assumes the ragdoll it built.

## What is actually wrong

Nothing is broken. A pin is a **ball-socket: it constrains position and nothing else.** Its
two anchors are held coincident and no part of the constraint says a word about relative
*orientation*, so each of the corpse's twenty joints is a free 360° swivel. A neck folding to
the knees satisfies every constraint in the system. The pins themselves are holding to a mean
0.0063 m (`demo_ragdoll`, Table 1) while the body they hold collapses.

Two things compound, and they need separating because only one of them is this phase:

1. **No angular limits.** The fold itself. Everything below.
2. **No self-collision.** Bones are `collision_layer = 0`, `collision_mask = MASK_WORLD`
   (`src/systems/ragdoll_builder.gd:76-77`), so a limb passes through the torso as well as
   through every other limb. Nothing geometric resists the fold either. See *Not this phase*.

**The trap, up front:** you cannot fix this by changing one line in the builder.
`phys.joint_type = PhysicalBone3D.JOINT_TYPE_CONE` today produces a corpse that comes apart
completely, because `HopPhysicsServer::_joint_make_cone_twist`
(`extern/hop-godot/src/hop_physics_server.cpp:1945`) is an empty `{}` — it creates **no joint
at all**, not a worse one. The work goes into hop first.

## hop Phase 13 — swing and twist limits

hop's `docs/rotation_plan.md` runs Phases 1–12, all shipped. This is the next one, and it is
the smaller sibling of Phase 12: the machinery a limit needs — per-tick joint rows, a solver
sweep interleaved with contacts, and a position-level pseudo-impulse channel that can *rotate*
a body (`solid::rot_correction_`) — all went in with the rigid pin. What is missing is the
angular constraint itself.

**1. A limit is a contact, not a joint.** This is the framing that makes the rest fall out. A
cone limit is *unilateral*: inside the cone it does nothing at all, and at the boundary it
pushes back and never pulls in — exactly the semantics of a contact normal, down to the
clamped accumulator (`accum >= 0`) that stops it becoming sticky. Do not model it as a second
bilateral constraint fighting the pin.

The other half of the framing: a limit's impulse is **pure torque, no linear component**. So
it cannot disturb the pin's position constraint no matter how hard it pushes, and a limited
joint is a pin plus a torque — not a different kind of joint. Assert that in the tests (the
pin error must not grow when a limit engages).

**2. Store the limits on the pin, not beside it.** Add to `constraint<T>`
(`include/hop/constraint.h`, alongside `bias_`/`impulse_clamp_` at :222), read only when
`type_ == rigid`:

- `frame_a_`, `frame_b_` — the joint's rest frame in each body's local space (`mat3<T>`, or
  `quat<T>`; the solver wants a quaternion). The joint is satisfied when `R_a·frame_a` and
  `R_b·frame_b` coincide.
- `swing_span_`, `twist_span_` — radians. **Negative means no limit**, which keeps
  `_joint_make_pin` a limit-free rigid and every existing caller bit-identical.
- `limit_bias_`, `limit_softness_`, `limit_relaxation_` — Godot's three cone-twist knobs
  (see item 5).

A cone-twist *is* a ball-socket plus limits. Splitting them into two constraint objects would
double the rows and make them fight over the same bodies.

**3. Swing–twist decomposition, once per tick in `build_joint_rows`**
(`include/hop/simulator.h:2048`). Everything here is fixed for the solve, like `K` is:

```
q_rel   = inverse(q_a · frame_a) · (q_b · frame_b)   // child frame, in the parent's joint frame
q_twist = normalize(quat(q_rel.w, q_rel.x, 0, 0))     // projection onto the twist axis
q_swing = q_rel · inverse(q_twist)                    // what is left is perpendicular to it
swing   = 2·atan2(|q_swing.xyz|, q_swing.w),  axis ⊥ twist by construction
twist   = 2·atan2(q_twist.x, q_twist.w)
```

**Twist axis is the joint frame's local +X**, matching Bullet and therefore Godot, so the
editor gizmo and any Jolt/GodotPhysics comparison agree with us. `quat.h` already has
`invert`, `mul`, `normalize_carefully` and `get_axis_angle_from_quat` (:186, which uses
`2·asin(|xyz|)` and is the accurate branch near identity); `scalar_traits` has `asin`/`acos`/
`atan2` for float, double **and** fixed16/fixed32 (polynomial, from toadlet).

Store on the row, per limit: the violation angle (0 when inside) and the world-space axis to
push about. Two possible rows per joint, swing and twist, and usually neither fires.

**4. Solve it in the sweep that is already there.**

- *Velocity*, in `solve_joints` (`simulator.h:2133`) right after the pin's 3-DOF solve, so the
  limit sees the pin's answer: drive the relative angular velocity along the violation axis to
  zero, `λ = −(ω_rel·axis) / (axis·(Iₐ⁻¹ + I_b⁻¹)·axis)`, accumulate and clamp `≥ 0`, apply as
  `ω_a −= Iₐ⁻¹(λ·axis)` / `ω_b += I_b⁻¹(λ·axis)`.
- *Position*, in the joint block of `correct_positions` (`simulator.h:1614`): the same
  unilateral push as a pseudo-rotation into `rot_correction_`, by `violation · limit_bias_`,
  split by inverse inertia. **This is the half that matters for the look.** The velocity solve
  stops a limb accelerating past its limit; only the position pass stops one *resting* past it,
  and a corpse on the floor is nothing but limbs resting.

**5. Honor Godot's three knobs, the way Phase 12 honored the pin's.** `SWING_SPAN` and
`TWIST_SPAN` are the spans. `BIAS` → the fraction of the violation the position pass removes
per iteration (the `limit_bias_` above). `SOFTNESS` → the fraction of the span at which the
limit begins to engage rather than switching on hard at the boundary — Bullet's meaning, and
what makes a limit read as flesh instead of a detent. `RELAXATION` → a scale on the velocity
impulse. Wire all three; `_cone_twist_joint_get_param` must answer with what was set.

**6. Sleep, and the trap in it.** `constraint::is_loaded` (`constraint.h:167`) decides whether
a body may deactivate. A joint **resting on its limit is like a body resting on a floor: it
must be allowed to sleep.** So the limit contributes to `is_loaded` only while the violation
exceeds tolerance, never merely because a limit is engaged. Get this wrong and every corpse
with an arm against its stop stays awake forever — and corpses already cannot sleep for an
unrelated reason (see *Risks*), which would hide it.

**7. Explicit non-goals.** `_joint_make_hinge`, `_joint_make_slider` and their `*_set_param`
siblings stay empty (`hop_physics_server.cpp:1936-1944`). A cone centred off the rest pose
approximates a hinge well enough for a corpse — see *The game side*.
`_joint_disable_collisions_between_bodies` (`:2040`) still stores a flag nobody reads.

**Where the work lands:** `include/hop/constraint.h` and `include/hop/simulator.h`; tests in
`tests/test_simulator.cpp`; `examples/demo_ragdoll.cpp` gains the limited corpse.

## hop-godot

`_joint_make_cone_twist` (`src/hop_physics_server.cpp:1945`) builds a `rigid` constraint like
`_joint_make_pin` does, taking the anchors from `p_local_ref_A/B.origin` and the frames from
their bases, then pushes the spans and knobs from `HopJointData`. `_cone_twist_joint_set_param`
/ `_get_param` store and forward, on creation and on every later set, because Godot sets params
after making the joint (the same shape as the pin fix). `HopJointData`
(`src/hop_joint_data.h`) gains `cone_swing_span` / `cone_twist_span` / `cone_bias` /
`cone_softness` / `cone_relaxation` with Godot's defaults — **45°, 180°, 0.3, 0.8, 1.0**,
verified out of the engine, and note that Godot hands the spans over in *radians* while the
node's inspector shows degrees.

## The game side

`src/systems/ragdoll_builder.gd:69` becomes `PhysicalBone3D.JOINT_TYPE_CONE` (which is enum
value `2`; the node's name for it is `CONE`, not `CONE_TWIST`), plus a per-joint table.

**The bone axis is free.** GoldSrc bones run down their own local **+X** — the hitbox dump
shows it plainly, every limb box spanning x from ~0 to its length (thigh 0→18.6, forearm
0→11.2) — and the importer's GoldSrc→Godot swizzle `GS(x,y,z) → Godot(x, z, −y)` leaves X
alone. The twist axis is +X. So the cone already points down the bone with
`joint_offset.basis` left at identity, and the builder does not need a per-bone axis.

**Aim the cone at the middle of the arc, not at the rest pose.** A cone-twist is symmetric and
an elbow is not — a knee bends one way, 0° to about 120°. Rotating the joint frame so the cone
is *centred at 60°* with a 60° span and near-zero twist gives a one-sided hinge out of a
symmetric primitive. This is what `joint_offset.basis` is for and it is the difference between
a corpse with legs and a corpse with tentacles.

A starting table, keyed on the `Bip01` bone name (all six element models share the rig, so one
table covers them), swing / twist in degrees:

| bone | swing | twist | note |
|---|---|---|---|
| Pelvis | — | — | free root, no joint |
| Spine, Spine1, Spine2, Spine3 | 15 | 20 | four segments, so a little each is a lot together |
| Neck | 30 | 30 | |
| Head | 45 | 40 | |
| L/R Arm (clavicle) | 20 | 15 | |
| L/R Arm1 (shoulder) | 80 | 60 | the loosest joint in a body |
| L/R Arm2 (elbow) | 60 | 10 | cone centred ~60° off rest — one-sided |
| L/R Hand | 45 | 30 | |
| L/R Leg (hip) | 60 | 30 | |
| L/R Leg1 (knee) | 60 | 5 | cone centred ~60° off rest — one-sided |
| L/R Foot | 35 | 15 | |

Numbers to start an argument with, not to trust. They are tuned by watching.

## Order of work

1. **hop Phase 13**, developed against `demo_ragdoll.cpp` and unit tests, entirely inside hop.
   The long pole, and independent of everything below.
2. **hop-godot**: wire `_joint_make_cone_twist` and its params.
3. **The builder's table**, and switch the joint type.
4. **Tune by watching**, which is the only way this gets finished. Judge it on the *baked*
   pose, not the live one — see *Risks*.

## Tests and the demo

- `test_cone_limit_holds` — a two-body joint with a 30° cone; gravity folds the child; the
  swing angle never exceeds 30° plus tolerance, and the *pin* error does not grow while the
  limit is carrying load (item 1).
- `test_twist_limit_holds` — spin the child about +X past its twist span; it stops there.
- `test_limit_is_unilateral` — a body moving freely *inside* its cone behaves exactly as it
  does on a plain pin. Bit-identical is the bar: a limit that is not engaged must cost nothing
  and change nothing.
- `test_joint_on_its_limit_sleeps` — item 6, and the one most likely to be got wrong.
- `demo_ragdoll.cpp` gains the limited corpse and reports **worst swing/twist violation** and a
  pose sanity number — dropped on its feet, the head must end up above the pelvis. That last
  number is the one that actually answers "does it look like a body".

## Not this phase

**Self-collision.** With limits in place a corpse should stop folding, but a limb can still
*sink into* the torso, because every bone is on layer 0. Fixing it properly needs per-pair
exclusion so a bone does not fight its own parent through the joint, and hop has none —
`_joint_disable_collisions_between_bodies` is a stored flag nobody reads. The cheap
approximation, if it proves necessary: put the torso chain on one layer and only the *ends* of
each limb (hand, foot, head) on a mask that sees it, so nothing adjacent ever pairs. Do this
only after watching a limited corpse, because limits alone may well be enough.

## Risks, and what to measure

- **A corpse still cannot sleep, and it is not this phase's fault.** See
  `hop_resting_box_spin`: an oriented box resting on a floor spins forever in hop, so the bones
  shiver regardless of what the joints do. `TumblingCorpse` stops them on a timer
  (`SETTLE_WINDOW` / `MAX_SIM_TIME`) and bakes the pose. **Tune the limits by looking at the
  baked pose**, or the shiver will be blamed on the joints.
- **Sleep regression** is the specific thing to watch in hop's own suite — item 6. hop's
  `test_rigid_joint_sleeps` must keep passing, and it will not catch a limit that reports
  loaded forever, hence the dedicated test.
- **Fixed-point.** The decomposition is more trig than hop does anywhere else. `asin`/`acos`/
  `atan2` exist for fixed16/fixed32 as polynomials, but the game's space is `float`
  (`hop_conversions.h`), so fixed is a correctness-of-the-port question, not a shipping one.
  Instantiate it in the tests; do not tune against it.
- **Twenty more rows per corpse.** Eight awake corpses already cost ~4.5 ms/tick
  (`demo_ragdoll`, Table 3) against a ~6.5 ms budget, which is survivable only because they are
  baked after a few seconds. Limits add up to two angular rows per joint, and most of them are
  inactive most of the time — measure it in Table 3 before assuming that is free.

## What actually shipped

The framing held. Three specifics did not.

**1. A one-sided cone is not available through `PhysicalBone3D`, and `joint_offset.basis` is
not what it is for.** `_reload_joint` builds *both* rest frames out of one world transform —
`joint_transf = global * joint_offset`, then `local_a = parent.global⁻¹ * joint_transf` and
`local_b = joint_offset` — so rotating `joint_offset.basis` rotates both halves together and
the relative rest orientation is identity no matter what. A cone here is always symmetric
about the pose the ragdoll was BUILT in, and that turned out to be the useful half of the
finding: the corpse now receives the dying wizard's bone rotations in its spawn payload and
poses the skeleton *before* building on it, so every cone centres on the death pose for free.
The asymmetry the plan wanted is still unavailable, but the thing it wanted asymmetry FOR —
limits that make sense for the pose the body is actually in — largely falls out of this. So the elbow and knee spans in the table above
were halved instead: a knee gets 45° of bend and 45° of hyperextension rather than 60° of
bend and none. Getting the asymmetric version would need a joint hop does not have and
frames Godot would not hand it.

**2. The position pass cannot do this job alone on a chain, and that is not a tuning
problem.** It moves the two bodies of one row; putting a clavicle back inside its cone means
moving the whole arm hanging off it. Measured, the pin to the arm cancels the push exactly
and a shoulder sits **140° outside a 20° cone forever**. So a violated limit also recovers in
the VELOCITY sweep, at up to 12 rad/s, the way a speculative contact's separation does — an
impulse propagates down a chain through the pins and a pseudo-position does not. The position
pass stays, clamped to ~3° per iteration, because `rot_correction_` is a *small-angle*
rotation and every reader of it (the pin's own anchor term included) uses `R(δ)·r ≈ r + δ×r`;
shoving a limb back a hundred degrees in one iteration makes that a lie, the pins read the
lie, and the corpse comes apart at the wrists while the limits look like they are working.

**3. There is no position pass at all, and the plan's item 4 has it backwards.** The plan
said the position pass is "the half that matters for the look", because only it stops a limb
*resting* past its limit. It is the half that made the corpse writhe. A pseudo-position
cannot be refused: a forearm pinned under a torso against the floor is outside its cone and
physically *cannot* get back in, so the position pass re-corrected it every tick forever and
teleported the corpse a couple of centimetres a tick while it did. Over 32 thrown corpses
that was 0.20 m of crawl per half-second against a pin-only corpse's 0.035 m, and two in
twelve ever came to rest — a corpse snaking on the ground until the game's bake timer
stopped it. A velocity impulse *can* be refused by the contact that is in the way, which is
exactly the property wanted, and it also propagates down the chain through the pins where a
pseudo-position does not (that is the 140° clavicle in item 2). So the limit is solved at the
velocity level and nowhere else. Deleting the position pass took the crawl to 0.025 m —
*below* the pin-only corpse — and left the joints no worse held.

On the way to finding that out, two things were tried and rejected, both recorded here so
they are not tried again. **Angular damping on the bones** (which hop lacks entirely —
`BODY_PARAM_ANGULAR_DAMP` is stored and ignored): it does not touch the crawl, because the
spin driving it is re-injected fresh every tick by the corner each bone balances on rather
than accumulated, and at useful strengths it eats the limit's own recovery and the joints
drift open. **Tuning against one drop:** a ragdoll on a floor is chaos, and a single corpse's
settle time swings by seconds on a change that means nothing. Table 4 runs 32 corpses thrown
32 different ways and reports the mean; every number above comes from that.

And one trap worth the line it takes: **the violation axis must point the way the violation
is RELIEVED**, like a contact normal. Point it the way it grows, which reads more naturally,
and every restoring impulse comes out negative, the `accum >= 0` clamp eats all of them, and
the limit silently does nothing at the velocity level at all.

*Self-collision is still not done*, and after watching a limited corpse it is still not
obviously needed.
