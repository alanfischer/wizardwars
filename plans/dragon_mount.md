# Dragon Mount

Reintroduce the rideable dragon from the original Wizard Wars. A normal wizard
mounts a dragon, gains flight + a fire-breath attack, and reverts to their
normal element/loadout on dismount. Maps like `ww_chasm` will use this for
"dragon rider team" starts.

## Original behavior (`code/src/DLLS/MONSTERS/DRAGON.CPP`)

`CDragon` is a `CBaseMonster` that doubles as a vehicle. Two map-keys:
`hostile` (1 = attacks non-team players, AI mode) and `mountable` (1 = player
can press Use to ride).

**Mount path (`CDragon::Mount`)**
- Dragon swaps to `models/v_dragon.mdl`, player viewmodel = same.
- `pev->aiment = pPlayer; movetype = MOVETYPE_FOLLOW` — dragon is parented to
  the player's hull.
- Player's active weapon holstered, max speed bumped to 550.
- Physics keyvalue `dragon=1` set on player — pmove uses flight-style movement
  (no gravity, free vertical).
- `MSG_ONE` `Dragon` HUD message sent to rider with `(health%, flame%)`. HUD
  widget (`dragonstatus.cpp`) draws two bars, plays flap sound on ascent.
- Dragon HP 500, flame 50, regen +6 every 2s.

**Update loop (every 0.1s)**
- Hold `IN_ATTACK` → `ShootFire()` spawns `proj_dragonfire` (1400 fwd vel,
  randomized spread). Projectile is invisible, on contact does
  `RadiusDamage(30, 180u, DMG_BURN|DMG_BLAST|DMG_SLOWBURN)`.
- Sequence picked from rider's vertical velocity (flap up vs glide).
- Flame regen, HUD bar resync.

**DeMount**
- Restores walk speed, dragon back to `models/dragon.mdl`, clears `dragon`
  pmove key, +100 z-velocity ejection, restores last weapon via
  `SelectLastItem()`.

**`weapon_dragonbreathspell`** — same `proj_dragonfire`, .1s cadence, 2 ammo
each. Standalone spell (used elsewhere, not part of this work).

**`info_dragonrider_spawn` (ww_chasm)** — spawns with `team_no=3/4`, four per
team. Rider mounted at spawn time. Map has both these *and* normal team
spawns; on death you respawn at a normal spawn (no fresh dragon).

## Architectural fit

Closest existing analog is **bear morph** (`player.gd:266-300`). Player's
`element` is preserved unchanged; mount only overrides `weapons[]`, model,
speed, and movement context. Dismount calls `set_element(element)` to rebuild
the original loadout. Dragon HP / flame live on the dragon entity, not the
player.

Assets already imported (no work needed):
- `models/player/dragon.mdl` — 3rd-person rider+dragon combined
- `sprites/hud_dragon.spr` — HUD flame/health sprite
- `sounds/monster/dragon/{fly1,idle1,pain1,die1,attack1}.wav`
- `sounds/spells/dragonfire.wav`

Currently `info_dragonrider_spawn` is aliased to `InfoPlayerSpawn`
(`main.gd:148`) — it's a normal spawn point; the mount mechanic is missing.

## Pieces

### 1. Flight movement (`addons/pmove/...`)

Riskiest piece, build first. Existing `levitate` is "softer gravity" — not
flight; pitch needs to drive vertical velocity directly.

Cleanest spot is a new branch in `player_movement_context.gd`: when
`_flying`, swap to a dedicated `DragonFlightMovement` path that reads
`cmd.pitch` / `cmd.move_forward` to produce 3D velocity. No gravity, no jump,
no crouch. Standard server-authoritative flow (no special prediction work —
the existing `ServerMovement` queue + reconciliation handles it).

Toggle is a player-side flag `_flying`, set/cleared in `mount_dragon` /
`dismount`. No new `cmd.custom_flags` bit needed (the player's mount state is
authoritative).

Prototype with a debug toggle (e.g. console command or temp keybind) before
building anything else — if the flight feel is wrong, the rest is wasted.

### 2. `DragonBreathWeapon` + `DragonFire` projectile

Mirrors `FireballWeapon` / `Fireball` (`src/weapons/fireball*.gd`). Differences:
- ~0.1s cadence (auto-repeat while held)
- Drains the dragon's flame pool, not the player's mana
- 30 damage / ~4.5m radius (matches original 180u)
- Fire DoT (existing `GameConsts.DamageType.FIRE` path)
- Owner attribution = the rider (kills score on rider's scoreboard)
- Sound `spells/dragonfire.wav`
- Stop firing on dismount

The weapon holds a ref to its dragon so it can read/write flame and stop on
dismount.

### 3. `Dragon` entity

`src/dragon.gd`, classname `dragon`. Pattern after
`SentryCrystal` — `EntityBase`, registered for sync. State:

```
health, max_health (500)
flame, max_flame (50), flame_regen (+6 / 2s)
rider: Player or null
team_no, hostile, mountable    # parsed from keyvalues
```

Press-Use interaction: `_on_use(player)` → `_mount(player)` if `mountable`,
team-compatible (`team_no == 0` or `player.team == team_no`), and not already
ridden. AI / `hostile=1` mode is out of scope for this pass — only mountable
free-standing dragons.

While mounted, hide the entity's visual (the rider's player model becomes the
dragon — see "model strategy" below). Position-follow the rider so AoE damage
to the dragon hits at the right spot.

