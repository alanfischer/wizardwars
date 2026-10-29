# PVS / Zone Visibility Plan

## Goal

A clean, backend-agnostic zone visibility system integrated into the game for both
rendering culling and network relevance filtering.  The game implementation uses
GDScript-driven visibility toggling — simple, no build complexity.  The architecture
is designed so that a future upstream Godot contribution (described below) can replace
the GDScript consumer with native renderer culling without touching any other code.

---

## Architecture

Four layers, strictly separated:

```
Godot engine             — VisualInstance3D.zone_ids + RenderingServer culling pass
ZoneMap (Resource)       — precomputed spatial data, no runtime deps
ZoneManager (Node)       — observer tracking + query API, no rendering/net knowledge
Consumers                — rendering (RenderingServer call) and networking (network_manager)
```

No layer knows about the layers below it.  Callers only see `ZoneMap` and
`ZoneManager`; the BSP backend is invisible to game code.  The engine does the actual
culling; the consumer just hands it a list of visible zone IDs.

---

## Upstream Godot Contribution (future)

Three self-contained, backward-compatible additions to Godot itself.  Not required to
ship the game — the GDScript consumer in Phase 5 works without them.  When contributed,
Phase 5 is replaced by a ~5-line handler and the renderer does the culling natively.
Requires building a custom Godot and maintaining a fork; defer until the game
implementation is proven.

### 1. `VisualInstance3D.zone_ids: PackedInt32Array`

New property on `VisualInstance3D` (inherited by `MeshInstance3D`, `GeometryInstance3D`,
etc.).  Thin wrapper over `RenderingServer.instance_set_zone_ids`.  Instances with an
empty `zone_ids` are always visible — backward compatible with all existing content.

### 2. `RenderingServer` — two new methods

```
instance_set_zone_ids(instance: RID, zone_ids: PackedInt32Array)
scenario_set_visible_zones(scenario: RID, zone_ids: PackedInt32Array)
```

`instance_set_zone_ids` stores zone membership on a render instance.
`scenario_set_visible_zones` sets the active visible zone set for a scenario; an empty
array disables zone culling.

### 3. Zone culling pass in `RendererSceneCull`

After frustum culling, before draw call submission (~30 lines in
`renderer_scene_cull.cpp`):

- Instance has empty `zone_ids` → always passes (backward compat)
- Instance has non-empty `zone_ids` and none intersect the visible set → culled
- Scenario has no visible zone set → no zone culling applied

When these land, Phase 3 drops `set_meta` in favor of `mesh_instance.zone_ids = ...`
and Phase 5 collapses to a single `RenderingServer.scenario_set_visible_zones()` call.

---

## New Types

### `ZoneMap` — abstract Resource (C++)

```cpp
class ZoneMap : public Resource {
    virtual int      get_zone_count() const;
    virtual int      get_zone(Vector3 position) const;   // -1 = outside/unknown
    virtual PackedInt32Array get_visible_zones(int zone) const;
    // default impl calls get_visible_zones — override for fast-path:
    virtual bool     are_zones_visible(int zone_a, int zone_b) const;
};
```

Serializable.  Loaded via `ResourceLoader`.  Backend is a subclass detail.

### `BSPZoneMap` — concrete subclass (C++, lives in goldsrc-godot)

Implements `get_zone()` via BSP tree traversal (point-in-leaf walk).
Implements `get_visible_zones()` via PVS RLE decompression.
Built by `GoldSrcBSP::build_zone_map()` and embedded in the `.scn`.

### `ZoneManager` — Node (C++)

```cpp
class ZoneManager : public Node {
    // configuration
    Ref<ZoneMap> zone_map;

    // observer tracking
    void register_observer(Variant id, Node3D* node);
    void unregister_observer(Variant id);
    int  get_observer_zone(Variant id) const;

    // query API — callable from rendering, networking, AI, audio
    int              get_zone(Vector3 position) const;
    PackedInt32Array get_visible_zones(int zone) const;
    bool             is_visible(Vector3 from, Vector3 to) const;

    // signal — consumers react to zone boundary crossings
    Signal zone_changed(Variant observer_id, int from_zone, int to_zone);
};
```

