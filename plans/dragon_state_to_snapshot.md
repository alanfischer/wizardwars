# Dragon state: side-channel RPC → goldnet snapshot

**Status: implemented** for the dragon (`net_sync_properties` seam + `is_ridden`/`anim_name`).
Breakables, lights, thornplants and monstermaker still ride `sync_entity_state`; each is now a
mechanical repeat of the same pattern. Needs a live client/server playtest — no single-process
test can observe replication.

Move the dragon's replicated state off `sync_entity_state` (an `@rpc`) and onto
synchronizer properties carried by goldnet's snapshot. First entity of a pattern the
other `sync_entity_state` users can follow one at a time.

## Why

goldnet delegates **all `@rpc` traffic to the inner stock `SceneMultiplayer`** and
overrides only state replication. So `sync_entity_state` rides a completely separate
pipeline from the snapshot that carries spawns and PVS relevance — no shared ordering,
no shared relevance. Everything that went wrong on ww_chasm follows from that:

- the `{is_ridden: true}` broadcast raced the dragon's spawner create and was dropped,
  leaving a ridden dragon rendering 1 m high and still solid (client only);
- it is broadcast to **every peer** regardless of PVS;
- `EntityBehavior` starts a `0.5 s` autostart timer per animated entity
  (`entity_behavior.gd:29-35`) that re-sends `{anim, anim_pos}` unconditionally —
  actively defeating goldnet's delta compression, whose whole premise is
  *"idle entities cost zero bytes, provided the game doesn't rewrite a field every tick."*

As snapshot properties all three problems disappear by construction. From goldnet's
README: *"Re-entry needs no event — the entity simply reappears in `changed` with a full
baseline."* That is the "never born stale" guarantee, already implemented, already tested,
and free.

## Scope: the dragon only

In scope — the dragon's **state**:

| today | after |
|---|---|
| `_get_sync_state() -> {"is_ridden": …}` (`dragon.gd:260`) | `is_ridden` synced property |
| `_apply_sync_state()` → collision layer + `_update_animation` (`dragon.gd:264-269`) | `is_ridden` setter |
| `_entity.sync_notify()` ×3 (`dragon.gd:167, 209, 220`) | assigning `is_ridden` |
| `_entity.set_anim_player()` → 0.5 s `{anim, anim_pos}` broadcast (`dragon.gd:98`) | `anim_name` synced property |

Out of scope, deliberately:

- **`sync_dragon_mount`** stays an RPC. It is a latching *command about a player* with
  player-lifecycle invalidation (respawn/class change), not entity state. Its parked-replay
  in `LocalPlayer` stays.
- **`sync_dragon_flame`** stays an owner-directed RPC — one peer, not replicated state.
- **breakables, lights, thornplants, monstermaker.** Same migration, later, once this proves out.
- The `_pending_entity_state` parking stays as the backstop for everything still on the RPC path.

## Design

**1. Per-entity sync properties.** `_spawn_dyn_entity` (`main.gd:2144`) builds one
`SceneReplicationConfig` for *all* dyn entities — adding `:is_ridden` there would break
projectiles that lack it. Give the spawned node an optional declaration:

```gdscript
# dragon.gd
func net_sync_properties() -> PackedStringArray:
    return PackedStringArray([":is_ridden", ":anim_name"])
```

and in `_spawn_dyn_entity`, append those paths to the config after the `NetInterp:*` ones.
Paths are relative to the synchronizer's `root_path` (its parent, the entity), so a leading
`:` addresses a property on the entity itself. This is the seam every later migration reuses.

**2. `is_ridden` becomes real state with a setter.**

```gdscript
var is_ridden := false:
    set(value):
        if is_ridden == value: return
        is_ridden = value
        _apply_ridden()
```

`_apply_ridden()` does what `_apply_sync_state` does today — collision layer, model
offset, animation — and runs on **both** sides, replacing the server's explicit
`_update_animation()` calls. The three `sync_notify()` sites become `is_ridden = (_rider != null)`,
a 1:1 mapping: those are exactly the mount/dismount/state-change points.

**3. `anim_name` for the one case that isn't derivable.** Ridden ⇒ `flying_cycler` and
unridden-on-floor ⇒ `idle_1` both follow from `is_ridden`, but the server also plays
`fall_cycler` while an unridden dragon falls (`dragon.gd:162`), which the client can't
derive. Replicate the animation name and drop `anim_pos`: the dragon's clips are looping
cyclers, so phase alignment is invisible — and dropping it removes a re-seek that currently
fires twice a second.

**4. Godot property writes invoke GDScript setters**, so no signal wiring is needed —
unlike `NetInterp`, which uses `synchronized` because the bridge must react.

## Risks

1. **State applied before `_ready`.** This trap has already bitten twice in this area
   (the deferred flush, and the registrar-before-tree-add). `_apply_ridden()` must tolerate
   a null `_model`/`_anim_player`, and `_ready` must call it once after building the model.
   Non-negotiable — it is the most likely way this ships broken.
2. **Replication mode is not a free choice — it must be `ALWAYS`.** goldnet picks slots
   by `property_get_sync()` (`goldnet_multiplayer.cpp:889-892`), and measured against
   Godot 4.7 that flag is true for `ALWAYS` **only**:

   | mode | `property_get_sync` | `property_get_spawn` |
   |---|---|---|
   | `NEVER` | false | true |
   | `ALWAYS` | **true** | true |
   | `ON_CHANGE` | false | true |

   So an `ON_CHANGE` property is invisible to goldnet and would never replicate on the
   default transport — the same bug in a new costume. Use `ALWAYS`; under goldnet an
   unchanged slot is skipped entirely, so it costs nothing while idle. `spawn` is true
   for every mode, so the spawn-time value rides the spawn regardless.
3. **The shared dyn config.** The per-entity extension must be additive; a typo'd path
   resolves to nil and silently syncs nothing. Verify projectiles/corpses still replicate.
4. **Verification is live-server only.** No single-process test observes any of this —
   the same blind spot behind all three ww_chasm bugs.

## Verification

- In-process: `is_ridden = true/false` flips `collision_layer` (0 ↔ `MASK_ENTITY`) and,
  with a stub model, the `-1.0` offset; `net_sync_properties()` paths resolve against a
  built Dragon.
- Live: client mounts on a dedicated server — dragon sits correctly, animates, is
  non-solid; a second player sees the same; fly out of and back into PVS and confirm the
  state is right on re-entry (the case the RPC path never handled).
- Bandwidth: dyn-entity traffic before/after with an idle dragon on the map. The 0.5 s
  timer's removal should be visible; worth capturing since the goldnet work tracks KB/s.

## Effort

~50 lines changed, ~15 deleted, across `dragon.gd` and `_spawn_dyn_entity`, plus a test.
The value is the pattern: after this, each remaining `sync_entity_state` user is a
mechanical repeat, and when the last one is gone the RPC, the parking, the flush, and
`MAX_PENDING_ENTITY_STATE` all delete.
