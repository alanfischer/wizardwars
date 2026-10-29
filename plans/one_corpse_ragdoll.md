# One corpse, ragdolled

> **Status: built.** All six steps shipped. `src/corpse.gd` is gone, `TumblingCorpse` is the
> only corpse in the game, and a dead wizard is a 21-body ragdoll built from the model's own
> MDL hitboxes. hop grew `constraint<T>::type::rigid` as Phase 12 (hop #90, hop-godot #51).
> Read the rest of this document as the design it was; **What actually happened** at the
> bottom records where reality differed, which is mostly one place and it matters.
>
> **Since then:** a third `kind` (MONSTER — a shot-down dragon, same rigged corpse on a
> longer clock), and a death big enough leaves no corpse at all — over
> `GameConsts.GIB_DAMAGE` the body bursts instead. `main._spawn_corpse` is now
> `main._spawn_remains`, which is where that fork lives.
>
> **Direction: the weight goes in hop, not in wizardwars.** The game side builds
> `PhysicalBone3D` bodies from the model's own MDL hitboxes and calls
> `physical_bones_start_simulation()`. Everything that makes that *look* right is a hop
> phase. Pin joints only to start — knees bending backwards is acceptable; we look at it
> first and add angular limits to hop only if the look demands it.

## What we have now — two classes that barely overlap

| | `src/corpse.gd` (`Corpse`) | `src/weapons/tumbling_corpse.gd` (`TumblingCorpse`) |
|---|---|---|
| spawned by | `main._spawn_corpse`, off `RemotePlayer._die` / offline `LocalPlayer` | `SkullProjectile` only |
| body | capsule r0.3 h1.0 at y+0.5, `lock_rotation = true`, `can_sleep = false` | sphere sized to the model, free rotation, `angular_damp = 2` |
| layer | `MASK_CORPSE` on the host, `0` + `freeze` on clients | `0` on **both** sides, never frozen |
| pose | one of six `die_*` clips, replicated as `NetInterp:net_anim` | `AnimationPlayer.stop()` — frozen mid-flap |
| lifetime | `LINGER 60` + `FADE 2` | `LINGER 2` + `FADE 0.6` |
| gameplay | `add_to_group("corpses")` — the body Grimfeast eats and Raise Dead takes | none, cosmetic |
| extras | death sound, element model, `BlobShadow()` | `model_yaw`, `strip_hitboxes`, hand inertia, `BlobShadow(0.25)` |

Two bugs fall out of that table regardless of the ragdoll:

- **`TumblingCorpse` has the double-simulation bug `Corpse` was already fixed for.** It never
  freezes on the client and never zeroes its layer, so every replica runs its own gravity
  while `NetInterpBridge` writes the authority's transform on top. It goes unnoticed only
  because a skull corpse lives two seconds.
- **Layer `0` means movers can't wake it.** `EntityBase._wake_touching_props`
  (`src/entities/entity_base.gd:119`) queries `MASK_DYNAMIC | MASK_CORPSE`; a body on layer 0
  is invisible to a descending platform and floats.

## The wizardwars side, in full

This is all of it. One new file, one merged file, two retyped call sites.

**`src/systems/ragdoll_builder.gd` (new, ~70 lines).** The MDL already ships the ragdoll:
`models/player/fire.mdl` is 22 bones, `Bip01`-named, with **21 hitboxes** — one per bone except
the root — each an axis-aligned box in bone-local space. The importer already turns every one
of them into a `BoneAttachment3D` + `Area3D` + `BoxShape3D` with the GoldSrc→Godot swizzle done
(`extern/goldsrc-godot/src/nodes/goldsrc_mdl.cpp:305-370`). The builder walks those, and for
each one creates a `PhysicalBone3D` under a `PhysicalBoneSimulator3D` child of the
`Skeleton3D`, carrying the same `BoxShape3D` size and offset, with:

- `bone_name` from the attachment's `bone_idx`
- `joint_type = JOINT_TYPE_PIN`
- `collision_layer = 0`, `collision_mask = MASK_WORLD` — world only, no self-collision, so
  limbs pass through each other and nothing in the game can be hit by a corpse's arm
- the hitbox `Area3D`s stripped afterwards (a corpse is not a hitscan target)

No joint wiring by hand: `PhysicalBone3D` finds its parent by walking *bone* parents to the
nearest bone that has one, and because bones 1–21 all have hitboxes, that resolves to the exact
skeleton hierarchy — pelvis as the free root, 20 joints below it. All six wizard element models
are the same rig, so there is no per-model table.

**`src/weapons/tumbling_corpse.gd` (merged).** Gains `raisable` (the `"corpses"` group —
a dead bird is not a body a necromancer can raise, so this is a spawn flag, wizards only),
`MASK_CORPSE`, the client `freeze` branch, the death sound, and configurable `linger`/`fade`.
Two shapes of corpse:

- **prop** (skull, and whatever grows a `spawn` call later): today's sphere and tumble, unchanged.
- **wizard**: no collider on the corpse node at all. The **pelvis `PhysicalBone3D` is the
  corpse's body** and carries `MASK_CORPSE`; the corpse node's transform mirrors the pelvis so
  `NetInterpBridge` publishes it and `global_position` still answers Grimfeast and Raise Dead.
  The model gets `top_level = true` — one line, and the reason the skeleton can live in world
  space where the physical bones put it while the node moves independently as the network
  reference.

Seeding the death: `RemotePlayer._die` already hands `death_velocity` to `_spawn_corpse`. Every
bone starts at that velocity plus a spin about the hit direction, so a wizard shot in the back
pitches forward. Any `randf` in the corpse path moves to a `RandomNumberGenerator` seeded from
a `"seed"` int in the spawn payload — see prediction below, this is load-bearing.

**Retyping.** `GrimfeastWeapon._find_target` returns `TumblingCorpse` and its `node is Corpse`
test becomes the group + `raisable` test; `target._expire()` becomes `_entity.destroy()`.
`SkeletonWeapon` is group-and-`Node3D` only and needs nothing; `src/tests/test_skeleton.gd`
builds its own stand-in and keeps passing.

## hop Phase 12 — rigid constraints

`extern/hop-godot/extern/hop/docs/rotation_plan.md` runs Phases 1–11, all shipped. This is the
next one. Four items; the first is the whole phase.

**1. A rigid pin, not a force spring.** `hop::constraint` is a *force* spring:
`constraint_force_on` (`simulator.h:1679`) computes `k·(|d| − rest) + c·v̇` along the anchor
separation, and `_joint_make_pin` (`hop_physics_server.cpp:1837`) builds one with `k = 100`,
`damping = 10`, `rest_length = 0`. It pulls anchors together; it does not *enforce* that they
coincide. A limb chain hung off that sags, and stiffening `k` to hide the sag is what makes an
explicitly-integrated spring chain ring and then leave.

The fix belongs where hop already does this kind of work. hop's tick is deliberately the reverse
of textbook order: positions integrate first (`update_solid`, gravity + the swept TOI snap), then
**Pass B** (`solve_contacts`, `simulator.h:570`) runs a post-integration Gauss–Seidel sweep that
fixes velocities, with an NGS position-correction pass for the speculative path
(`simulator.h:1475`). A rigid pin wants exactly that treatment:

- add `constraint<T>::type::rigid` alongside `spring` and `rope`. **Additive, not a
  redefinition** — hop's own demos and tests construct `type::spring` explicitly
  (`tests/test_simulator.cpp:1055,1100`), and nothing in wizardwars uses a joint today, so
  `_joint_make_pin` can switch to `rigid` with no existing caller affected.
- velocity level: per sweep iteration, drive the **full 3-DOF relative anchor velocity** to
  zero, mass-weighted, with the angular term through the inverse inertia. Every piece of that
  already exists from Phases 9 and 10 — `anchor_lever`, `anchor_velocity`, `add_torque`,
  `accumulate_constraint_torque`.
- position level: an NGS pass pushing the anchors together by the residual error, split by
  inverse mass. This is the part a force spring cannot do at any stiffness, and it is what
  stops the sag.
- **interleave joints and contacts in the same sweep**, sharing the iteration budget
  (`simulator.h:688`). A pinned limb whose parent is resting on a floor only converges if the
  joint and the contact are solved against each other; two separate passes fight.

**2. Honor the pin params.** `_pin_joint_set_param` (`hop_physics_server.cpp:1869`) stores
`BIAS`, `DAMPING` and `IMPULSE_CLAMP` and nothing reads them. Under Godot's semantics they map
cleanly onto the solver above: `BIAS` → the fraction of position error corrected per iteration,
`DAMPING` → relative-velocity damping, `IMPULSE_CLAMP` → per-iteration impulse cap. Wire all
three from the start; the clamp in particular is the safety valve that turns a solver blow-up
into a visibly floppy corpse instead of a body launched out of the map.

**3. Sleep — falls out of item 1, and that is the point.** Today the sleep rule keeps a body
awake while any of its constraints `is_loaded(epsilon_)` (`simulator.h:1204-1230`), and a soft
spring holding a limb up against gravity is *by definition* loaded: it needs a nonzero stretch
to produce the force. So a spring ragdoll never sleeps — 21 bodies × 20 springs per corpse, awake
for the whole 60-second linger, against hop's ~6.5 ms budget. A satisfied **rigid** pin has
near-zero positional error, so `is_loaded` reads false and the assembly deactivates normally.
Worth stating in the phase notes: whole-ragdoll sleep requires every bone quiet, because the
rule breaks out if any far endpoint is still active.

**4. Explicit non-goals.** `_joint_make_cone_twist`, `_joint_make_hinge`, `_joint_make_slider`
and every one of their `*_set_param` siblings are empty bodies returning 0
(`hop_physics_server.cpp:1916-1927`). **Leave them empty.** Angular limits become Phase 13 if
and only if watching a pin-only ragdoll says we need them.
`_joint_disable_collisions_between_bodies` (`:2017`) also stores a flag nobody reads — moot
here, since ragdoll bones are layer 0 and never pair with each other, but note it so the next
person doesn't assume it works.

**Where the work lands:** the solver in `extern/hop-godot/extern/hop/include/hop/simulator.h`
and `constraint.h`, a `type::rigid` case in `tests/test_simulator.cpp` (a two-link chain must
hold its length under gravity, and a jointed pair must reach `deactivate`), and a
`demo_ragdoll.cpp` next to `demo_gib_spin.cpp` — the gib work was debugged through exactly that
kind of demo and this will be too, well before a wizard ever dies in-game.

## Prediction and correction

The corpse is the best-case object for this, and it is worth being precise about why.

A corpse ragdoll is `collision_layer = 0`, `collision_mask = MASK_WORLD`: it collides **only with
static world geometry**, which is byte-identical on both peers, and it takes no input after
spawn. Its entire trajectory is therefore a pure function of its spawn state. Replicate that
state — position, velocity, model, and the RNG `seed` — and both sides run the same simulation
against the same world.

What "match" means, exactly: `hop_scalar = float` (`hop_conversions.h:31`). hop supports
`fixed16`/`fixed32` for bit-exact determinism and the substep count is deterministic
(`simulator.h:460`), but the game's space is float, and float is reproducible per
binary-and-architecture, not across the five shipped targets. So the two simulations *converge*;
they are not bit-identical. Hence the correction, and hence the shape of it:

- the host owns the pelvis. `NetInterpBridge` replicates the corpse node's transform exactly as
  it does today — **one** body's worth of traffic, unchanged. Per-bone replication is not on the
  table and does not need to be.
- clients stay `freeze`d with layer 0 on that node and interpolate it, as `Corpse` does today.
  That value is the authority's pelvis, and the client's reference.
- the client runs its **own** ragdoll from the replicated seed and compares its predicted pelvis
  against the reference. Past a threshold it corrects by **rigidly translating every bone by the
  delta**. A rigid offset of the whole assembly is the one correction operator that satisfies
  every joint exactly — nudging a single bone of a jointed chain fights the solver and is what
  makes ragdoll netcode look broken.
- gameplay never sees the divergence: `GrimfeastWeapon._find_target` and `SkeletonWeapon._harvest`
  read `global_position` and a `MASK_WORLD` ray, both authority-side. A limb resting two
  centimetres differently on two screens cannot desync anything.
- `net_anim` leaves the corpse entirely — with no `die_*` clip there is nothing to replicate, so
  `net_sync_properties()` returns empty and the corpse stops being an `AnimationPlayer` consumer.

## Order of work

1. **Fold the two classes** — no ragdoll yet. Wizard corpses get `lock_rotation = false` and a
   box collider and still play a `die_*` clip. `src/corpse.gd` deleted, `WW_CORPSE_PROBE` gone.
   Shippable and playtestable alone: corpses tumble down stairs instead of sliding rigidly.
2. **Retype Grimfeast** (step above).
3. **hop Phase 12**, developed against `demo_ragdoll.cpp` and unit tests, entirely inside hop.
   This is the long pole and it is independent of steps 1–2.
4. **`ragdoll_builder.gd`** and the wizard corpse's switch from `die_*` to
   `physical_bones_start_simulation()`. The `die_*` clips stay in the models, so the old look is
   a flag away while the ragdoll is tuned.
5. **Prediction/correction**, once a single-player ragdoll looks right. Seeded RNG, then the
   rigid-offset correction.
6. **Bake and stop.** When every bone sleeps, write the final poses with `set_bone_pose_*` and
   stop the simulator, so a settled corpse is a static skinned mesh for the rest of its 60
   seconds. `project_skeleton_crowd_cost` is the reason this is a step and not an afterthought:
   the per-frame bone write is a real cost at `gl_compatibility`, and a corpse that has stopped
   moving should not pay it.

## What this deletes

- `src/corpse.gd` (117 lines) and the `Corpse` `class_name`
- the `WW_CORPSE_PROBE` instrumentation
- `Corpse.DEATH_ANIMS` and the corpse's `net_anim` replication
- `_spawn_corpse`'s `"element"` / `"yaw"` payload keys, replaced by `"model"` + `"velocity"` +
  `"seed"` like every other dynamic entity

## Risks, and what to measure before tuning

- **Body count.** 21 bodies and 20 joints per corpse; eight dead wizards is 168 bodies. Measure
  in `demo_ragdoll.cpp` first. If it doesn't fit, the fallback is merging hitboxes per limb
  segment down to ~11 physical bones while the remaining bones follow their parent's rest
  offset — a change to `ragdoll_builder.gd` alone, not to hop.
- **The capsule spin bug does not apply, and that is luck worth banking.** Bug 2 in
  `plans/rotating_gibs.md` — "a capsule resting on a floor creates spin from nothing" — is
  capsule-only, boxes immune. MDL hitboxes are boxes, so ragdoll bones are boxes. Step 1's
  interim wizard corpse should use a **box** collider for the same reason.
- **Intra-tick stretch.** `update_solid` can take several substeps per tick, and constraints
  recompute per substep on the force path (`simulator.h:299`) — but the Pass-B rigid solve runs
  once per tick. A bone moving fast within one tick can stretch and get pulled back. Standard,
  and fine at ragdoll speeds; noted so it isn't mistaken for a solver bug.
- **Sixty seconds of corpses** is only affordable because of item 3 and step 6. If either slips,
  the linger comes down until they land.


---

## What actually happened

Steps 1–6 all shipped, and the design above survived them almost unchanged. Four places
where it didn't:

**1. hop cannot sleep a corpse, and the reason is not the joints.** Item 3 of Phase 12 —
"Sleep — falls out of item 1, and that is the point" — is *true about the joints*: a
satisfied rigid pin reads unloaded, and `test_rigid_joint_sleeps` holds a pinned body
deactivating where a sprung one never does. But a corpse lying on a floor still never
sleeps, because of something underneath:

> **An oriented box resting on a floor spins forever.**

`demo_ragdoll`'s control drops one box with no joints anywhere. Axis-aligned, it settles and
sleeps. Tilted three degrees, it turns at several rad/s indefinitely — worse the smaller the
body (|ω| ≈ 1/size), and damping does not touch it, because the spin is handed out fresh
every tick rather than accumulating. hop resolves a pair at ONE point and `support()` on a
tilted box returns a CORNER; one tick of gravity's impulse at that lever is worth ~4 rad/s
on a 0.35 kg bone, so it tips, catches the next corner, and rocks there permanently.

This is exactly the risk this document called *"luck worth banking"* — bug 2 of
`plans/rotating_gibs.md`, recorded as capsule-only with boxes immune. **Boxes are immune only
while they are axis-aligned**, and a corpse's bones land at every angle but that one. The fix
is a contact manifold — two or four points under a resting face — which is a hop phase of its
own and was not taken here.

So **step 6 stopped being an optimization and became the thing that makes the feature
affordable**. The corpse decides for itself when it has stopped moving anywhere that matters
(`SETTLE_WINDOW`/`SETTLE_DISTANCE` at the pelvis, `MAX_SIM_TIME` as a hard cap), bakes the
pose, and stops. `test_eight_dead_wizards_all_stop_on_their_own` is the guard: 168 bodies, and
none still simulating when the corpses still have fifty seconds left to lie there.

**2. The position pass needed rotation, which this document did not anticipate.** "An NGS
pass pushing the anchors together by the residual error, split by inverse mass" is what hop's
contact pass does, and it is translation-only. A pin's residual error is mostly *rotational*:
Pass A steps a body's orientation with the ω it held before the solve, so a bone the solver
is about to spin has already turned by the wrong amount. Sliding it sideways to close that
gap only opens the next joint along — measured, a translation-only pass left a corpse sagging
25 cm at the wrists. `solid` gained `rot_correction_` beside `pos_correction_` and the joint
position pass is a full pseudo-impulse. A Baumgarte term in the *velocity* sweep does the
same job and hands the chain real energy for it; that was tried, and with (1) above a corpse
converts it straight into a permanent shiver.

**3. The corpse origin moved to the body's centre.** hop spins a solid about its own origin
and has no centre-of-mass offset, so the old feet-origin would have pivoted a corpse about
its ankles. `wizard_payload` spawns half a hull above the player's feet; Grimfeast dropped
the `+0.5` it used to add to aim at the chest, and a raised skeleton spawns half a metre high
and falls the rest, which it already did.

**4. `net_anim` did not leave the corpse.** It was going to, since a ragdoll plays no clip.
But `ragdolls off` keeps the `die_*` presentation as a live fallback rather than a dead
branch, so the slot stays declared — it costs one path resolve per corpse per tick and buys a
one-word rollback if the ragdoll ever looks wrong on a map.

Everything else landed as written: the builder is ~110 lines and reads the rig with no
per-model table, the merged corpse carries both shapes, Grimfeast retyped, the two
pre-existing bugs in the table at the top are both fixed (`MASK_CORPSE` on every corpse so
movers can find one; the client freeze branch), and the prediction/correction is a seeded RNG
plus a rigid whole-assembly offset.

**Still open**, in the order they would be worth doing:

- **Contact manifolds in hop** (the box spin above). It would let corpses sleep instead of
  being stopped on a timer, and it would settle loose gibs too, which have the same problem
  today and nobody noticed.
- **Angular limits**, if watching pin-only corpses says the joints need them. Phase 13 in
  hop's plan, still an if.
- **Merging hitboxes per limb segment** down to ~11 bodies, if 21 ever proves too many. A
  change to `ragdoll_builder.gd` alone. Measured in `demo_ragdoll`: eight awake corpses cost
  ~4.5 ms/tick, which is why step 6 matters; baked, they cost nothing.