Updated each physics tick.  Fires `zone_changed` only when an observer actually
crosses a boundary (cheap: one `get_zone()` call per observer per tick).

---

## Where Code Lives

```
extern/goldsrc-godot/src/
  nodes/
    zone_map.h / zone_map.cpp            DONE — ZoneMap abstract Resource
    zone_manager.h / zone_manager.cpp    DONE — ZoneManager Node
    bsp_zone_map.h / bsp_zone_map.cpp    NEW  — BSPZoneMap concrete subclass
    goldsrc_bsp.h / goldsrc_bsp.cpp      MODIFY — add build_zone_map(), set zone_ids on nodes

src/
  systems/
    map_converter.gd                     MODIFY — embed ZoneMap in .scn
  main.gd                                MODIFY — load ZoneMap, wire ZoneManager
  systems/network_manager.gd             MODIFY — filter broadcasts via ZoneManager
```

`ZoneMap` and `ZoneManager` contain zero BSP knowledge.  `BSPZoneMap` stays in
goldsrc-godot as the reference implementation for the upstream pitch.

---

## Phases

### Phase 1 — `ZoneMap` + `ZoneManager` C++ skeleton ✓

Files: `zone_map.h/.cpp`, `zone_manager.h/.cpp`, `register_types.cpp`

- `ZoneMap`: abstract Resource, virtual methods, registered with ClassDB
- `ZoneManager`: Node, observer list, `zone_changed` signal, query methods,
  per-tick observer update in `_physics_process`
- No BSP dependency yet — `ZoneMap` stub returns -1/empty

Milestone: `ZoneManager` instantiates in Godot, signal fires when observer moves. ✓

---

### Phase 2 — `BSPZoneMap` + BSP data retention

Files: `bsp_zone_map.h/.cpp`, `goldsrc_bsp.cpp`

- Retain BSP nodes (plane + children) and raw PVS lump bytes after `build_mesh()`
  (currently discarded)
- `BSPZoneMap::get_zone(position)`: walk BSP node tree, return leaf index
- `BSPZoneMap::get_visible_zones(zone)`: decompress RLE PVS for that leaf
- `GoldSrcBSP::build_zone_map()`: construct and return a `BSPZoneMap` resource
- Register `BSPZoneMap` with ClassDB

Milestone: `build_zone_map()` returns a resource; leaf queries match expected values
for known positions on a test map.

---

### Phase 3 — Spatial node tagging

Files: `goldsrc_bsp.cpp` (mesh building pass)

During `build_mesh()`, track which BSP leaf each face originates from.  When
creating worldspawn spatial group nodes, store the union of their faces' leaf
indices as node metadata:

```gdscript
node.set_meta("zone_ids", PackedInt32Array([12, 13, 17]))
```

Strategy: tag-not-regroup.  Existing spatial grouping (by BSP depth) is unchanged;
we only annotate the existing nodes.  A node is visible if *any* of its `zone_ids`
is in the current visible set.

Milestone: all worldspawn spatial nodes carry `zone_ids` metadata after conversion.
Verify by printing metadata in the editor scene tree.

---

### Phase 4 — Map converter: embed ZoneMap in the `.scn`

Files: `map_converter.gd`, `main.gd`

Same pattern as the existing `light_grid` and `lightstyle_texture` metadata.
In `map_converter.gd::convert()`, after `bsp.build_mesh()`:

```gdscript
if bsp.has_method("build_zone_map"):
    root.set_meta("zone_map", bsp.build_zone_map())
```

The `ZoneMap` resource is packed into the `.scn` by Godot's `ResourceSaver` automatically.
No separate file.  Cache invalidation is automatic — if `.scn` regenerates, so does the
zone map.  Client map downloads already transfer the `.scn`, so zone data is free.

In `main.gd` map loading (both listen-server and dedicated), after scene load:

```gdscript
if map_root.has_meta("zone_map"):
    var zm = ZoneManager.new()
    zm.zone_map = map_root.get_meta("zone_map")
    map_root.add_child(zm)
    _zone_manager = zm
```

