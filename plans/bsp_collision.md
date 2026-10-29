# BSP hull collision for hop-godot

> **Status (2026-08-04): Phases 1–4 landed** on branch `bsp-hull-collision`
> (submodule branches `hop-godot:bsp-hull-traceable`,
> `goldsrc-godot:bsp-hull-blob`). Hull collision is live under hop and verified
> on all 30 shipped maps. Phase 5 is partly done (push-out recovery + margin both
> implemented and tested); Phases 6–7 are untouched and largely moot — see the
> notes inline. **Not yet playtested by a human.**
>
> Two decisions changed during implementation, both recorded below:
> - The blob is a *shared* per-map allocation keyed by the carrying node, and
>   margin inflation is a read-time plane bias, not a copied plane array. Per-body
>   copies would have cost ~800KB × 245 bodies.
> - Contents does NOT need a channel out of a trace (Phase 6/7). Blocking contents
>   is a build-time mask on the traceable, so sky falls out of GoldSrc's own
>   default: passable in hull 0 (projectiles fly through), solid in hulls 1–3
>   (players collide) — measured across four maps, not assumed.

Trace player movement, hitscan, and contents against GoldSrc BSP hulls instead of
trimesh/convex colliders, to get clean plane normals (no seam jitter, no
is_on_floor flicker) and GoldSrc-authentic movement — while keeping the existing
trimesh/convex colliders so the game stays fully playable under default Godot
physics.

## Locked decisions

1. **Fallback bar: correct & playable.** Default-physics path must be fully
   functional (no fall-through, no missing water, no broken collision). Minor
   micro-feel differences vs the hop/BSP path are acceptable. Therefore: BSP data
   is **purely additive** — we never remove a collider that default physics needs.
2. **Collision model: GoldSrc box hulls.** Player traces as a point through the
   pre-expanded clipnodes (`headnode[1..3]`). Authentic, cheapest, cleanest
   normals. Accepts slight box-vs-capsule divergence from default physics at
   edges/corners (allowed by decision 1).
3. **Build the trace first.** Prove `recursive_hull_check` (hull 0, point trace) in
   hop-godot's C++ test suite against a synthetic blob, in isolation, before
   touching movement or the real-map handoff.
4. **Water: keep Area3D, BSP contents additive.** Do not modify the existing water
   system. BSP contents (`point_contents` / `trigger_scope`) come later as an
   optional parallel channel, never as a replacement.

## Architecture: the additive metadata carrier

Everything funnels through two facts:

- hop *is* the PhysicsServer (`project.godot:116` `3d/physics_engine="Hop Physics"`).
  Switching it off = set that back to `"DEFAULT"` at engine init. Default physics
  cannot read a BSP hull, so BSP data can only ride as **metadata** beside a real
  collider that default physics understands.
- hop dispatches collision per-solid through a polymorphic `traceable`
  (`extern/hop/include/hop/traceable.h`: `get_bound` / `trace_segment` /
  `trace_solid`). The trimesh is one impl (`hop_trimesh_traceable.h`); a BSP hull
  is just another. Attach point is `hop_shape_data.cpp:245`.

So the integration shape is:

> goldsrc-godot keeps building the current `ConcavePolygon`/`ConvexPolygon`
> collider on each model's `StaticBody3D` **and** attaches a serialized hull blob
> as metadata (`col->set_meta("bsp_hull", blob)`). When hop registers that body in
> a space it checks for `bsp_hull` and, if present, builds a `HopBspTraceable` from
> the blob and uses it instead of the carrier shape. Under default physics (or hop
> with the feature off), the metadata is ignored and the carrier shape — today's
> exact collision — is what runs.

The fallback is not a separate code path: **the fallback is the carrier shape that
is still there.**

## Current collision path (what we are adding alongside)

Per-model loop, `extern/goldsrc-godot/src/nodes/goldsrc_bsp.cpp:1642+`:

- Worldspawn (m=0): `build_hull_collision` (`:1768`) → trimesh
  `ConcavePolygonShape3D` from visible face tris. Water:
  `build_brush_convex(…, CONTENTS_WATER)` → convex cells in an Area3D (`:1659`).
  Sky: face-built StaticBody, layer 9 (`:1206+`).
- Brush entities (m>0): `build_brush_convex` (`:1857`) → one
  `ConvexPolygonShape3D` per solid BSP leaf via `walk_bsp_tree` on `headnode[0]`,
  shared into a `Volume` Area3D.

All three end identically: `CollisionShape3D{shape}` added to a `StaticBody3D`.
That is the single seam we extend.

Note: `clipnodes` and `headnode[1..3]` are parsed into `BSPData` but **never
read** today — every descent (`point_contents:656`, `point_to_leaf:686`,
`walk_bsp_tree:1888`) uses `headnode[0]`. The box hulls are untapped.

## Foundations (needed before any phase)

- **Coordinate space: trace in native GoldSrc units — do NOT pre-transform.**
  The blob carries BSP geometry in native GoldSrc space (Z-up, inches), exactly as
  it sits on disk. The consumer transforms the *query* into that space, traces, and
  transforms the *result* back (`Rᵀ` in, `R` out — the axis-swap/scale inverse of
  `goldsrc_to_godot`). This is how real GoldSrc traces, and it's the pattern hop's
  rotation work already uses (`extern/hop/docs/rotation_plan.md:60`). It beats the
  earlier "transform every plane at export" idea: no float error baked across
  thousands of planes, and the blob stays a pristine, dumpable `.bsp`. The one
  non-BSP datum the trace needs — `scale_factor` — is not a standard lump field, so
  it travels as a *separate* metadata value alongside the blob (`set_meta`), never
  inside the BSP bytes. Getting the query in/out transform wrong faces floors
  sideways; it is proven by the Phase 1 tests.
- **Hull-size constants.** GoldSrc bakes hull box sizes in the engine, not the
  file (HL: hull1 `±16,±16,-36/+36`; hull2 `±32`; hull3 `±16,±16,-18/+18`). The
  consumer hard-codes these (they are engine constants, not per-map) so
  `hull_for_box` has something to match. Express in GS units; selection compares
  the traced solid's AABB in GS space.
- **Blob format: a stripped BSP30 file, unified with the PVS blob.**
  Do NOT invent a bespoke payload. goldsrc-godot already ships
  `get_pvs_blob()` (`goldsrc_bsp.cpp:540`) which writes a *valid BSP30 file* — real
  `BSPHeader` with `version = HLBSP_VERSION` and a lump directory, carrying only the
  lumps a consumer needs (PLANES/VISIBILITY/NODES/LEAFS/MODELS), everything else
  zeroed. Collision needs the same set **plus CLIPNODES** (`LUMP_CLIPNODES = 25`,
  already parsed into `BSPData`). So collapse the two into one
  `get_bsp_blob()` carrying **PLANES + VISIBILITY + NODES + CLIPNODES + LEAFS +
  MODELS** — it serves both `VisibilityManager` (PVS) and `HopBspTraceable`
  (collision) from a single metadata key. Benefits over a bespoke blob: the format
  is the published BSP30 spec (no private versioning — `BSPHeader.version` is the
  version), any BSP reader can parse it, and you can dump it straight to disk and
  open it in a BSP viewer. Still a copied `PackedByteArray`: hop owns its copy,
  never a pointer into goldsrc-godot's parse (lifetime safety).