Damage: dragon takes hits independently of rider. At HP 0, force-dismount and
play death anim/sound, then queue_free.

### 4. `Player.mount_dragon(dragon)` / `dismount(reason)`

Mirrors `become_bear` / `become_wizard`:

```
mount_dragon(dragon):
  _mounted_dragon = dragon
  weapons = [DragonBreathWeapon.new(dragon)]
  current_weapon_idx = 0
  _flying = true
  speed_multiplier = ~2.2
  _load_player_model("dragon")     # uses models/player/dragon.mdl
  NetworkManager.sync_dragon_mount.rpc(peer_id, dragon._entity_id, true)

dismount(reason):
  _flying = false
  velocity.y += 4.0                # +100 GS units * SCALE_FACTOR ejection
  _stop_all_attacks()
  set_element(element)             # rebuilds wizard loadout / model / speed
  if _mounted_dragon: _mounted_dragon.rider = null
  _mounted_dragon = null
  NetworkManager.sync_dragon_mount.rpc(peer_id, -1, false)
```

Triggers for dismount: dragon HP→0, rider HP→0 (death), manual dismount key
(reuse Use? or a new bind), fall-out-of-world (already handled by existing
take_damage(9999)).

Late-join sync: extend `sync_state_to_peer` to re-emit `sync_dragon_mount` if
`_mounted_dragon != null`, like bear morph does.

### 5. `info_dragonrider_spawn` activation

Promote it from an alias to a flagged variant of `InfoPlayerSpawn`. Add
`is_dragon_spawn: bool` set when classname is `info_dragonrider_spawn`.

In `_on_team_class_selected` / `_host_respawn` (server-side spawn path), when
the picked spawn is a dragon spawn:
1. Spawn a `Dragon` at that spot, `team_no = sp.team_no`,
   `mountable = 1`.
2. Call `player.mount_dragon(dragon)` immediately.

If the rider dies, they respawn at a regular team spawn next time (chasm has
both). The dragon they were on persists until killed or empty timeout.

### 6. Dragon HUD

Two bars (dragon HP + flame). Show only while mounted. Hooked to a
`sync_dragon_status(hp_pct, flame_pct)` RPC at ~2Hz from the dragon entity to
the rider only. Add to `src/systems/hud.gd` next to the existing health/mana
sections.

Sprite asset already exists (`sprites/hud_dragon.spr`).

## Open design questions

**Model strategy.** Original has separate `models/dragon.mdl` (standalone) and
`v_dragon.mdl` (mounted). The new project has one combined
`models/player/dragon.mdl` (rider+dragon). Simplest: while mounted, hide the
`Dragon`'s visual and swap the rider's player model to `dragon`. The
entity still owns HP/flame.

For the unmounted free-standing dragon visual, we need *some* model — could
reuse `models/player/dragon.mdl` with the rider hidden via skin/anim, or
import `models/dragon.mdl` if it exists in `wizard-wars/`. Defer until we
build #3.

**Rider damage routing.** Two HP pools or one? Original game had both
independent. Keep that: rider's player damage routes normally (and on death
dismounts via the death path); dragon damage drops the dragon HP and forces
dismount at 0. AoE that hits both hits both.

**Mount/dismount input.** Press Use to mount. Press Use again to dismount? Or
a separate key? Original used Use only for mount; dismount was implicit
(death). Easiest start: Use to mount, no manual dismount — rider gets off
when dragon or rider dies. Add a manual dismount later if needed.

**Friendly fire / team checks.** Match `IRelationship`: `team_no=0` dragons
are mountable by anyone; otherwise only same-team can mount. Skip hostile-AI
dragons (out of scope this pass).

**Network model.** Rider drives position via the existing server-authoritative
path. Dragon entity has no `ServerMovement` of its own — it just follows the
rider in a `_physics_process` (host-side `global_position = rider.global_position`).
Matches original `MOVETYPE_FOLLOW`.

## Build order

1. **Flight movement** — prototype with debug toggle, validate feel.
2. **DragonBreathWeapon + DragonFire** — flying-firebreathing wizard
   activated via debug toggle.
3. **Dragon entity + mount/dismount** — proper mount mechanic, free-
   standing dragons place-able from a test map.
4. **info_dragonrider_spawn** — chasm dragon-rider teams work end-to-end.
5. **Dragon HUD** — visible flame/HP bars.

Each step ships a usable result on its own.