Milestone: zone map embedded in `.scn`, present on both client and dedicated server
after map load.  `ZoneManager` in scene tree.  Regenerate existing cached maps by
deleting `user://resources/maps/`.

---

### Phase 5 — Rendering consumer

Files: `main.gd` or a new `zone_visibility.gd` autoload (~60 lines)

On map load, after `_zone_manager` is wired:

1. Register the local camera (or client body) as observer:
   ```gdscript
   _zone_manager.register_observer("camera", _client)
   ```

2. Scan the map scene tree for nodes with `zone_ids` metadata; build a lookup:
   ```gdscript
   var _zone_nodes: Dictionary  # zone_id -> Array[Node3D]
   ```

3. Connect to `zone_changed` signal:
   ```gdscript
   func _on_zone_changed(id, _from, to):
       if id != "camera": return
       var visible = _zone_manager.get_visible_zones(to)
       for node in _all_zone_nodes:
           var ids: PackedInt32Array = node.get_meta("zone_ids")
           node.visible = ids.any(func(z): return z in visible)
   ```

Only executes when the camera crosses a leaf boundary.  No per-frame cost otherwise.
Zone crossings are infrequent enough that iterating a few hundred nodes is negligible.

Milestone: walking through a map culls geometry behind walls.  Verify with Godot's
wireframe debug mode and the existing occluder debug visualization.

---

### Phase 6 — Network consumer

Files: `network_manager.gd` (~20 lines changed), `main.gd` (~5 lines)

Pass `_zone_manager` reference to `NetworkManager` after map load.

In `send_entity_transforms()`, filter per peer before adding to batch:

```gdscript
if _zone_manager and not _zone_manager.is_visible(
        _player_cache[peer_id].global_position, entity.global_position):
    continue
```

Same one-line guard in `broadcast_all_player_states()`.

Handle edge cases:
- Observer zone is -1 (outside map, loading): send everything
- Entity zone is -1: always send (conservative)
- No `_zone_manager` present: fall through to existing broadcast (backwards compat)

Milestone: on a LAN test with two clients, entity transform RPCs drop to near zero
when one player cannot see the other through PVS.  Verify via network traffic logging.

---

## Upstream Path

Once the game implementation is working end-to-end:

1. Submit Godot PR: `VisualInstance3D.zone_ids`, `RenderingServer` methods,
   `RendererSceneCull` pass (see "Upstream Godot Contribution" above).  Point to this
   project as proof of concept.
2. Replace Phase 5's GDScript consumer with the single `scenario_set_visible_zones()`
   call.  Replace Phase 3's `set_meta` with `mesh_instance.zone_ids = ...`.
3. `ZoneMap` and `ZoneManager` can be extracted into a standalone `godot-zone-visibility`
   GDExtension if useful — the game code is unchanged either way.
4. `BSPZoneMap` stays in goldsrc-godot as a first-party backend example.

The game code never changes: it only sees `ZoneMap`, `ZoneManager`, and `is_visible()`.

---

## Resolved Decisions

- **Cache invalidation**: zone map is embedded in the `.scn` as metadata (same pattern
  as `light_grid`), so it regenerates automatically whenever the scene does.  No
  separate file, no separate cache check.

- **Zone -1 policy**: always show everything.  Pass empty array to
  `scenario_set_visible_zones` to disable zone culling for that frame.

- **Rendering integration**: GDScript `.visible` toggling for the shipped game — no
  Godot fork required.  Zone crossings are rare events; iterating a few hundred nodes
  in a signal handler is negligible.  Native renderer culling is the upstream goal but
  not a prerequisite for shipping.

- **PVS expansion for network**: expose two knobs on `ZoneManager`:
  ```gdscript
  @export var network_pvs_expand: int = 0   # extra neighbor leaves to include
  @export var render_pvs_expand: int  = 0   # same for rendering
  ```
  Both default to 0 (exact PVS).  When > 0, `get_visible_zones()` also walks N hops
  of BSP leaf adjacency and unions the result.  Lets us tune pop-in vs. bandwidth
  independently for the two consumers without touching consumer code.