- **Shared struct layout: copy a minimal subset into hop-godot, do NOT depend on
  goldsrc-godot.** hop-godot must stay independently buildable/testable (its test
  suite builds with neither Godot nor goldsrc-godot). So it gets a new
  `src/hop_bsp_format.h` (~40 lines) with only the lumps the trace reads:
  `BSPLump`, `BSPHeader`, `BSPPlane`, `BSPNode`, `BSPClipNode`, `BSPLeaf`,
  `BSPModel`, the `CONTENTS_*` constants, and the **exact same `#pragma pack`
  directive** as goldsrc-godot's `bsp_parser.h`. NOT the render/texture structs
  (`BSPFace`, `BSPTexInfo`, `BSPEdge`, mip-tex…) — the trace never touches them.
  This mirrors an existing convention in these repos: goldsrc-godot already inlined
  structs "to avoid that dependency" (`goldsrc_bsp.cpp:38`). The byte-layout
  agreement is a conformance to the fixed BSP30 spec on both sides — not a private
  contract — with a comment in `hop_bsp_format.h` pointing at `bsp_parser.h` as its
  layout twin so a future format touch updates both.

## Phase 1 — `RecursiveHullCheck` + `hop_bsp_format.h` in hop-godot — BUILD FIRST

The trace has exactly one home — hop-godot, where it actually runs — so build and
prove it there from the start. hop-godot's C++ test suite builds with neither Godot
nor goldsrc-godot, so the trace math + blob parse + query transform get validated in
isolation, no cross-extension coupling yet.

- Add `src/hop_bsp_format.h` — the minimal copied BSP30 struct subset (foundations).
- Add `src/hop_bsp_traceable.h` skeleton with a free `recursive_hull_check(...)`
  over the parsed lumps: the `point_contents`-style descent plus a t-fraction split
  at each plane crossing, tracking the last crossed plane as the hit normal, and
  `startsolid`/`allsolid` from leaf contents. hull 0 uses `nodes`; the same function
  takes `clipnodes` in Phase 4.
- The descent runs in **native GoldSrc space**. The public entry takes/returns
  Godot-space vectors: convert the query segment in with the inverse of
  `goldsrc_to_godot` (using `bsp_scale`), trace against the native planes, convert
  `endpos`/`normal` back out. No plane is ever pre-baked.
- Tests in hop-godot's own C++ suite against a **hand-authored synthetic blob** — a
  single axis-aligned box brush written as a stripped BSP30 file in the test itself
  (a few planes, one solid leaf). Cases: straight-down onto the floor (fraction,
  up-normal), into a wall, start-in-solid, clean miss. This is where the query
  in/out transform gets proven — the highest-risk detail (a sideways floor normal
  shows up immediately here) — and where the `hop_bsp_format.h` byte layout gets
  round-trip-checked against a known-good blob.

No goldsrc-godot changes and no real map needed yet: the synthetic box exercises
every code path the descent has.

## Phase 2 — Blob export + metadata carrier in goldsrc-godot (additive, no behavior change)

Feed the Phase-1 trace real map data.

- Extend `get_pvs_blob()` into `get_bsp_blob()` by adding the CLIPNODES lump (a
  single extra `write_lump` — see foundations). This is the unified stripped BSP30
  file that serves both PVS and collision; keep `get_pvs_blob()` as a thin alias or
  migrate `VisibilityManager` to the unified call.
- In the collision dispatch (`:1642+`), after the existing
  `build_hull_collision` / `build_brush_convex` call, attach the blob and the scale
  on the carrier `CollisionShape3D` (or the `StaticBody3D`):
  `col->set_meta("bsp_hull", blob)` and `col->set_meta("bsp_scale", scale_factor)`.
  Nothing else changes; with no consumer yet this is a no-op at runtime and
  trivially fallback-safe.
- A round-trip test (write `get_bsp_blob()` in goldsrc-godot, parse with a copy of
  `hop_bsp_format.h`) guards the struct-layout contract between the two extensions.

## Phase 3 — Wire `HopBspTraceable` into the physics server (in-engine hitscan)

The trace already exists and is tested (Phase 1); this is the cross-extension
handoff — real blob → live traceable.

- hop-godot, when a body enters a space, checks for `bsp_hull` metadata, copies the
  blob + `bsp_scale` into a `HopBspTraceable`, and uses it in place of the carrier
  shape (new branch near `hop_shape_data.cpp:245` / body registration in
  `hop_physics_server.cpp`). Absent metadata → existing carrier shape path,
  unchanged.
- Exercises `trace_segment` (hull 0) end-to-end on a real map — the low-risk query
  (raycasts) — validating the metadata handoff before movement depends on it.

## Phase 4 — Box hulls + `trace_solid` (player movement — the payoff)

- Light up `clipnodes` / `headnode[1..3]`. `hull_for_box`: pick the hull whose
  baked size best matches the traced solid's AABB (player capsule → hull 1).
- `HopBspTraceable::trace_solid`: reduce the solid to a point (origin, offset for
  the hull reference), `RecursiveHullCheck` along `seg` through the chosen
  clipnode tree, return `time` / `point` / `normal = plane normal`.
- This is where is_on_floor gets a single clean up-plane — the seam jitter and
  margin-gap class of bugs (see git history / this branch's earlier fixes)
  disappear for BSP maps. Carrier convex shape remains the default-physics
  fallback.
- Validate: walk/strafe/jump on a BSP map under hop; confirm no fall-through,
  stable grounding, working steps; then toggle `physics_engine="DEFAULT"` and
  confirm the carrier convex collision is still playable.

## Phase 5 — Recovery / depenetration + margin (satisfy the traceable contract)

`traceable.h` requires the zero-direction overlap path to return `t=0` **with a
push-out `depth` and `normal`**, and `margin` Minkowski-inflation for
speculative contacts. Classic hull tracing only gives `startsolid` (a bool), so:

- Zero-direction case: find the nearest bounding plane of the containing solid
  leaf and report `depth`/`normal` to push out along. Needed for spawn-inside-wall
  and to match how hop's CharacterBody3D path leans on recovery.
- `margin`: offset plane distances by `margin` during descent (approximate at
  corners; acceptable).

## Phase 6 — Contents (additive, optional)

Per decision 4, the water Area3D stays. Add BSP contents as a *parallel* channel:

- `point_contents` already returns `CONTENTS_WATER/SLIME/LAVA/SKY` and is
  engine-independent. Optionally expose waterlevel sampling (feet/waist/eye) as an
  alternative the movement code *may* consult — but do not remove the Area3D path.
- Optionally map liquid contents → hop `collision.trigger_scope`
  (`extern/hop/include/hop/collision.h`) so a single `trace_solid` reports
  "in water" alongside the solid hit. Strictly additive; off by default.

## Phase 7 — Projectiles / sky (optional)

- Projectile sky removal via the `HopBspTraceable` trace endpoint
  `contents == CONTENTS_SKY` (reported by `trace_segment`/`trace_solid` in the hop
  path). Keep the existing sky StaticBody as the default-physics fallback; do not
  remove it.

## Scope boundaries

- **Terrain `.glb` maps stay trimesh.** BSP collision applies only to BSP maps;
  trimesh terrain keeps using `hop_trimesh_traceable`. The two coexist per-solid.
- **Rotating brush entities** (`func_rotating`, swinging doors) keep today's
  behavior — hop core lacks per-solid orientation (`project_hop_rotation_deferred`).
  Translating brush entities work via the `position` subtract the trimesh already
  does. No regression, no new capability here.

## Risks / open items

- **Query in/out transform correctness** — the single highest-risk detail (native
  GoldSrc-space trace, Godot-space query). Phase 1 tests must nail it before
  anything builds on it; a sideways floor normal surfaces there immediately.
- **Blob struct-layout drift** — hop's copied `hop_bsp_format.h` must stay
  byte-identical to goldsrc-godot's `bsp_parser.h` (same `#pragma pack`, same field
  order). Both conform to the fixed BSP30 spec, so drift is unlikely, but a format
  touch on one side without the other silently misreads lumps. Cross-reference
  comment + a round-trip parse test (write blob in goldsrc-godot, read in
  hop-godot's test suite) guard it.
- **`hull_for_box` mismatch** — only baked hull sizes exist; a solid that isn't a
  baked size collides slightly wrong. Fine for the fixed player size + point
  hitscan; do not use BSP hulls for arbitrary-sized dynamic bodies.
- **Box-vs-capsule divergence** when toggling engines — accepted under decision 1;
  re-evaluate only if it's noticeable in play.
- **Blob lifetime** — hop owns a copy; never a pointer into goldsrc-godot's parse.
- **`func_water` (moving liquid)** is an entity (own model/headnode), not a
  worldspawn contents leaf — keep the two distinct in the converter.

## Validation per phase (the fallback gate)

Every phase ends with the same gate: run the affected scenario under
`physics_engine="Hop Physics"`, then flip to `"DEFAULT"` and confirm the carrier
colliders still give correct, playable collision. A phase isn't done until both
toggles pass.

## The `bsp_hulls` flag (added after Phase 4)

Hull collision is a **replicated server var**, not a build-time choice, because it
decides what geometry movement *prediction* runs against: a client tracing trimesh
while the host traces hulls mispredicts every step. So it rides the existing
ServerVars path — host sets, `NetworkManager.sync_server_var` replicates, and the
join snapshot catches late joiners.

- `/bsp_hulls [on|off]` (admin; no arg flips). Reports what is actually in effect,
  which is "inert" when the physics engine is not Hop.
- `--bsp-hulls <on|off>` at startup, for dedicated servers with no console. On a
  client it holds only until the host's snapshot lands on join.
- `ServerVars.value_changed` is the new signal reactive tunables hang off — most
  vars are read at point of use, this one has to *reconfigure* the physics server.
  `Main._apply_bsp_hulls` is the listener; `Main.bsp_hulls_active()` reports truth.
- `HOP_NO_BSP_HULLS=1` now only seeds hop's boot default (CI / headless).

Verified: toggling on a loaded ww_2fort rebuilds 245 carrier bodies each way and
flips what casts hit; a host started `--bsp-hulls off` flips a default-on client to
off on join, with no client-side argument.

## Two fall-through bugs found by bot testing (2026-08-04)

Bots on ww_2fort with hulls on scored **zero** captures across two runs and kept
ending up at y=-103, past `WORLD_BOUND`; with hulls off they captured normally.
Both causes were invisible to the unit tests because every test used a
centre-origin mover, and both are no-ops for one:

1. **Hull offset sign.** GoldSrc traces `origin + mins - clip_mins`; the code had
   `clip_mins - mins`. The difference is zero for a centre-origin box — GoldSrc's
   own player — but Godot character bodies put the origin at the feet
   (`godot_body.gd` offsets the collider up). Backwards, the trace ran half a body
   below the feet, so a bot standing on the floor read as 0.9m embedded and got a
   **downward** push-out through the world.
2. **Swept trace starting inside solid returned "clear".** Quake reports
   `startsolid` and leaves the trace clear because its callers check that flag;
   hop's caller has none, so a clear trace means "the path is free" and the mover
   tunnels. Now reported as a t=0 overlap with the push-out.

Both are pinned by tests (`feet_origin_mover_*`, `solid_starting_stuck_reports_overlap`).

**Lesson for the rest of this feature:** a centre-origin mover hides an entire
class of offset bug. Any new hull math should be tested against a feet-origin box.

Verified after the fix, ww_2fort, 6 bots, same 150s window:

| | captures | min y | samples below y=-30 |
|---|---|---|---|
| hulls off (baseline) | 2 | -17.0 | 0 |
| hulls on, before fix | 0 | -103 | 29 |
| hulls on, after fix | 2 | -17.3 | 0 |
