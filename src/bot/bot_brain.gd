extends Node
## Host-only AI controller for a single bot.
##
## Navigation follows the hand-authored waypoint graph (WaypointGraph): A* to the objective,
## then steer waypoint-to-waypoint, honoring baked jump/crouch flags. Maps with no waypoint file
## fall back to local steering — whisker raycasts plus wall-follow (see _local_steer). Combat is
## opportunistic: fires at any enemy in range/LOS while moving, without abandoning the objective.
## Each tick enqueues one InputCommand into the bot puppet's ServerMovement. Attached as a child
## of the puppet by BotSystem.add_bot; BotSystem.tick() drives it.

const InputCommand = preload("res://addons/pmove/input_command.gd")
const WaypointGraph = preload("res://src/bot/waypoint_graph.gd")

const ENGAGE_RANGE := 30.0      # open fire within this distance (metres)
const FOV_COS := 0.34           # ~70 deg half-angle sight cone: a bot can be flanked. Wider than
								# a human's because the cone is horizontal, so an enemy well above
								# or below costs angle it shouldn't.
const VIS_MEMORY := 3.0         # how long a lost (or unseen but felt) enemy is still faced
## How often sight is re-acquired (Combat.find_homing_target: a group walk plus a visibility
## ray per candidate). A bot used to ask on all 60 ticks a second, alone in the game — every
## monster, missile and cloud self-gates between 0.1s and 0.5s. Holding the answer is safe
## because what the trigger depends on still runs every tick: the shot is traced along the real
## aim line (the fire-line gate below) and the aim follows the target's live position. And 0.1s
## is under the reaction delay owed a fresh target (_reaction_time, 0.15-0.55s), so a sighting
## too brief for this to catch was never one the trigger could have answered.
##
## The phase is rolled per bot at setup and on respawn, so the acquisitions spread across ticks
## even after a round reset brings every bot back on one of them.
const SENSE_INTERVAL := 0.1
## Projectile lead (see _lead_point). Every spell that flies is a straight-line, constant-speed
## projectile with no gravity (Projectile._physics_process), so where it WILL be is exactly
## solvable — and a bot that fires at where a target IS cannot hit anything that moves. Motion is
## measured as displacement rather than read off CharacterBody3D.velocity, which is what a body
## ASKED for: a target leaning on a wall reports full speed and travels nothing, and leading that
## aims into the wall beside it.
const LEAD_EASE := 8.0          # per-second rate the measured target velocity eases at, so a juke
								# takes ~0.12s to reach the aim. Being a beat late on a direction
								# change is where a human's misses come from.
const LEAD_MAX_T := 1.5         # cap on predicted flight time, so a target at the far edge of a
								# slow spell's reach isn't led halfway across the map
const ARRIVE_OBJ := 0.7         # close enough to touch a flag/cap
const LADDER_MOUNT_NEAR := 0.5  # how close to the mount node the bot must be before it grabs the
								# rungs — off to the side it climbs the wall beside the shaft
const LADDER_CENTER_PULL := 0.6 # how hard the climb steers toward the shaft column while pressing
const LADDER_TOPOUT := 0.3      # climb until this far ABOVE the node being headed for, so the step
								# off clears the floor's edge instead of jamming under it
const LADDER_COLUMN_NEAR := 2.5 # how close a remembered ladder axis must be to climb its column
								# into the rungs (0 = straight in, which jams off-centre climbs)
const LADDER_ARRIVE := 1.0      # 3D arrival radius for a FL_LADDER node — small so the bot climbs
								# near the top before the route advances to the landing
# Lifts (see WaypointGraph.FL_LIFT). Riding is the one leg of a route where standing still is
# correct, and almost every anti-stuck mechanism below exists to punish exactly that.
const LIFT_CENTER_NEAR := 0.35  # close enough to the deck's own column to just stand there
const LIFT_COLUMN_SCAN := 40.0  # how far up and down a lift waypoint's column to look for the deck
# Where to wait for a deck that is at the other stop: a band just outside the deck's own footprint.
# Both edges of it matter. Any closer and the bot is IN the shaft, which is what the descending deck
# gets blocked on — CFuncPlat::Blocked reverses, the plat returns to the top, comes back down onto
# the same bot, and neither ever gets anywhere (measured on ww_storm: an endless -3.08 <-> 2.40
# bounce). Any further and the bot is outside the plat's call volume — the footprint grown by
# TOUCH_MARGIN — so it is waiting for a lift nothing is asking to come.
const LIFT_CLEAR := 0.5         # nearest the footprint the bot may stand
const LIFT_CALL_REACH := 0.85   # ...and furthest, so its hull still overlaps the call volume
const LIFT_APPROACH := 3.0      # outside this the ride steering keeps its hands off: the bot is
								# still walking up to the lift, and that is ordinary route-following
								# with all the obstacle avoidance the straight line does not have
const LIFT_ON_DECK := 0.4       # feet this close to the deck's surface = aboard it
const LIFT_BOARD_STEP := 0.9    # ...and this close, with the lift settled, = close enough to board
# Grace for a ride before giving up on it: the call, the wait at the far stop, and the travel
# itself at a slow lift's ~0.5 m/s.
const LIFT_PATIENCE := 8.0
const LIFT_PATIENCE_PER_M := 2.0
## How long a ride attempt is remembered across ticks that are not riding. The patience above is
## the whole safety net for a lift that never arrives, and it used to be unreachable: _riding is
## recomputed every tick from "is the current route node a lift", so a single re-path that moved
## route_i off that node ran _clear_ride() and zeroed the clock, and coming back set
## rid_now != _ride_id which zeroed it again. A ride that never completes was therefore retried
## for ever. Measured on a 2v4 ww_storm match: four of six bots spent ~40% of five minutes in the
## ride state, re-entering it 9-14 times each, and the grail carrier parked 10.8m from its own
## capture point for the last 170 seconds while the score never moved.
##
## So the attempt is now accounted against the NODE and survives brief exits; only genuinely
## going somewhere else for this long forgets it.
const RIDE_FORGET := 4.0
const VERT_ARRIVE := 1.6        # waypoint counts as reached only within this height, so a drop/climb
								# node above/below isn't skipped early (just over step_height)
const TURN_ARRIVE := 0.5        # arrival radius where the route turns hardest — see _straightness
const PASSED_WP := 0.35         # receding this much from a node we already closed on counts as
								# having passed it — see _passed_wp
const FALL_REROUTE := 1.4       # a grounded bot this far BELOW its route node, roughly overhead, is
								# under the route rather than on it: no edge in the graph climbs more
								# than JUMP_UP (1.2m), so it fell off a ledge or slid off a ramp.
								# Ladder/water climbs are excluded — being below is normal there
const EYE_HEIGHT := 1.6         # stand_eye (see movement_config)
const STUCK_HOP := 2.5          # no-progress time before hopping to clear a lip/corner
const STUCK_SKIP := 4.0         # no-progress time before giving up on the current waypoint
const HOP_DWELL := 0.15         # min continuous ground time between discretionary hops, so the bot
								# doesn't re-jump on every landing frame (bounce-lock)
const BL_WINDOW := 2.0          # bounce-lock detection window (s)
const BL_MOVE := 2.5            # horiz progress over the window below which we count as confined (m)
const BL_GROUND_FRAC := 0.4     # if grounded less than this fraction while confined, it's bouncing
const BL_REST := 1.5            # how long to fully suppress hops once bounce-lock trips (s)
# Ladder-stall reroute: a bot stuck on a ladder (foot gap, unclimbable slab) plateaus in height, so
# we pile an escalating avoid-penalty on its nodes and re-path to a different way out.
const LAD_STALL_T := 2.2        # no net height gain for this long while on a ladder = stuck
const LAD_STALL_RISE := 0.6     # height gain that counts as real climb progress (resets the timer)
const LAD_AVOID_STEP := 24.0    # weight_scale added to the stuck ladder's nodes per stall (escalates)
const LAD_AVOID_TTL := 14.0     # how long an avoid-penalty lingers before it's cleared (s)
const LAD_AVOID_RADIUS := 4.0   # also penalize graph nodes within this of the stuck ladder axis
const STALL_AVOID_STEP := 24.0  # penalty added to a route node the bot stalled trying to reach
## Local-navigation rescue (see _rescue_t). Every other recovery mechanism in this file answers a
## failing leg by asking the GRAPH again — re-path, penalise a node, or teleport to spawn. None of
## them navigates, so where the graph is wrong there is nothing that can make progress anyway, and
## the bot cycles: fail, re-query, get the same answer, fail. This is the rung that is missing.
##
## It is a STATE on the failure path, not another writer of wish_dir. Route following is untouched
## while it is working; only once the no-progress watchdog has been unhappy for RESCUE_AFTER does
## local navigation take the wheel, aimed at the waypoint the bot cannot reach, for at most
## RESCUE_MAX. That ordering is the whole design: four earlier attempts put contact-navigation
## inline in _dodge where it ran on every tick, and each one fought the manoeuvres that need
## sub-metre placement (a lift's 0.35m call band, a ladder mount) and cost more than it earned.
const RESCUE_AFTER := 2.5        # no-progress seconds before local nav takes over
const RESCUE_MAX := 6.0          # ...and how long it may keep it before the give-up runs anyway
const WP_GIVEUP := 6.0           # seconds of no closing on the current waypoint before we give up
## The same clock while an enemy is in mind, where holding position and shooting is the job. It used
## to be no clock at all, and that made the give-up — and the penned rescue it feeds — unreachable
## for any bot that could SEE the map it was stuck on: ww_golem spawns team 1 on a balcony over the
## town whose only graph exit is a step up the bot can't make, so it hopped at the step for a whole
## 180s soak with enemies in view the entire time and nothing ever came for it. A long fight earns
## patience; it doesn't earn forever.
const WP_GIVEUP_FIGHT := 20.0
const WP_PROGRESS := 0.4         # closing this much on it counts as progress and resets the clock
## Objective commitment. _choose_objective rebuilds its answer from scratch every tick, so any
## condition that flickers — an enemy crossing the HUNT_NEAR ring or the edge of the sight cone, a
## team-mate picking up the flag — moves the goal across the map, and the bot physically reverses.
## Measured on ww_ravine: one bot alternated between two objectives 78m apart almost every second
## for 17s, route length flipping 163 -> 11 -> 164 -> 11, and across six bots that was 57 switches
## in 240s. It reads exactly as what it is — bots running in circles in one spot.
##
## So a new objective has to be worth the turn. A goal near the one in hand is the same intent
## with a drifting target and is tracked immediately; a distant one has to wait out OBJ_HOLD
## unless something decisive happened (picking the flag up or losing it, which clears the hold).
## The escort latch below is the same idea applied to one case; this is the general rule.
const OBJ_HOLD := 3.0            # seconds before a distant objective switch is allowed
const OBJ_SWITCH_DIST := 8.0     # beyond this from the held goal counts as a switch, not a drift
const ESCORT_NEAR := 6.0         # already this close to our dropoff → no point standing on it
const ESCORT_REARM := 10.0       # ...and don't go back to escorting until this far from it again.
								 # Without the gap the single ESCORT_NEAR test flips the objective
								 # every time the bot crosses one ring: outside it the goal is the
								 # dropoff, inside it the goal falls through to the nearest enemy,
								 # and those two lie in opposite directions. A bot that arrives at
								 # the ring reverses on every crossing and sprints on the spot —
								 # measured on ww_ravine, one bot burned 48s at 8 m/s at exactly
								 # 5.97m from its own dropoff, and every clustered "stall" episode
								 # in a 600s soak sat between 5.5m and 6.0m of it.
const WEDGE_T := 12.0            # trying to move, but not moving AT ALL for this long = wedged in
const WEDGE_DIST := 0.15         # world geometry; displacement under this over the window counts
const PENNED_GIVEUPS := 4        # WP_GIVEUPs in a row without leaving PENNED_DIST = penned: the
const PENNED_DIST := 2.0         # bot can move, just not anywhere the graph leads

# Re-path throttle. A* costs O(map size) (path_ids re-stamps every waypoint's weight), so it must
# stay an occasional event: a route that runs out near a close objective, or an objective that
# keeps moving, would otherwise re-query every tick. While throttled the bot steers straight at it.
const REPATH_MIN := 0.4         # min seconds between A* queries
const REPATH_FAIL := 1.5        # longer backoff after a query that found no route (objective
								# off-graph or in another component — an exhaustive search)
const ZONE_RECHECK := 0.5       # how often the capture-zone objective is re-evaluated (s)

# --- Roaming (maps with no objective a bot can act on — see _roam_target) ---
const ROAM_NEAR := 2.5          # roam spot counts as visited within this horizontal distance (m)
const ROAM_MIN := 15.0          # a new spot must be at least this far off, or "touring" the map
								# degenerates into shuffling between neighbouring waypoints
const ROAM_GIVEUP := 40.0       # seconds on one spot before picking another regardless (the route
								# may be failing, or the way there blocked by a mover)
const ROAM_TRIES := 12          # random waypoints sampled per pick; the farthest wins
const HUNT_NEAR := 20.0         # while roaming, break off for an enemy we know about this close

# --- Graph-less local navigation (maps without a waypoint file — see _local_steer) ---
const LOCAL_NAV_MIN := 2.5      # only steer locally beyond this distance to the objective (m)
const PROBE_DIST := 3.0         # forward clearance that counts as "path open" (m)
const PROBE_LOW := 0.75         # probe ray heights: low sits above step_height (0.55) so
const PROBE_HIGH := 1.5         # steppable lips are invisible; high catches walls/lintels
const STAIR_GAP := 0.45         # low/high hit-distance spread that reads as climbable stairs
## How deep a drop local nav will take when it is working a route LEG rather than heading for a
## far-off objective. Between two nodes something already said are connected, a descent is part of
## the route, not a pit — but "part of the route" is not "any depth", so this is the baker's own
## ceiling for a one-way drop it will link (WaypointBaker.DROP_MAX): a survivable fall.
const DROP_MAX_LEG := 8.0
const DROP_MAX := 4.5           # ledge depth avoidance won't walk off (drops toward a lower
								# objective, and anything while swimming, are still allowed)
## A waypoint this much above the bot is a climb, and climbs are steered dead-centre (see the
## wander offset in tick): anything taller than a step means stairs or a ledge, where the walkable
## line is narrow and the per-waypoint roll is what puts a bot beside it instead of on it.
const CLIMB_PRECISE := 0.6
## Contact navigation (see _dodge). The bot's normal way of getting between two waypoints is to
## walk at the next one and, when something is in the way, turn parallel to it and keep walking —
## the model the original HPB bot used (BotCantMoveForward + BotTurnAtWall, bot_navigate.cpp) and
## the one every hand-authored .HPB_wpt file was drawn for. Those files place waypoints 5-10m
## apart precisely because the bot was never required to walk the straight line between two of
## them. Measured on ww_keep's file: of the 57 legs a straight walk cannot finish, 54 (95%) are
## traversable by turning at the wall.
##
## The jitter is HPB's: BotTurnAtWall added a random 5-20 degrees half the time, without which two
## bodies meeting the same corner pick the same way out and stay locked together.
const SLIDE_JITTER_MIN := 5.0
const SLIDE_JITTER_MAX := 20.0
const WF_TIMEOUT := 14.0        # wall-follow tries the other hand after this long (s)
const WHISKERS: Array[float] = [0.0, 0.5, -0.5, 1.05, -1.05, 1.6, -1.6]  # fan angles (rad)
## What a bot can see when it looks where it is going. Players are SOLID to each other
## (RemotePlayer.collision_mask includes MASK_PLAYER) but were missing from every navigation
## probe, so the one obstacle class that moves was invisible: a bot walked into a player and
## leaned there until an anti-stuck hop shook it loose, and a player standing on the waypoint a
## bot was heading for blocked it from ever arriving — _wp_min_d never falls below _arrive_wp,
## so the _passed_wp escape cannot fire and the bot laps the node at full speed. From the far
## side of a fight that reads as a bot circling you.
const PROBE_MASK := GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY \
		| GameConsts.MASK_PLAYER
## The floor test is the exception and must stay world-only: it asks "is there ground ahead",
## and a player standing in the pit would answer yes.
const FLOOR_PROBE_MASK := GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
## What stops a shot (see the fire-line gate in tick). MASK_WORLD is exactly what a projectile
## collides with — no clip brushes, no sky — plus the solid placed entities a thornplant or a
## beanstalk puts in the way. Deliberately NOT players: neither the target nor anyone standing
## near it is a reason to hold fire, and on these layers a player's capsule and its per-bone
## hitboxes are invisible anyway.
const SHOT_MASK := GameConsts.MASK_WORLD | GameConsts.MASK_ENTITY

const CMD_JUMP := InputCommand.FLAG_JUMP
const CMD_CROUCH := InputCommand.FLAG_CROUCH

var _bot: CharacterBody3D = null
var _main: Node = null
var _graph: WaypointGraph = null
var _seq := 0
var _fire_cooldown := 0.0
## Weapon whose trigger we're currently holding, or null. A bot's commands carry no attack button
## for FireControl to see released, so without this nothing ever calls stop_firing.
var _firing_weapon: Weapon = null
## Time left before an un-held trigger is released. Refreshed by every successful shot.
var _firing_hold := 0.0
var _cap_pos := Vector3.INF
var _spawn_pos := Vector3.ZERO   # bot's own-base location (set at setup), picks the cap point
var _is_ctf := false             # map mode (computed in setup): CTF maps have carriable flags
var _my_flags: Array = []        # this bot's grabbable flags (static for the map, found at setup)
var _obj_is_control := false     # current objective is a control point (→ hop to contest it)
var _escort_done := false        # reached our dropoff this life; see ESCORT_REARM
var _cp_positions: PackedVector3Array = PackedVector3Array()  # sequential capture points (ww_chasm's
								 # PotatoC point1..N cap-volume centres, ordered; empty off such maps)
# Territorial-control capture zones this bot's team can take (ww_monoliths' warpath runes). See
# _capture_zone_target. Empty off such maps.
var _cap_zones: Array = []
var _cap_zone_pos: PackedVector3Array = PackedVector3Array()
var _zone_pos := Vector3.INF     # last chosen zone centre (INF = nothing takeable right now)
var _zone_t := 0.0               # countdown to the next zone re-evaluation
var _roaming := false            # current objective is a roam spot, not a real goal
var _roam_pos := Vector3.INF     # the spot (a graph waypoint), held until reached or timed out
var _roam_t := 0.0               # time spent heading for it (see ROAM_GIVEUP)
var _obj_held := Vector3.INF     # objective the bot has committed to (see OBJ_HOLD)
var _obj_held_t := 0.0

# --- Human-like imperfection (per-bot "personality", rolled once at setup) ---
var _skill := 0.6                # 0 = sloppy … 1 = crack shot; scales the knobs below
var _reaction_time := 0.3        # delay before firing on a freshly-acquired target (s)
var _turn_rate := 9.0            # max look turn speed (rad/s) — no instant snapping
var _aim_err := 0.05             # aim-wander cone half-angle at close range (rad)
var _lead_frac := 0.6            # how much of the exact projectile lead this bot applies
var _face_yaw := 0.0             # current (rate-limited) look yaw the bot actually holds
var _face_pitch := 0.0           # current (rate-limited) look pitch
var _reaction := 0.0             # countdown until the current target may be fired on
var _prev_enemy: Node3D = null   # last acquired target, to detect fresh acquisition
var _known: Node3D = null        # last enemy seen or felt; faced (not fired on) once out of sight
var _known_pos := Vector3.INF    # where it was last known to be
var _known_t := 0.0              # memory left on it (see VIS_MEMORY)
var _wander := Vector2.ZERO      # current aim-error offset (yaw, pitch), drifts over time
var _wander_to := Vector2.ZERO   # value _wander is easing toward
var _seen: Node3D = null         # the target the last acquisition saw, up to SENSE_INTERVAL ago
								 # (null while only remembered) — what the trigger and the lead
								 # are allowed to use
var _sense_t := 0.0              # countdown to the next acquisition (see SENSE_INTERVAL)
var _lead_tgt: Node3D = null     # target _lead_vel is measured against (see _track_target)
var _lead_pos := Vector3.INF     # ...its position last tick
var _lead_vel := Vector3.ZERO    # ...and its eased measured velocity
var _nav_turn := 14.0            # max look turn speed while just navigating (rad/s) — faster
								 # than combat tracking, but corners still read as turns
var _route_var := 0.45           # A* weight perturbation strength — route "adventurousness"
var _route_salt := 0             # seed for the route perturbation; rerolled on respawn and on
								 # real objective switches, held while chasing a drifting one
var _wp_slop := 0.6              # max lateral offset steered from waypoint centres (m)
var _arrive_wp := 1.8            # advance to the next waypoint within this horizontal distance

# Stateful route along the waypoint graph (recomputed only on objective change / strayed).
var _route: PackedInt64Array = PackedInt64Array()
var _route_i := 0
var _route_obj := Vector3.INF
var _wp_off := Vector3.ZERO      # rolled lateral offset for the current waypoint
var _wp_off_i := -1              # route index _wp_off was rolled for (-1 = needs a roll)
var _axis_seen := Vector3.INF    # last FL_LADDER axis node the route offered (see hold_climb_axis)
var _ledge_sides := 0            # bit 1 = deep drop off the left of this tick's heading, bit 2 the
								 # right. Probed once per tick and read by everything that decides
								 # how loosely the route may be followed (see _side_drops)
var _riding := false             # heading for a lift deck (see LIFT_PATIENCE). Recomputed in the
								 # route block; blocks running before it read last tick's value
var _ride_id := -1               # lift node the steering state is bound to
var _ride_try_id := -1           # lift node the PATIENCE is accumulating against (see RIDE_FORGET)
var _ride_try_t := 0.0           # ...and the total time spent trying to get past it
var _ride_idle_t := 0.0          # how long since we last rode it; past RIDE_FORGET the try resets
var _ride_patience := 0.0        # seconds allowed for this ride, from its travel when it latched
var _ride_lift: Node3D = null    # the mover the FL_LIFT node belongs to (see _bind_lift)
var _ride_box := Rect2()         # its deck's XZ footprint, in the mover's OWN frame (a platrot
var _ride_top := 0.0             # spins as it travels) and its deck's top surface in that frame
var _wedge_pos := Vector3.INF    # anchor for the wedge detector (see WEDGE_T)
var _wedge_t := 0.0
var _penned_pos := Vector3.INF   # where the last WP_GIVEUP happened (see PENNED_GIVEUPS)
var _penned_n := 0
var _rescue_t := 0.0             # time local nav has held the wheel for this leg (see RESCUE_AFTER)
var _rescue_id := -1             # route node it was engaged for; a new node ends it
var _wp_try_id := -1             # waypoint the no-progress watchdog is timing (see WP_GIVEUP)
var _wp_try_t := 0.0             # time spent not closing on it
var _wp_best_d := INF            # closest we have come to it
var _was_carrying := false       # carry state last tick; a change re-paths at once (see tick)
var _wp_min_id := -1             # waypoint _wp_min_d is measured against (see _passed_wp)
var _wp_min_d := INF             # true closest approach to it, untouched by WP_PROGRESS hysteresis
var _was_dead := false           # detects the death → respawn edge to reroll the route
var _repath_t := 0.0             # cooldown left before another A* query is allowed (see REPATH_MIN)

# Anti-stuck: the waypoint edges are walkable, so a hop is enough to clear small lips/corners.
var _stuck_t := 0.0
var _win_t := 0.0
var _win_pos := Vector3.INF

# Bounce-lock guard (see _hop_gate): unpaced discretionary hops fire on every landing frame, so a
# bot confined to a raised spot (e.g. ww_chasm's control nub) goes airborne continuously and just
# bounces in place. These pace/suppress the hops so it can ground and steer out.
var _ground_dwell := 0.0         # continuous time on_floor (reset on a hop or when airborne)
var _bl_pos := Vector3.INF       # confinement-window anchor
var _bl_t := 0.0                 # time in the current window
var _bl_ground := 0.0            # grounded time accumulated in the window
var _bl_rest_t := 0.0            # while > 0, hops are fully suppressed (bounce-lock tripped)

# Graph-less local steering (see _local_steer): whisker avoidance + wall-follow state.
var _local_nav := false          # this tick steers straight at the objective (no waypoint)
## Which way round the obstacle, remembered. Contact navigation and the ladder exit both choose
## between two OPPOSITE directions every tick — along the wall one way or the other — from a
## heading that itself wobbles, so both flip 180 degrees whenever it does. Measured on ww_ravine:
## the ladder exit reversed on 1038 of its 1399 ticks (8089 deg/s while active) and contact
## navigation on 1275 of 5711, together about three quarters of every violent turn the bots made.
## A side, once picked, is kept while the bot is still against the same surface.
## A body cannot change the direction it is travelling instantly, and neither should the command
## that tells it to. Latching the side choices above cut how OFTEN the demanded heading reverses
## (505 -> 267 deg/s of jitter, >90 degree reversals 3.9% -> 1.6% of ticks) but not how fast the
## head then moved, which stayed at ~175 deg/s across stock and every fix: nothing limited the
## RATE the command could change, only its frequency, and _nav_turn happily served a 90 degree
## step at up to 917 deg/s. This caps the command. Generous enough to round a corner at a run —
## 6 m/s through a right angle is about 200 deg/s — and far below a whip-round.
const WISH_TURN_MAX := deg_to_rad(360.0)
var _wish_prev := Vector3.ZERO   # last tick's committed heading, for the slew limit
var _wish_yaw := 0.0             # ...and its yaw, which _slew has already computed
var _slide_n := Vector3.ZERO     # surface normal currently being followed (ZERO = not sliding)
var _slide_dir := Vector3.ZERO   # the direction along it already committed to
var _exit_sign := 0              # ladder exit: which way along the rungs, latched
var _avoid_dir := Vector3.ZERO   # committed whisker direction, held briefly so it can't dither
var _avoid_t := 0.0
var _wf_hand := 0                # 0 = not wall-following; +1 = wall on the right, -1 = left
var _wf_dir := Vector3.ZERO      # current wall-follow travel direction
var _wf_t := 0.0                 # time on this wall (hand flips at WF_TIMEOUT)
var _wf_leave_dist := INF        # horiz distance to objective at latch (Bug-style leave test)
var _wf_obj := Vector3.INF       # objective latched for (follow is stale if it moves far)
var _wf_force := false           # anti-stuck: wedged hard → latch/flip on the next steer
# Freeze recovery: position-based (unlike _anti_stuck, which needs the bot actively pushing), so it
# catches a bot producing NO movement at all. While _free_t > 0 we abandon the route and steer
# straight at the objective, hopping, to physically break loose.
var _froze_pos := Vector3.INF
var _froze_t := 0.0
var _free_t := 0.0
var _prog_obj := Vector3.INF     # progress watchdog: objective it's tracking, best (closest)
var _prog_best := INF            # horiz distance reached so far, and time since that improved
var _prog_t := 0.0               # (dodging can move plenty without ever actually closing in)
# Ladder-stall reroute (see LAD_* consts): best climb height reached on the current mount, time since
# it improved, and a per-bot set of graph nodes to route around (node id -> extra weight_scale) with a
# shared time-to-live. Cleared on respawn.
var _lad_best_y := -INF
var _lad_stall_t := 0.0
var _node_avoid := {}                 # node id -> penalty weight fed to path_ids (ladders the bot
								 # can't climb, route steps it can't execute)
var _node_avoid_t := 0.0              # remaining TTL for the whole avoid set
var _steer_pitch := 0.0   # look pitch _steer wants for the goal it was last given
var _probe_n := Vector3.ZERO     # last _probe hit's horizontal normal (see _probe)
var _last_wall_n := Vector3.ZERO # ...and the one _clearance settled on, for contact nav
## Soak profiling: which path _steer took, and which _choose_objective branch answered. Off in
## real matches — these run per bot per tick and nothing but bot_soak ever reads them.
static var diag := false
var steer_tally := {}
var obj_tally := {}
## Whether the bot is under its own route node right now, i.e. it walked off something (see
## FALL_REROUTE). A fall is the one navigation failure that fixes itself, so no watchdog above
## counts it — and from a player's seat it is the most visible thing a bot does wrong, cutting a
## corner off a ramp and having to climb back. Published rather than tallied here: bot_soak's
## _edge already turns a state like this into rising edges bucketed by place and context.
var fell_now := false
var _ray_query: PhysicsRayQueryParameters3D  # reused by every probe ray (built in setup)
var _floor_query: PhysicsRayQueryParameters3D  # world-only twin, for drop tests and the lift bind
var _shot_query: PhysicsRayQueryParameters3D   # the line a shot would really travel (see SHOT_MASK)


## Where the bot is trying to be, and how exactly to be there.
##
## Every manoeuvre the brain performs — walk a route leg, board a lift, mount a ladder, stand on
## a capture point, head for a flag — is expressed as one of these and steered by _steer. Before
## that there were eleven places writing wish_dir directly, and precision was not something the
## steering could SAY: it was four separate features each individually opting out of interfering
## with a lift's 0.35m call band. Any new behaviour had to know about all of them, which is why
## contact navigation took four attempts to add. Here a manoeuvre states its tolerance and the
## navigator respects it, which is how the bot these waypoint files were drawn for did it —
## HPB's arrival radius was 50 GoldSrc units normally and 20-25 at a crouch, jump or ladder node.
## Reset in place rather than reallocated: a Goal is built, steered and dropped inside one tick
## and never escapes, so one per brain does — the same reason _ray_query is a member.
class Goal extends RefCounted:
	var pos := Vector3.INF        # where to be
	var radius := 0.05            # inside this (horizontally) counts as arrived
	var centre := Vector3.INF     # validated line to hug beside a drop (a route node's true spot)
	var precise := false          # execution needs exact placement: no contact-turning liberties
	var free := false             # no waypoint behind it: use the full local navigator
	var rescue := false           # route following failed this leg; navigate to it
	var climb := Vector3.INF      # ladder axis: satisfied by looking up it and pressing forward

	func reset() -> void:
		pos = Vector3.INF
		radius = 0.05
		centre = Vector3.INF
		precise = false
		free = false
		rescue = false
		climb = Vector3.INF


var _goal := Goal.new()   # reused every tick; see Goal


## `skill` forces this bot's aim skill (0 sloppy … 1 crack shot); negative rolls one, which is
## what every bot did before there was a way to ask. See BotSystem.add_bot / the bot_skill var.
func setup(bot: CharacterBody3D, main: Node, graph: WaypointGraph,
		cp_positions: PackedVector3Array = PackedVector3Array(), skill := -1.0) -> void:
	_bot = bot
	_main = main
	_graph = graph
	_cp_positions = cp_positions
	_ray_query = PhysicsRayQueryParameters3D.new()
	_ray_query.collision_mask = PROBE_MASK
	_ray_query.exclude = [bot.get_rid()]
	# Separate query for the floor test and the lift bind, which must not see players.
	_floor_query = PhysicsRayQueryParameters3D.new()
	_floor_query.collision_mask = FLOOR_PROBE_MASK
	_floor_query.exclude = [bot.get_rid()]
	_shot_query = PhysicsRayQueryParameters3D.new()
	_shot_query.collision_mask = SHOT_MASK
	_shot_query.exclude = [bot.get_rid()]
	_spawn_pos = bot.global_position  # set right after spawn_at → this is the bot's own base
	# Classify the game mode and collect this bot's grabbable flags once (both static for the
	# map's lifetime). Same pass finds this team's capture point via `team_no` on a scoring goal;
	# its position is the brush AABB centre (cap brushes carry no `origin`, so the node is at 0).
	for g in GoalSystem.get_all_goals():
		if GoalSystem.is_carriable_flag(g):
			_is_ctf = true
			if g.req_team == _bot.team:
				_my_flags.append(g)
		# Territorial control (ww_monoliths' warpath runes): an info_tfgoal brush volume our team
		# takes by running through it. Not carriable, so the flag branch misses it, and baked
		# graphs carry no FL_CAP node to stand in — without this the bot has no objective here.
		# goal_no != 0 drops the message/effect helper goals sharing the volume.
		elif g is InfoTFGoal and g.is_brush_entity() and g.goal_no != 0 \
				and g.req_team == _bot.team \
				and g.item_is_needed == 0 and g.item_to_give == 0:
			_cap_zones.append(g)
			_cap_zone_pos.append(_goal_center(g))
		if _cap_pos == Vector3.INF and g.item_is_needed != 0 \
				and _bot.team >= 1 and _bot.team < g.team_scores.size() \
				and g.team_scores[_bot.team] != 0:
			_cap_pos = _goal_center(g)
	if not _cap_zones.is_empty():
		Log.info("[Bot] team %d: %d capture zone(s)" % [_bot.team, _cap_zones.size()])
	# Roll a personality so bots aren't identical: skill scales aim, reaction and turn speed;
	# the route/waypoint traits are independent (path preference isn't an aim skill).
	_skill = clampf(skill, 0.0, 1.0) if skill >= 0.0 else randf_range(0.35, 0.9)
	_reaction_time = lerpf(0.55, 0.15, _skill)
	_turn_rate = lerpf(6.5, 12.0, _skill)
	_aim_err = lerpf(0.09, 0.02, _skill)
	_nav_turn = lerpf(10.0, 16.0, _skill)
	# A sloppy bot still leads a little — firing at where you stand is not a mistake a player
	# makes, it is one no player makes — and only a crack shot solves the intercept outright.
	_lead_frac = lerpf(0.2, 1.0, _skill)
	_route_var = randf_range(0.2, 0.7)
	_route_salt = randi()
	_wp_slop = randf_range(0.3, 1.0)
	_arrive_wp = randf_range(1.4, 2.2)
	_face_yaw = bot.rotation.y
	_sense_t = randf() * SENSE_INTERVAL


## Drive one physics tick. Called by BotSystem.tick() on the host, before
## _process_player_movements() consumes the queued command the same tick.
func tick(delta: float) -> void:
	if _bot == null or not is_instance_valid(_bot):
		return
	_fire_cooldown = maxf(_fire_cooldown - delta, 0.0)
	_zone_t = maxf(_zone_t - delta, 0.0)
	var sm = _bot.get_server_movement()
	if sm == null or _bot.is_dead:
		_was_dead = _was_dead or _bot.is_dead
		return  # dead bots wait for the host respawn timer; brain re-arms automatically
	# Whether the body is SWIMMING, which changes what half the manoeuvres below mean: velocity
	# comes from where the bot looks, `jump` is swim-up, and nothing is ever on the floor. Read off
	# the context's cached answer rather than taking a shape query of our own — it is refreshed by
	# every movement tick and the brain runs one tick ahead of the mover, which for a swim is
	# nothing. (`_move_ctx` is null until the puppet finishes setting up.)
	var swimming: bool = _bot._move_ctx != null and _bot._move_ctx.in_water
	fell_now = false   # recomputed in the route block below, if there is a route to be under
	if _was_dead:
		# Fresh life (teleported) → drop all stale per-life state below.
		_was_dead = false
		_wish_prev = Vector3.ZERO
		# Death already stopped every weapon (RemotePlayer._stop_all_attacks); drop the hold
		# rather than releasing a trigger that's no longer held.
		_firing_weapon = null
		_firing_hold = 0.0
		_route_salt = randi()
		_escort_done = false
		_roam_pos = Vector3.INF
		_obj_held = Vector3.INF
		_obj_held_t = 0.0
		_route = PackedInt64Array()
		_repath_t = 0.0
		_zone_t = 0.0
		_reset_local_steer()
		_bl_pos = Vector3.INF
		_bl_t = 0.0
		_bl_ground = 0.0
		_bl_rest_t = 0.0
		_ground_dwell = 0.0
		_lad_best_y = -INF
		_lad_stall_t = 0.0
		_node_avoid = {}
		_node_avoid_t = 0.0
		_axis_seen = Vector3.INF
		_clear_ride()
		_ride_try_id = -1
		_ride_try_t = 0.0
		_ride_idle_t = 0.0
		_wedge_pos = Vector3.INF
		_wedge_t = 0.0
		_penned_pos = Vector3.INF
		_penned_n = 0
		_wp_try_id = -1
		_wp_try_t = 0.0
		_rescue_t = 0.0
		_rescue_id = -1
		_wp_best_d = INF
		_wp_min_id = -1
		_wp_min_d = INF
		_was_carrying = false
		_known = null
		_known_pos = Vector3.INF
		_known_t = 0.0
		_seen = null
		_sense_t = randf() * SENSE_INTERVAL
		_lead_tgt = null
		_lead_pos = Vector3.INF
		_lead_vel = Vector3.ZERO

	_local_nav = false
	# Last tick's ride state, for the blocks that run before the route block recomputes it. Cleared
	# here rather than there so a route that runs out (or a map with no graph) can't leave a bot
	# latched to a ride it is no longer on, with every watchdog muzzled for the rest of its life.
	var was_riding := _riding
	_riding = false
	# Age the ride attempt outside the route block, so it keeps running on the ticks the route
	# is empty or pointing elsewhere — those are exactly the ticks that used to reset it.
	if was_riding:
		_ride_idle_t = 0.0
	else:
		_ride_idle_t += delta
		if _ride_idle_t > RIDE_FORGET and _ride_try_id != -1:
			_ride_try_id = -1
			_ride_try_t = 0.0
	var obj := _commit_objective(_choose_objective(delta), delta)

	# Current or next route node is the synthetic FL_LADDER axis → the bot is climbing. Freeze
	# recovery and anti-stuck hops must be suppressed (a hop's velocity exceeds the knockoff speed
	# and drops the climb override); the climb is driven by looking at the axis + pressing forward.
	var mounting_ladder := false
	var ladder_axis := Vector3.INF
	var ladder_foot := Vector3.INF     # FL_LADDER node at our own level: the mount, not a climb
	if _graph != null and not _route.is_empty():
		for k in [_route_i, _route_i + 1]:
			if k >= _route.size() or (_graph.flags_of(_route[k]) & WaypointGraph.FL_LADDER) == 0:
				continue
			var lp := _graph.position_of(_route[k])
			if lp.y > _bot.global_position.y + 0.5:
				ladder_axis = lp          # the climb target, above us
				_axis_seen = lp           # remembered: a re-path mid-climb loses it (below)
			else:
				ladder_foot = lp          # somewhere to stand, in front of the rungs
	# Physically on the rungs with no FL_LADDER node in hand. A re-path from inside a shaft does
	# this every time: the nearest waypoint to a bot halfway up ww_ravine's 12m ladder is the
	# LANDING at the top, so A* starts the route there, the axis node is never visited, and the
	# bot — with no climb to drive — leans on the wall 2m under the floor until something rescues
	# it. Climb this ladder on the evidence of being on it: straight up (nudged into the rungs so
	# contact holds) until the node we are heading for is no longer above us, which is the point
	# at which stepping off sideways lands on the floor instead of falling down the shaft.
	if ladder_axis == Vector3.INF and _graph != null and _route_i < _route.size() \
			and _bot._move_ctx != null:
		ladder_axis = hold_climb_axis(_bot.global_position, _graph.position_of(_route[_route_i]),
				_bot._move_ctx.ladder_normal, _axis_seen)

	# The baker lays a mount node at the foot of the rungs and the axis node at the top, and the
	# route visits them in that order. Engaging the climb from wherever we happen to be standing
	# is how a bot ends up on the wall BESIDE the shaft: the ladder Volume is fatter than the
	# rungs, so it grabs, rises about a metre and jams on the wall (measured on ww_ravine — from
	# the mount the same bot climbs all 4.1m). So walk onto the mount first, climb second.
	if ladder_axis != Vector3.INF:
		mounting_ladder = ladder_foot == Vector3.INF or Vector2(
			ladder_foot.x - _bot.global_position.x,
			ladder_foot.z - _bot.global_position.z).length() <= LADDER_MOUNT_NEAR

	# Ladder-stall reroute (see LAD_* consts). Freeze recovery is off while mounting a ladder, so a
	# bot that engages the rungs but stops rising would press in forever otherwise — watch climb
	# height, and if it plateaus, penalize this ladder's nodes and re-path.
	_node_avoid_t = maxf(_node_avoid_t - delta, 0.0)
	if _node_avoid_t <= 0.0 and not _node_avoid.is_empty():
		_node_avoid = {}
	if mounting_ladder:
		if _bot.global_position.y > _lad_best_y + LAD_STALL_RISE:
			_lad_best_y = _bot.global_position.y
			_lad_stall_t = 0.0
		else:
			_lad_best_y = maxf(_lad_best_y, _bot.global_position.y)
			_lad_stall_t += delta
			if _lad_stall_t > LAD_STALL_T:
				_lad_stall_t = 0.0
				_avoid_ladder(ladder_axis)
				_route = PackedInt64Array()   # force a re-path around it (recomputed below)
				_route_salt = randi()
	else:
		_lad_best_y = -INF
		_lad_stall_t = 0.0

	# Freeze recovery (see _froze_* fields): barely moved for a while → reroute; still stuck →
	# ignore the graph and steer straight at the objective with local avoidance + hopping.
	if obj != Vector3.INF and not _was_dead and not mounting_ladder and not was_riding:
		# Horizontal only: a bot hopping on the spot (an FL_JUMP step it can't take) moves more
		# than a metre per bounce, and a 3D test reads that as progress and never trips.
		var froze_moved := INF if _froze_pos == Vector3.INF else Vector2(
			_bot.global_position.x - _froze_pos.x, _bot.global_position.z - _froze_pos.z).length()
		if froze_moved > 0.7:
			_froze_pos = _bot.global_position
			_froze_t = 0.0
		else:
			_froze_t += delta
			if _froze_t > 2.5:
				_froze_t = 0.0
				# Penalise the step we could not take, or A* hands back the same one and the bot
				# shuffles under it forever. The case that motivated this: a drop whose landing is
				# all but straight down, so there is no direction to walk off in — the bot stands
				# on its own waypoint and hops. Same escalating avoid the ladder stall uses.
				_avoid_route_node()
				_route = PackedInt64Array()   # fresh route out (recomputed below)
				_route_salt = randi()
				_free_t = 2.0                 # and break loose locally for a couple of seconds
	else:
		_froze_t = 0.0
	_free_t = maxf(_free_t - delta, 0.0)
	_repath_t = maxf(_repath_t - delta, 0.0)
	# Picking up a flag (or losing it) swaps the objective from one base to the other, so the route
	# in hand now leads the wrong way down the map. Everything else that invalidates a route can
	# wait for the throttle and keep walking what it has; this cannot, and it is rare enough to
	# cost nothing. Measured: without it, keeping stale routes lifted grabs 15% but dropped
	# conversion from 73% to 57%, because carriers spent their first moments running back in.
	var carrying: bool = not _bot.carried_items.is_empty()
	if carrying != _was_carrying:
		_was_carrying = carrying
		_obj_held = Vector3.INF     # picking the flag up or losing it IS the new objective
		_route = PackedInt64Array()
		_route_i = 0
		_repath_t = 0.0
		_route_salt = randi()
	var wish_dir := Vector3.ZERO   # desired horizontal world move direction (unit); ZERO = hold
	var nav_yaw: float = _bot.rotation.y
	var nav_pitch := 0.0
	var flags := 0
	var want_hop := false          # a discretionary hop was requested this tick; gated below (_hop_gate)

	if obj != Vector3.INF:
		var target := obj
		var wp_center := Vector3.INF   # current waypoint WITHOUT the wander offset (see _dodge)
		var wp_flags := 0
		if _graph != null and _graph.loaded:
			# Stateful route following: compute the A* route once, then walk it node-by-node, only
			# advancing when actually reached (recomputing every tick oscillates near-node picks).
			var off_route := not _route.is_empty() and _route_i < _route.size() and not was_riding \
				and _bot.global_position.distance_to(_graph.position_of(_route[_route_i])) > 12.0
			# Fell off the route: target is well ABOVE and roughly overhead — walked off a ledge and
			# can't reach it on foot. The 12m off-route test misses short drops, so without this we'd
			# fixate on an unreachable node. Re-route from where we landed, unless legitimately
			# climbing (ladder/water), where being below the target is normal.
			var fell := false
			if not _route.is_empty() and _route_i < _route.size():
				var tp := _graph.position_of(_route[_route_i])
				var climbing: bool = _bot._move_ctx != null and (_bot._move_ctx.ladder_normal != Vector3.ZERO \
					or _bot._move_ctx.check_water())
				# Grounded only: mid-jump and mid-fall the bot is legitimately below its target.
				fell = sm.state.on_floor and not climbing and not mounting_ladder and not was_riding \
					and _bot.global_position.y < tp.y - FALL_REROUTE \
					and Vector2(tp.x - _bot.global_position.x, tp.z - _bot.global_position.z).length() < 3.0
			fell_now = fell
			if _route.is_empty() or _route_i >= _route.size() \
					or _route_obj.distance_to(obj) > 3.0 or off_route or fell:
				if _repath_t > 0.0:
					# Throttled, so keep walking the stale route instead of dropping it. Out of
					# date is not the same as unusable: its nodes are still places the baker says a
					# bot can stand, reached by edges it says a bot can walk, whereas the fallback
					# for having no route at all is to steer straight at the objective — a beeline
					# through whatever happens to be in the way.
					#
					# That fallback is expensive because this branch is not rare. Measured on
					# ww_ravine, something invalidates a route every 2.6 bot-seconds (mostly
					# off_route, then fell), and each one used to buy up to REPATH_MIN of blind
					# running. It shows up as 373 stumbles a match, median 1s each, 656 bot-seconds
					# of ~10% of all route-following time, with the bot pressed flat against a wall
					# at 0.8 m/s. Distance covered is what captures are made of: bots convert grabs
					# at a flat 72% whatever the graph looks like, so what moves the score is how
					# much ground they cover looking for one.
					#
					# A stale route is only actively wrong when the objective has moved to the far
					# end of the map, and the test for that is not distance — the objective drifts
					# more than 8m all the time while a bot tracks an enemy, and dropping the route
					# on that put every bit of the blind running straight back. It is picking the
					# flag up or losing it, handled once, above.
					pass
				else:
					# Real objective switch (flag grabbed → cap, new nearest enemy) rerolls the salt
					# for a fresh route pick; a drifting objective (chased enemy) keeps it so the
					# re-query extends the same route instead of flip-flopping. A fall also rerolls.
					if fell or (_route_obj != Vector3.INF and _route_obj.distance_to(obj) > 8.0):
						_route_salt = randi()
					_route = _graph.path_ids(_bot.global_position, obj, _route_var, _route_salt, _node_avoid)
					_route_obj = obj
					_route_i = _nearest_route_index()
					_wp_off_i = -1
					_repath_t = REPATH_FAIL if _route.is_empty() else REPATH_MIN
					if _route.is_empty() and _roaming:
						_roam_pos = Vector3.INF   # can't get there; somewhere else next tick
			# Advance once reached. Proximity is horizontal EXCEPT we must also be near vertically, or
			# a node the bot stands far above/below counts as "reached" and gets skipped — the classic
			# wedge: skipping a drop node lands the target across the wall the drop was meant to avoid.
			# FL_LADDER nodes sit high on the axis and use a plain 3D radius for the same reason.
			# A drop beside the heading means the route is a ledge, a causeway or a bridge, and
			# every liberty taken with the line has somewhere to throw the bot. Probed once and
			# read three times below: how close counts as arrived, whether to roll a lateral
			# offset, and which way to lean (_ledge_safe).
			_ledge_sides = 0
			var ledge_shallow := false   # a drop either side that would lose the route, not a cliff
			if _route_i < _route.size() and not mounting_ladder:
				var to_wp: Vector3 = _graph.position_of(_route[_route_i]) - _bot.global_position
				to_wp.y = 0.0
				if to_wp.length() > 0.1:
					# Bits 1-2 are the cliffs either side, bits 4-8 the shallower drops; only the
					# cliffs outlive this tick (_ledge_safe reads them from _steer).
					var sides := _side_drops(to_wp.normalized())
					_ledge_sides = sides & 3
					ledge_shallow = (sides & 12) != 0
			while _route_i < _route.size():
				var rid: int = _route[_route_i]
				var rp: Vector3 = _graph.position_of(rid)
				if _graph.flags_of(rid) & WaypointGraph.FL_LADDER:
					if _bot.global_position.distance_to(rp) >= LADDER_ARRIVE:
						break
				# The arrival radius is what decides how much of a corner gets cut, and on a baked
				# graph it is wider than the 1m grid the nodes sit on — so several of them can be
				# inside it at once and the bot steers at one three ahead. That is a smoother line
				# in the open and a swim in the moat on ww_roc2's causeway, where a bot was
				# measured skipping route index 12 -> 15 in a second at 7 m/s and going over the
				# side. Beside a drop, take them one at a time.
				elif (_horiz(rp) >= lerpf(TURN_ARRIVE, _arrive_wp, \
							_straightness(_route_i) * (0.0 if _ledge_sides != 0 else 1.0)) \
							and not _passed_wp(rid, rp)) \
						or absf(rp.y - _bot.global_position.y) > VERT_ARRIVE:
					break
				_route_i += 1
			if _route_i < _route.size():
				target = _graph.position_of(_route[_route_i])
				wp_center = target
				wp_flags = _graph.flags_of(_route[_route_i])
				# No-progress watchdog. A hand-authored file can link a step the bot cannot take —
				# ww_2fort's lift, where the human who placed the waypoints rode up and a bot can
				# only shuffle at the bottom of the shaft. Freeze recovery misses that: shuffling
				# covers more ground than its threshold. So measure closing on THIS node, and when
				# none happens for a while, penalise it and let A* offer something else. Held off
				# while an enemy is in mind, where standing and shooting is the point.
				# Distance is 3D on purpose: a climbing bot makes no horizontal progress at all,
				# and a horizontal test throws the route away mid-climb and leaves it dithering at
				# the foot of the rungs. This deliberately still fires on a climb that has stalled,
				# unlike freeze recovery: on ww_ravine's 12m ladder it is the only thing that gets
				# a bot off, and exempting ladders here measured three times worse (a 175s hang).
				var rid_now: int = _route[_route_i]
				var wp_d := _bot.global_position.distance_to(wp_center)
				var give_up_on_wp := false
				# Heading for a lift deck — the ride itself, or the walk onto one, which is the
				# same problem: the deck is only under that waypoint at one of the lift's two
				# stops. Both, because height cannot tell them apart — at ww_storm's upper stop
				# the deck and the landing beside it are 18cm apart, so a bot that reads "same
				# height, walk to it" walks into an empty shaft and falls seven metres. While this
				# leg is live no watchdog below may fire: every one of them reads a bot holding
				# station for a lift as a bot that has failed.
				_riding = (_graph.flags_of(rid_now) & WaypointGraph.FL_LIFT) != 0
				if not _riding:
					_clear_ride()
				else:
					if rid_now != _ride_id:
						_ride_id = rid_now
						# A lift blocked by another player, or one whose call the bot never managed
						# to make, has to be given up on eventually or the route is a permanent
						# trap. Long enough to cover the slowest lift's whole travel plus its wait.
						_ride_patience = LIFT_PATIENCE \
							+ absf(wp_center.y - _bot.global_position.y) * LIFT_PATIENCE_PER_M
						_bind_lift(wp_center)
					# Patience accrues against BEING ON A LIFT AT ALL, not against one node and
					# not against an uninterrupted spell — see RIDE_FORGET. Keying it to the node
					# was not enough: a shaft has a lift waypoint at each stop, and a bot
					# alternating between the two reset the clock every time, which still left
					# 37.5s unbroken rides on ww_storm against a patience of ~8-22s. Only
					# genuinely walking away for RIDE_FORGET forgets the attempt.
					_ride_try_id = rid_now
					_ride_try_t += delta
					if _ride_try_t > _ride_patience:
						_clear_ride()
						_ride_try_id = -1
						_ride_try_t = 0.0
						_avoid_route_node()
						give_up_on_wp = true
				if rid_now != _wp_min_id:
					_wp_min_id = rid_now
					_wp_min_d = wp_d
				_wp_min_d = minf(_wp_min_d, wp_d)
				if rid_now != _wp_try_id or wp_d < _wp_best_d - WP_PROGRESS:
					_wp_try_id = rid_now
					_wp_best_d = wp_d
					_wp_try_t = 0.0
					_rescue_id = -1      # closing again: hand the leg back to route following
					_rescue_t = 0.0
				elif not _riding:
					_wp_try_t += delta
					# Unhappy for a while but not yet given up: navigate to it instead of waiting
					# out the clock beelining into whatever is in the way. Never on a leg whose
					# execution is itself precise — a ride, a climb, a jump or a duck — where the
					# specialised code above owns the approach and a nudged heading misses it.
					if _wp_try_t > RESCUE_AFTER and not mounting_ladder \
							and (wp_flags & (WaypointGraph.FL_PRECISE | WaypointGraph.FL_LIFT)) == 0:
						if rid_now != _rescue_id:
							_rescue_id = rid_now
							_rescue_t = 0.0
							_wf_hand = 0          # fresh leg: let the wall-follow pick a hand
						_rescue_t += delta
					if _wp_try_t > (WP_GIVEUP if _known == null else WP_GIVEUP_FIGHT):
						_wp_try_t = 0.0
						_wp_try_id = -1
						_rescue_id = -1
						_rescue_t = 0.0
						_avoid_route_node()   # reads the route, so before it is dropped
						give_up_on_wp = true
						if _bot.global_position.distance_to(_penned_pos) > PENNED_DIST:
							_penned_n = 0
						_penned_pos = _bot.global_position
						_penned_n += 1
				# Whether this leg is a JUMP is a property of the edge we're on, not of the node
				# we're heading to: the same ledge-top waypoint is jumped up to from below and
				# walked onto from along the top. Baked graphs say so per edge; hand HPB files
				# only have the node flag, so those keep it.
				if _route_i > 0 and _graph.has_edge_flags():
					wp_flags &= ~WaypointGraph.FL_JUMP
					wp_flags |= _graph.flags_of_edge(_route[_route_i - 1], _route[_route_i]) \
						& WaypointGraph.FL_JUMP
				# Steer at a point rolled off-centre per waypoint, so bots don't all walk the same
				# rail. Precision nodes (jump/crouch/ladder) stay on the true centre.
				if _route_i != _wp_off_i:
					_wp_off_i = _route_i
					_wp_off = Vector3.ZERO
					# A CLIMB is a precision node too, flag or no flag. Stairs bake as plain walk
					# edges (a continuous ramp, no FL_JUMP), so nothing here used to hold the bot to
					# the centreline while it went up one — and a metre of lateral roll is wider
					# than the tread. On ww_ravine's two base stairs that walks the bot off the side
					# onto the 3.2m face beside them, where it presses into the wall at 6-7 m/s for
					# five or six seconds before an anti-stuck hop shakes it loose.
					var climbing: bool = wp_center.y - _bot.global_position.y > CLIMB_PRECISE
					if not climbing and not _riding and not ledge_shallow \
							and wp_flags & WaypointGraph.FL_PRECISE == 0:
						var ang := randf() * TAU
						_wp_off = Vector3(cos(ang), 0.0, sin(ang)) \
								* (randf() * _wp_slop * _straightness(_route_i))
				target += _wp_off
				# Dropping the route is deferred to here: the flag and offset code above still
				# indexes it, and clearing it mid-block read off the end of the array.
				if give_up_on_wp:
					_route = PackedInt64Array()
					_route_salt = randi()
					_repath_t = 0.0
		# (no graph for this map → target stays the objective: steer straight)

		# Freeze recovery active → abandon the route, steer straight at the objective, and hop.
		if _free_t > 0.0 and not mounting_ladder and not _riding:
			target = obj
			want_hop = true

		var heading_to_obj := target == obj
		# --- Pick the goal ------------------------------------------------------------------
		# One place to be, and how exactly to be there. Every manoeuvre the brain performs is
		# expressed this way rather than as its own steering code, so there is a single writer of
		# wish_dir below and a new behaviour has to agree with one thing instead of eleven.
		var goal := _goal
		goal.reset()
		goal.pos = target
		goal.centre = wp_center
		if heading_to_obj:
			goal.radius = ARRIVE_OBJ   # standing on the objective is the point; don't drift off
		goal.precise = _riding or mounting_ladder \
				or (wp_flags & WaypointGraph.FL_PRECISE) != 0
		# Nothing between here and there but geometry: the full local navigator, which can
		# wall-follow out of a concave room. This is the no-waypoint case (no graph, or the route
		# ran out short of the objective).
		goal.free = heading_to_obj and _horiz(obj) > LOCAL_NAV_MIN
		# Route following could not close on this node (see RESCUE_AFTER): navigate to it instead
		# of leaning on whatever is in the way for the rest of the give-up clock. Aimed at the
		# node CENTRE — the wander offset is for variety and this is no longer a leg wanting any.
		goal.rescue = _route_i < _route.size() and _rescue_id == _route[_route_i] \
				and _rescue_t < RESCUE_MAX
		# A climb is not a walk: the movement layer drives velocity from where the bot LOOKS, so
		# this goal is satisfied by facing up the axis and pressing forward (see _steer).
		if mounting_ladder and ladder_axis != Vector3.INF:
			goal.climb = ladder_axis

		# Working a lift is its own goal source, like the route and the objective (see _lift_goal).
		var on_lift := _riding and _lift_goal(goal, wp_center)
		if on_lift:
			want_hop = false
			flags &= ~CMD_JUMP   # a hop on a moving deck is how you fall off it

		# --- Steer to it --------------------------------------------------------------------
		wish_dir = _slew(_steer(delta, goal), delta)
		if wish_dir != Vector3.ZERO:
			nav_yaw = _wish_yaw
		nav_pitch = _steer_pitch
		# A duck still applies on a lift leg — only the JUMP is suppressed there, since a hop on a
		# moving deck is how you fall off it. (The pre-refactor code set crouch before the lift
		# block and cleared only the jump bits; dropping both was an accident.)
		if wp_flags & WaypointGraph.FL_CROUCH:
			flags |= CMD_CROUCH
		if not on_lift:
			if wp_flags & WaypointGraph.FL_JUMP:
				flags |= CMD_JUMP
			# Some control maps (ww_memnate's Ring) capture on a jump-through, not just standing.
			if _obj_is_control and _horiz(obj) < 3.0:
				want_hop = true

	if not _local_nav:
		_reset_local_steer()

	# Opportunistic combat while still pathing. Bots aim with human-like imperfection — a reaction
	# delay, a drifting aim error, and a finite turn rate — so they don't headshot instantly.
	# Sight is a cone around where the bot is LOOKING, so it can be approached from behind; what
	# leaves the cone is remembered briefly (below) rather than forgotten the same tick.
	# A target that died or left is dropped on the tick it happens; acquiring a new one runs on
	# this bot's own sense tick (see SENSE_INTERVAL) and the last answer is held until then.
	if _seen != null and (not is_instance_valid(_seen) or not _seen.is_inside_tree()
			or _seen.get("is_dead")):
		_seen = null
	_sense_t -= delta
	if _sense_t <= 0.0:
		_sense_t = SENSE_INTERVAL
		var facing := Vector3(-sin(_face_yaw), 0.0, -cos(_face_yaw))
		_seen = Combat.find_homing_target(_bot, _bot, _bot.team, ENGAGE_RANGE,
			_bot.get_rid(), Vector3.INF, facing, FOV_COS)
	var enemy := _seen
	_known_t = maxf(_known_t - delta, 0.0)
	if _known != null and (_known_t <= 0.0 or not is_instance_valid(_known) or _known.get("is_dead")):
		_known = null
		_known_pos = Vector3.INF
	if enemy != null:
		_known = enemy
		_known_pos = enemy.global_position
		_known_t = VIS_MEMORY
	# Face the live target, or the last place one was seen or felt — a bot shot from behind turns
	# round instead of walking on. Firing still needs `enemy`, so it never shoots a remembered spot.
	# Aim at the BODY, not the feet: collision_center is the point acquisition tests LOS to and
	# the point a projectile's contact radius is measured from (Projectile._player_contact), so
	# it is the only one worth shooting at. `_known_pos` stays the target's ORIGIN on purpose —
	# it doubles as the hunt objective in _choose_objective, and a destination lifted 0.9m can
	# pick a waypoint on the floor above. A remembered position is only ever faced, never fired
	# at, so the difference does not reach a shot.
	var aim_pos := _known_pos if enemy == null else SpatialQuery.collision_center(enemy)
	var dist := 0.0 if aim_pos == Vector3.INF else _horiz(aim_pos)
	_track_target(enemy, delta)
	# Choose the weapon BEFORE aiming rather than after firing: how far ahead of a moving target to
	# aim depends on how fast this spell's projectile flies, so the aim point is a property of the
	# weapon in hand. Raising it during the reaction delay is also what a player does.
	var wpn: Weapon = null
	if enemy != null:
		_bot.current_weapon_idx = _choose_weapon(dist)
		wpn = _bot.weapon_at(_bot.current_weapon_idx)
		aim_pos = _lead_point(aim_pos, wpn.bot_lead_speed if wpn != null else 0.0)
	var want_yaw := nav_yaw
	var want_pitch := nav_pitch
	if aim_pos != Vector3.INF:
		# From the EYE, not the feet. This is the third of the three lines: the aim angle used to
		# be measured from the bot's origin while the shot leaves 1.6m above it, so the pitch was
		# wrong by the eye height over the range — a level shot at a target on the same floor
		# passes over its head. Measured on a pinned 20m duel: not one of 40 mind missiles came
		# within 1.4m of the target, with or without any lead.
		var e3 := aim_pos - _eye()
		var eh := Vector3(e3.x, 0.0, e3.z)
		if eh.length() > 0.05:
			want_yaw = atan2(-eh.x, -eh.z)
			# Positive pitch = up (camera.rotation.x convention), so an enemy above needs +asin.
			want_pitch = asin(clampf(e3.normalized().y, -1.0, 1.0))
	if enemy != null:
		if enemy != _prev_enemy:
			_reaction = _reaction_time   # just spotted this target → hesitate before firing
		_prev_enemy = enemy              # only on a live sighting, so a target that dips out of
										 # the cone and back doesn't pay the delay twice
		# Retarget the aim error to a new point in a cone now and then (wider at range), then ease
		# toward it, so the aim wobbles like a hand tracking rather than snapping dead-on.
		if randf() < 0.04:
			var cone := _aim_err * (0.6 + dist / ENGAGE_RANGE)
			_wander_to = Vector2(randf_range(-cone, cone), randf_range(-cone, cone))
		_wander = _wander.lerp(_wander_to, clampf(delta * 3.0, 0.0, 1.0))
	else:
		_wander = Vector2.ZERO
		_wander_to = Vector2.ZERO
	_reaction = maxf(_reaction - delta, 0.0)

	# Turn toward the wanted look at a finite rate (slower in combat, faster while navigating) so
	# it reads as a body turning, not a snap. Movement below is strafe-corrected into the look
	# frame, so pathing stays crisp even while the face lags the route.
	if enemy != null:
		want_yaw += _wander.x
		want_pitch = clampf(want_pitch + _wander.y, -1.4, 1.4)
	var max_turn := (_turn_rate if enemy != null else _nav_turn) * delta
	_face_yaw += clampf(angle_difference(_face_yaw, want_yaw), -max_turn, max_turn)
	_face_pitch += clampf(want_pitch - _face_pitch, -max_turn, max_turn)

	var yaw := _face_yaw
	var pitch := _face_pitch
	var move_x := 0.0
	var move_y := 0.0
	if wish_dir != Vector3.ZERO:
		# Steer toward the nav target in the look frame (world = Basis(UP, yaw) * (mi.x, 0, mi.y)).
		var x_axis := Vector3(cos(yaw), 0.0, -sin(yaw))
		var z_axis := Vector3(sin(yaw), 0.0, cos(yaw))
		move_x = clampf(wish_dir.dot(x_axis), -1.0, 1.0)
		move_y = clampf(wish_dir.dot(z_axis), -1.0, 1.0)

	# Anti-stuck hops clear lips/corners, but on a ladder they knock the bot off the rungs (velocity
	# past the knockoff speed drops the climb override) — suppress while climbing.
	if _riding:
		_stuck_t = 0.0
		_win_pos = Vector3.INF
	elif not mounting_ladder and _anti_stuck(delta, move_x != 0.0 or move_y != 0.0) != 0:
		want_hop = true

	# Penned: not wedged — the bot moves, it just cannot get anywhere the graph leads, so it gives
	# up on the same waypoint over and over from the same spot. Measured on ww_wstland4, where a
	# bot that overshoots the mesa lip at (44.3, 7.2, 0.9) drops into a hull pocket below and
	# rattles around a metre of it; the wedge test never fires because a metre is not a centimetre.
	# Re-pathing has already been tried PENNED_GIVEUPS times and answered with the same first node.
	if _penned_n >= PENNED_GIVEUPS:
		_penned_n = 0
		_penned_pos = Vector3.INF
		Log.info("%s penned at %v — %d give-ups without leaving %.1fm; returning it to spawn"
				% [_bot.name, _bot.global_position, PENNED_GIVEUPS, PENNED_DIST], "bot")
		if BotSystem.free_wedged(_bot):
			return

	# Wedged in the world: pressing to move and not travelling a centimetre. Nothing above can fix
	# that — re-pathing, avoid penalties, hops and freeze recovery all fire and the bot does not
	# budge (measured on ww_chasm: a crack on the lip of the ravine held one for a whole 600s
	# match at 1.2 m/s of wish velocity). So take the last resort a bot mod has and put it back at
	# a spawn. Logged, loudly: every one of these is a spot worth fixing at the source.
	if _riding:
		_wedge_pos = Vector3.INF   # holding station on a deck is the job, not a wedge
		_wedge_t = 0.0
	elif move_x != 0.0 or move_y != 0.0:
		if _wedge_pos == Vector3.INF or _bot.global_position.distance_to(_wedge_pos) > WEDGE_DIST:
			_wedge_pos = _bot.global_position
			_wedge_t = 0.0
		else:
			_wedge_t += delta
			if _wedge_t > WEDGE_T:
				_wedge_t = 0.0
				Log.info("%s wedged at %v for %.0fs — returning it to spawn"
						% [_bot.name, _bot.global_position, WEDGE_T], "bot")
				if BotSystem.free_wedged(_bot):
					_wedge_pos = Vector3.INF
					return
	else:
		_wedge_pos = Vector3.INF
		_wedge_t = 0.0

	# Gate every discretionary hop: pace it by ground dwell and cut it out entirely while
	# bounce-locked, so the bot grounds and steers out instead of trampolining in place.
	# Baked waypoint FL_JUMP (real gap crossings) is applied directly above and never gated.
	if _hop_gate(delta, sm.state.on_floor, swimming) and want_hop:
		flags |= CMD_JUMP
		_ground_dwell = 0.0   # consumed: must re-ground before the next discretionary hop

	# The sim jumps only on a fresh press, so jump held through the air would be spent before the
	# landing. Let go wherever it does nothing and every grounded jump tick stays a press.
	var on_ladder: bool = _bot._move_ctx != null and _bot._move_ctx.ladder_normal != Vector3.ZERO
	if not (sm.state.on_floor or swimming or on_ladder):
		flags &= ~CMD_JUMP

	var cmd = InputCommand.create(_seq, move_x, move_y, yaw, pitch, flags, delta)
	_seq += 1
	sm.enqueue(cmd)

	# Would the shot actually reach? Target acquisition rays from the bot's FEET to the target's
	# collision CENTRE (Combat.find_homing_target), while a shot leaves the EYE along the
	# rate-limited, wobbling aim above — three different lines, and nothing used to compare them.
	# So a bot opened fire before its head had finished turning, and kept firing into the cover
	# edge it was tracking across, spending mana it has no way to get back (nothing regenerates
	# it; only a pickup does) on the wall. Trace the line the weapon will really fire along, and
	# hold fire while it is blocked.
	var shot_blocked := false
	if enemy != null and aim_pos != Vector3.INF:
		var eye := _eye()
		_shot_query.from = eye
		_shot_query.to = eye + _look_dir() * eye.distance_to(aim_pos)
		var space := _bot.get_world_3d().direct_space_state
		shot_blocked = not space.intersect_ray(_shot_query).is_empty()
		_tally("shot_blocked" if shot_blocked else "shot_clear")

	# sync_firing rides the snapshot (PLAYER_FLAG_FIRING) so observers drive a sustained weapon's
	# beam the same as a player holding the button. Discrete weapons show per-shot via sync_attack.
	var beaming := false
	var held: Weapon = null  # the weapon we're engaging with this tick, null when not engaging
	if enemy != null and not shot_blocked and _reaction <= 0.0:
		beaming = wpn != null and wpn.sustained
		held = wpn
		if _fire_cooldown <= 0.0:
			_fire_at(enemy)
	# A bot's commands carry no attack button, so nothing else releases the trigger. Discrete weapons
	# also release when the fire cadence lapses (still sees target, stopped landing shots); sustained
	# weapons keep an immediate stop since their observers are driven by PLAYER_FLAG_FIRING.
	_firing_hold = maxf(_firing_hold - delta, 0.0)
	if _firing_weapon != null and (_firing_weapon != held
			or (not _firing_weapon.sustained and _firing_hold <= 0.0)):
		_release_trigger()
	_bot.sync_firing = beaming


## Damage from outside the sight cone still registers: the bot turns toward whoever hit it and
## picks them up normally once they enter the cone. Called by RemotePlayer on the authority.
func on_damaged(attacker: Node3D) -> void:
	if _bot == null or attacker == null or not is_instance_valid(attacker):
		return
	if attacker == _bot or Teams.nodes_friendly(attacker, _bot):
		return
	_known = attacker
	_known_pos = attacker.global_position
	_known_t = VIS_MEMORY


## Forget the lift we were working, so the next FL_LIFT node latches and binds from scratch.
func _clear_ride() -> void:
	_riding = false
	_ride_id = -1
	_ride_lift = null


## Bind the mover an FL_LIFT waypoint belongs to. The waypoint marks the deck's surface at ONE of
## the lift's two stops and the deck is parked at the other one as often as not, so look both ways
## along its column. Everything the ride state needs comes from the mover itself — where its deck
## is this instant, how wide it is, and whether it has settled — because the graph can only say
## where the two stops are, not which of them the deck is at right now.
func _bind_lift(tp: Vector3) -> void:
	_ride_lift = null
	_ride_box = Rect2()
	_ride_top = 0.0
	var space := _bot.get_world_3d().direct_space_state
	for dir: Vector3 in [Vector3.DOWN, Vector3.UP]:
		_floor_query.from = tp + Vector3(0.0, 0.3, 0.0)
		_floor_query.to = _floor_query.from + dir * LIFT_COLUMN_SCAN
		var hit := space.intersect_ray(_floor_query)
		if hit.is_empty() or not (hit.collider is FuncDoorBase):
			continue
		_ride_lift = hit.collider
		# The mover sized its own brush at spawn and kept the box (FuncDoorBase._build_body); it is
		# the same measurement, in the same local frame, that its call volume and blocked detector
		# are built from. Measuring it again here is how the two ended up able to disagree.
		var a: AABB = _ride_lift.brush_aabb
		_ride_box = Rect2(a.position.x, a.position.z, a.size.x, a.size.z)
		_ride_top = a.end.y
		return


## Where we are standing in the deck's own frame — the frame the footprint is measured in, so a
## func_platrot spinning through its travel is still asked the same question.
func _deck_local(p: Vector3) -> Vector2:
	if _ride_lift == null or not is_instance_valid(_ride_lift):
		return Vector2(INF, INF)
	var l := _ride_lift.to_local(p)
	return Vector2(l.x, l.z)


## Out of the shaft by the shortest way: perpendicular to the nearest footprint edge. A bot backed
## straight away from the deck's CENTRE leaves along the diagonal from a corner, which is the
## longest way out and often into the wall the shaft is cut through. Returned in world space.
func _away_from_deck(here: Vector2) -> Vector3:
	var c := _ride_box.get_center()
	var half := _ride_box.size * 0.5
	var dx: float = (here.x - c.x) / maxf(half.x, 0.01)
	var dz: float = (here.y - c.y) / maxf(half.y, 0.01)
	var local := Vector3(signf(dx) if dx != 0.0 else 1.0, 0.0, 0.0) if absf(dx) >= absf(dz) \
		else Vector3(0.0, 0.0, signf(dz) if dz != 0.0 else 1.0)
	if _ride_lift == null or not is_instance_valid(_ride_lift):
		return local
	var w: Vector3 = _ride_lift.global_transform.basis * local
	w.y = 0.0
	return w.normalized() if w.length() > 0.01 else Vector3.FORWARD


## Where the bound lift's deck surface is this instant. Falls back to the waypoint itself when the
## column probe found nothing, which degrades the ride to "wait here until it works or times out".
func _lift_deck_y(tp: Vector3) -> float:
	if _ride_lift == null or not is_instance_valid(_ride_lift):
		return tp.y
	return _ride_lift.global_position.y + _ride_top


## True when the lift is parked at a stop rather than mid-travel. Stepping onto a deck still moving
## is how a rider gets caught under it.
func _lift_settled() -> bool:
	if _ride_lift == null or not is_instance_valid(_ride_lift):
		return true
	var st: int = _ride_lift.state
	return st == FuncDoorBase.State.AT_BOTTOM or st == FuncDoorBase.State.AT_TOP


func _horiz(p: Vector3) -> float:
	return Vector2(p.x - _bot.global_position.x, p.z - _bot.global_position.z).length()


## Pile an escalating path-avoidance penalty on the ladder the bot just stalled on (its FL_LADDER
## gate node plus nodes near the axis), so successive re-paths swing further from it. TTL decays
## so it's retryable later.
func _avoid_ladder(axis: Vector3) -> void:
	if _graph == null or axis == Vector3.INF:
		return
	_node_avoid_t = LAD_AVOID_TTL
	for i in _graph.positions.size():
		var p: Vector3 = _graph.position_of(i)
		var is_gate := (_graph.flags_of(i) & WaypointGraph.FL_LADDER) != 0
		if (is_gate and Vector2(p.x - axis.x, p.z - axis.z).length() < LAD_AVOID_RADIUS + 3.0) \
				or p.distance_to(axis) < LAD_AVOID_RADIUS:
			_node_avoid[i] = float(_node_avoid.get(i, 0.0)) + LAD_AVOID_STEP


## Where to climb to when the bot is on a ladder with no FL_LADDER node to aim at (see the caller).
## Straight up from where it is, half a metre into the rungs so contact holds, and high enough to
## clear `next_node` — the node it is trying to reach. Vector3.INF when this does not apply: not on
## a face ladder (`ladder_normal` is zero off a ladder, and also on the thick free-climb volumes
## WW's mappers used for rock faces, which have no single climbing plane and steer differently), or
## we are clear above it, which is the release: stepping off sideways then lands ON the floor.
## Letting go level with it is not enough — four centimetres low, the hull meets the vertical face
## of the floor slab instead of its top, and the bot hangs there (measured: 417s).
static func hold_climb_axis(bot_pos: Vector3, next_node: Vector3, ladder_normal: Vector3,
		axis_seen := Vector3.INF) -> Vector3:
	if ladder_normal == Vector3.ZERO:
		return Vector3.INF
	if bot_pos.y >= next_node.y + LADDER_TOPOUT:
		return Vector3.INF
	# Climb the shaft's own column when we know where it is: ww_ravine's ladder rises through a
	# hole barely wider than the hull, and a climb straight up from wherever the bot happens to be
	# carries its shoulder into the corner, where it jams under the floor and rides nothing.
	var col := bot_pos
	if axis_seen != Vector3.INF and Vector2(axis_seen.x - bot_pos.x,
			axis_seen.z - bot_pos.z).length() < LADDER_COLUMN_NEAR:
		col = axis_seen
	var into := Vector3(-ladder_normal.x, 0.0, -ladder_normal.z)
	into = into.normalized() * 0.5 if into.length() > 0.01 else Vector3.ZERO
	return Vector3(col.x, next_node.y + 0.5, col.z) + into



## True once the bot has closed on `rp` and started moving away from it again.
##
## The arrival radius _straightness asks for through a corner can be tighter than the bot's own
## turning circle: at 8.6 m/s it laps the node at ~1.1m and never satisfies a 0.5m test. That cost
## ww_ravine 366 bot-seconds of a 600s match orbiting three corners at a dead run — invisible to
## every stuck detector, because the bot is moving flat out the whole time. So also let a node go
## once it is behind us, since steering back at it only widens the orbit. Closing on it first is
## required, so a node the bot never actually reaches still falls to the WP_GIVEUP watchdog rather
## than being skipped, and the vertical gate (VERT_ARRIVE) still applies on top of this.
func _passed_wp(rid: int, rp: Vector3) -> bool:
	if rid != _wp_min_id or _wp_min_d > _arrive_wp:
		return false
	return _bot.global_position.distance_to(rp) > _wp_min_d + PASSED_WP

## How straight the route runs THROUGH node `i`: 1 when the legs in and out are collinear, 0 at a
## right angle or sharper. Corner-cutting is the point of a loose arrival radius and a wander
## offset — it is what stops bots walking a single rail — but both of them leave the corridor the
## baker validated, and on ww_ravine's switchback stairs the corridor is all there is: aiming up to
## a metre off centre and turning for the next node from 2.2m short walks a bot straight off the
## landing, or into the wall on the inside of the turn. So spend that freedom on the straights,
## where there is room for it, and hug the graph through the turns. Ends of a route count as
## straight — there is no corner there to cut.
func _straightness(i: int) -> float:
	if _graph == null or i <= 0 or i + 1 >= _route.size():
		return 1.0
	# Baked graphs only. A tight radius is a promise that the node is somewhere the hull can
	# actually stand, and only the baker makes that promise — hand HPB waypoints were placed by
	# eye at hull centre, sparsely, and holding a bot to half a metre of one costs more than the
	# corner-cutting does: ww_2fort measured 140s pinned -> 227s with this applied to its file.
	if not _graph.has_edge_flags():
		return 1.0
	# A ladder's mount and its landing are not corners to be taken cleanly, they are the two ends
	# of a climb, and the turn through them is always sharp. Tightening there just pins the bot on
	# the approach: measured on ww_ravine's short ladder, 125s of a 600s match at (-12, 45, -18).
	for k in [i - 1, i, i + 1]:
		if _graph.flags_of(_route[k]) & WaypointGraph.FL_LADDER:
			return 1.0
	var a: Vector3 = _graph.position_of(_route[i - 1])
	var b: Vector3 = _graph.position_of(_route[i])
	var c: Vector3 = _graph.position_of(_route[i + 1])
	var v1 := Vector2(b.x - a.x, b.z - a.z)
	var v2 := Vector2(c.x - b.x, c.z - b.z)
	if v1.length() < 0.01 or v2.length() < 0.01:
		return 1.0
	return clampf(v1.normalized().dot(v2.normalized()), 0.0, 1.0)


## Pile an avoid-penalty on the route node the bot has stalled trying to reach, and on anything
## within a metre of it, so the next query routes around it. Wears off with the rest of the avoid
## set (LAD_AVOID_TTL), and it is a weight, not a wall: if that step is the only way, A* still takes
## it — the bot just tries everything else first.
func _avoid_route_node() -> void:
	if _graph == null or _route.is_empty() or _route_i >= _route.size():
		return
	_node_avoid_t = LAD_AVOID_TTL
	var tp: Vector3 = _graph.position_of(_route[_route_i])
	for i in _graph.positions.size():
		if _graph.position_of(i).distance_to(tp) <= 1.0:
			_node_avoid[i] = float(_node_avoid.get(i, 0.0)) + STALL_AVOID_STEP


## Index into _route of the node nearest the bot — where to resume after a recompute so we
## don't restart the route from its beginning.
func _nearest_route_index() -> int:
	var best := 0
	var best_d := INF
	for k in _route.size():
		var d: float = _bot.global_position.distance_squared_to(_graph.position_of(_route[k]))
		if d < best_d:
			best_d = d
			best = k
	return best


## Paces/suppresses discretionary hops so a bot can't bounce-lock (re-jump on every landing
## frame while confined, staying airborne with no horizontal control). Called every tick to keep
## its state current; returns true when a hop is permitted now. See the _bl_* fields.
## A swimmer passes straight through: everything this gate measures is about the jump-land cycle,
## and in water there is neither. `on_floor` is false for the whole swim, so the "confined and
## mostly airborne" test is unconditionally true and trips on any bot not covering BL_MOVE metres
## — which is every bot trying to go UP. Measured on ww_2fort, where the moat is the busiest place
## on the map: 69% of every bounce-lock trip in a 600s six-bot match happened in the water. And
## what it suppresses there is the one press that helps, since `jump` in water is swim-up (see
## LadderWater.water_velocity): the gate's ground-dwell requirement cannot be met while
## swimming either, so a bot in water could never take a recovery hop at all.
func _hop_gate(delta: float, on_floor: bool, swimming := false) -> bool:
	_ground_dwell = _ground_dwell + delta if on_floor else 0.0
	if swimming:
		_bl_pos = _bot.global_position
		_bl_t = 0.0
		_bl_ground = 0.0
		_bl_rest_t = 0.0
		return true

	# Detection window: over BL_WINDOW seconds, did we make horizontal progress, and how much of
	# it was spent on the floor? Confined + mostly airborne == bouncing in place.
	var pos := _bot.global_position
	if _bl_pos == Vector3.INF:
		_bl_pos = pos
	if on_floor:
		_bl_ground += delta
	_bl_t += delta
	if _bl_t >= BL_WINDOW:
		var moved := Vector2(pos.x - _bl_pos.x, pos.z - _bl_pos.z).length()
		if moved < BL_MOVE and _bl_ground / _bl_t < BL_GROUND_FRAC:
			_bl_rest_t = BL_REST   # bounce-lock: suppress hops so it settles, grounds, reroutes out
		_bl_pos = pos
		_bl_t = 0.0
		_bl_ground = 0.0
	_bl_rest_t = maxf(_bl_rest_t - delta, 0.0)

	if _bl_rest_t > 0.0:
		return false                     # locked: no hop until it grounds and moves on
	return _ground_dwell >= HOP_DWELL    # else require a brief ground dwell between hops


## If we're trying to move but making no net horizontal progress, hop to clear a lip/corner;
## if still stuck a while, skip the current waypoint. Returns a jump flag when stuck.
func _anti_stuck(delta: float, moving: bool) -> int:
	if not moving:
		_stuck_t = 0.0
		_win_pos = Vector3.INF
		return 0
	_win_t += delta
	if _win_pos == Vector3.INF:
		_win_pos = _bot.global_position
	if _win_t >= 0.5:
		var moved := Vector2(_bot.global_position.x - _win_pos.x,
			_bot.global_position.z - _win_pos.z).length()
		_stuck_t = _stuck_t + 0.5 if moved < 0.2 else 0.0
		_win_pos = _bot.global_position
		_win_t = 0.0
	# Wedged a while → hop. Still wedged much longer → the next waypoint is often just as
	# unreachable, so throw the route away and re-path with a new salt instead of skipping it.
	# Steering locally with no waypoints: latch/flip the wall-follow instead.
	if _stuck_t >= STUCK_SKIP:
		if _route_i < _route.size():
			_route = PackedInt64Array()   # empty → route block recomputes next tick
			_route_salt = randi()         # a different path this time
		elif _local_nav:
			_wf_force = true              # _local_steer latches (or flips hands) next tick
		_stuck_t = STUCK_HOP              # keep hopping while we work past it
	if _stuck_t >= STUCK_HOP:
		return CMD_JUMP
	return 0


# --- Graph-less local steering ----------------------------------------------------------

## Steer toward the objective with no waypoints to guide us. Straight when the way is open;
## around obstacles via a whisker fan when not; and when boxed in, Bug-style wall-following —
## keep the wall on one hand until the straight line opens up closer than where we latched
## (gets a bot out of a concave spawn room whose doorway is behind it).
## `to_waypoint` says the target is a route node rather than a far-off objective, which changes
## one rule: how a drop is read. For an objective, a deep ledge is only worth taking when the
## objective is itself below — otherwise it is a pit. A waypoint on the far side of a descent
## sits at the bot's OWN height, so that test refuses the stairs down; on ww_keep, whose two
## floors are 6.4m apart, it read the only way between them as a wall. Between two nodes the
## baker or a human already said are connected, a drop is part of the route, so allow it down to
## a survivable depth and keep refusing anything past that.
func _local_steer(delta: float, desired: Vector3, obj: Vector3,
		to_waypoint := false) -> Vector3:
	var space: PhysicsDirectSpaceState3D = _bot.get_world_3d().direct_space_state
	if space == null:
		return desired
	var obj_d := _horiz(obj)
	# Falling toward a LOWER objective is navigation, not a hazard — and depth is meaningless
	# while swimming. Otherwise deep ledges are treated as walls so avoidance can't pit-dive.
	var allow_drop: bool = obj.y < _bot.global_position.y - 1.5 \
		or (_bot._move_ctx != null and _bot._move_ctx.check_water())
	var drop_depth: float = DROP_MAX_LEG if to_waypoint else DROP_MAX
	# Progress watchdog: whisker dodging can orbit a local minimum forever — the bot keeps
	# moving (so the position-based stuck detector never fires) without ever getting closer.
	# No new best distance for a while → stop dodging and wall-follow out instead.
	if _wf_hand == 0:
		if _prog_obj.distance_to(obj) > 8.0 or obj_d < _prog_best - 0.5:
			_prog_obj = obj
			_prog_best = obj_d
			_prog_t = 0.0
		else:
			_prog_t += delta
	if _wf_force:
		_wf_force = false
		if _wf_hand == 0:
			_wf_latch(space, desired, obj)
		else:
			# Still wedged while following → this hand isn't working; try the other one.
			_wf_hand = -_wf_hand
			_wf_dir = desired
			_wf_t = 0.0
			_wf_leave_dist = obj_d
	if _wf_hand != 0:
		return _wall_follow(space, delta, desired, obj, allow_drop, drop_depth)
	_avoid_t -= delta
	# Probe no farther than the objective itself, so a wall BEHIND a close objective doesn't
	# read as "path blocked".
	var open_d := minf(PROBE_DIST, obj_d)
	if _clearance(space, desired, open_d) >= open_d \
			and (allow_drop or not _drop_ahead(space, desired, drop_depth)):
		_avoid_dir = Vector3.ZERO
		return desired
	if _prog_t > 6.0:
		# Blocked AND not closing in despite the dodging — a local minimum; wall out of it.
		_prog_t = 0.0
		_wf_latch(space, desired, obj)
		return _wall_follow(space, delta, desired, obj, allow_drop, drop_depth)
	# Keep a chosen dodge direction for a beat (as long as it stays open) so re-probing every
	# tick can't dither between two comparable sides and stall in the middle.
	if _avoid_dir != Vector3.ZERO and _avoid_t > 0.0 and _clearance(space, _avoid_dir) > 1.2:
		_tally("d_hold")
		return _avoid_dir
	var best := Vector3.ZERO
	var best_score := 0.0
	for a in WHISKERS:
		var d := desired.rotated(Vector3.UP, a)
		var c := _clearance(space, d)
		if c < 1.2 or (not allow_drop and _drop_ahead(space, d, drop_depth)):
			continue
		# Clearance weighted toward the desired heading, so we deviate no more than needed.
		var score: float = c * (0.55 + 0.45 * cos(a))
		if score > best_score:
			best_score = score
			best = d
	if best == Vector3.ZERO:
		# Every whisker is blocked → boxed in; follow the wall out.
		_wf_latch(space, desired, obj)
		return _wall_follow(space, delta, desired, obj, allow_drop, drop_depth)
	_avoid_dir = best
	_avoid_t = 0.35
	_tally("d_whisker")
	return best


## Whisker dodge for waypoint following: deviate only as much as the obstacle demands, then carry
## on to the same waypoint. Deliberately NOT _local_steer — no wall-follow, no progress watchdog,
## no committing to a hand: the waypoint is metres away and the route is already the plan, so when
## no whisker is open this hands the tick back unchanged and leaves it to _anti_stuck and the
## re-path. One ray in the common case: if the straight line is clear it returns immediately.
## `precise` marks a leg whose EXECUTION needs sub-metre placement — a lift's 0.35m call band, a
## ladder mount, a jump or a duck. Contact navigation is suppressed there and only the whisker fan
## runs: on those legs the approach IS the manoeuvre and a heading turned along a wall misses it.
## That is the one thing the bots' steering had no way to say before — precision was expressed by
## disabling individual features case by case rather than as a property of the goal.
func _dodge(delta: float, desired: Vector3, target: Vector3, center := Vector3.INF,
		precise := false) -> Vector3:
	if desired == Vector3.ZERO:
		return desired
	var space: PhysicsDirectSpaceState3D = _bot.get_world_3d().direct_space_state
	if space == null:
		return desired
	_avoid_t = maxf(_avoid_t - delta, 0.0)
	# Hold a chosen dodge for a beat so re-probing cannot dither between two comparable sides.
	#
	# FIRST, before the "is the straight line clear" test below, which is the whole point. That
	# test used to run first and cleared the hold the instant the line read clear — so at a
	# grazing boundary, clear/blocked alternated at 60Hz and the bot was handed two very
	# different headings on alternate ticks. Measured on ww_ravine: the DEMANDED heading moved
	# 505 deg/s on average and reversed by more than 90 degrees on 3.4% of ticks, which the head
	# then chased at up to _nav_turn. That is the spinning — a commitment that was written down
	# and then bypassed every other frame.
	if _avoid_dir != Vector3.ZERO and _avoid_t > 0.0 and _clearance(space, _avoid_dir) > 1.2:
		return _avoid_dir
	# Probe no farther than the waypoint itself, or a wall just beyond it reads as "blocked".
	var reach: float = clampf(_horiz(target), 0.6, PROBE_DIST)
	if _clearance(space, desired, reach) >= reach:
		_avoid_dir = Vector3.ZERO
		_slide_n = Vector3.ZERO      # clear of it: the next contact chooses a side afresh
		_slide_dir = Vector3.ZERO
		_tally("d_clear")
		return desired
	# The face we are up against, taken from the probe that just found it. Grabbed here because
	# the centre retry below probes a different direction and would overwrite it.
	var wall_n := _last_wall_n
	# Blocked. First give up the wander offset: the node CENTRE is the line the baker validated,
	# and the offset exists only so bots don't all walk the same rail. Rolled up to a metre wide,
	# it is enough to miss a doorway and lean on the wall beside it — which is exactly how the
	# ww_ravine bots spent whole rounds shuffling along one diagonal wall.
	if center != Vector3.INF:
		var to_center := center - _bot.global_position
		to_center.y = 0.0
		if to_center.length() > 0.05:
			var cdir := to_center.normalized()
			var creach: float = clampf(to_center.length(), 0.6, PROBE_DIST)
			if _clearance(space, cdir, creach) >= creach:
				_wp_off = Vector3.ZERO   # don't re-roll it back on the next tick
				_avoid_dir = Vector3.ZERO
				_tally("d_centre")
				return cdir
	# Dropping toward a waypoint BELOW is the route doing its job; otherwise a ledge is a wall.
	var allow_drop: bool = target.y < _bot.global_position.y - 1.5 \
		or (_bot._move_ctx != null and _bot._move_ctx.check_water())
	# Contact navigation: turn along what is in the way and keep walking (see SLIDE_JITTER_MIN).
	# This is the bot's normal response to an obstacle, not a last resort — the whisker fan below
	# only gets the cases this cannot answer. It reads the surface it is touching; the fan scores
	# seven fixed angles and in a corridor two of them score alike and it dithers between them.
	_tally("dodge_blocked")
	if not precise:
		if wall_n != Vector3.ZERO:
			var sl: Vector3
			if _slide_n != Vector3.ZERO and wall_n.dot(_slide_n) > 0.7 \
					and _slide_dir != Vector3.ZERO:
				sl = _slide_dir          # same wall as last tick: keep going the way we chose
			else:
				var wl := Vector3(-wall_n.z, 0.0, wall_n.x)
				var wr := Vector3(wall_n.z, 0.0, -wall_n.x)
				sl = wl if wl.dot(desired) > wr.dot(desired) else wr
				if randf() < 0.5:
					sl = sl.rotated(Vector3.UP,
							deg_to_rad(randf_range(SLIDE_JITTER_MIN, SLIDE_JITTER_MAX)))
			# A wall is a reason to turn, never a reason to walk off a ledge.
			if allow_drop or not _drop_ahead(space, sl):
				_slide_n = wall_n
				_slide_dir = sl
				_avoid_dir = sl
				_avoid_t = 0.35
				_tally("contact_nav")
				return sl
	var best := Vector3.ZERO
	var best_score := 0.0
	for a in WHISKERS:
		var d := desired.rotated(Vector3.UP, a)
		var c := _clearance(space, d)
		if c < 1.2 or (not allow_drop and _drop_ahead(space, d)):
			continue
		var score: float = c * (0.55 + 0.45 * cos(a))   # weighted toward the waypoint
		if score > best_score:
			best_score = score
			best = d
	if best == Vector3.ZERO:
		_tally("d_boxed")
		return desired          # boxed in — anti-stuck hops, then re-paths around it
	_avoid_dir = best
	_avoid_t = 0.35
	return best


## One wall-follow tick: hug the wall on the _wf_hand side — turn away from it when the way
## ahead closes, curl toward it when it falls away (doorways/outside corners). Releases when
## the straight line to the objective is open AND we're closer than where we latched on (so
## we can't re-latch the same spot forever); a timeout flips hands in case we picked badly.
func _wall_follow(space: PhysicsDirectSpaceState3D, delta: float, desired: Vector3,
		obj: Vector3, allow_drop: bool, drop_depth := DROP_MAX) -> Vector3:
	_wf_t += delta
	if _wf_obj.distance_to(obj) > 8.0:
		_wf_hand = 0  # objective changed under us — the follow is stale; re-evaluate fresh
		return desired
	var obj_d := _horiz(obj)
	var open_d := minf(PROBE_DIST, obj_d)
	if obj_d < _wf_leave_dist - 0.5 and _clearance(space, desired, open_d) >= open_d:
		_wf_hand = 0
		return desired
	if _wf_t > WF_TIMEOUT:
		_wf_hand = -_wf_hand
		_wf_t = 0.0
		_wf_leave_dist = obj_d
	if _wf_dir == Vector3.ZERO:
		_wf_dir = desired
	if _clearance(space, _wf_dir, 1.4) < 1.4 \
			or (not allow_drop and _drop_ahead(space, _wf_dir, drop_depth)):
		# Way ahead closed (wall, or a ledge we won't take) → rotate away from the wall in
		# 45° steps until it opens; inside corners turn 90°, dead ends turn all the way back.
		for _i in 7:
			_wf_dir = _wf_dir.rotated(Vector3.UP, _wf_hand * PI / 4.0)
			if _clearance(space, _wf_dir, 1.4) >= 1.4 \
					and (allow_drop or not _drop_ahead(space, _wf_dir, drop_depth)):
				break
	else:
		var side_d := _clearance(space, _wf_dir.rotated(Vector3.UP, -_wf_hand * PI / 2.0), 2.2)
		if side_d >= 2.2:
			# The wall fell away — a doorway or an outside corner. Curl toward it so we wrap
			# around (or through) instead of walking off in a straight line.
			_wf_dir = _wf_dir.rotated(Vector3.UP, -_wf_hand * 2.6 * delta)
		elif side_d < 0.7:
			_wf_dir = _wf_dir.rotated(Vector3.UP, _wf_hand * 1.8 * delta)  # scraping — ease off
	return _wf_dir


## Start wall-following. The wall goes on the more-blocked side (that's where the wall is);
## a coin flip breaks ties so bots latched at the same spot don't all pick the same way round.
func _wf_latch(space: PhysicsDirectSpaceState3D, desired: Vector3, obj: Vector3) -> void:
	var left := _clearance(space, desired.rotated(Vector3.UP, PI / 2.0))
	var right := _clearance(space, desired.rotated(Vector3.UP, -PI / 2.0))
	if absf(left - right) < 0.01:
		_wf_hand = 1 if randf() < 0.5 else -1
	else:
		_wf_hand = 1 if right < left else -1
	_wf_dir = desired
	_wf_t = 0.0
	_wf_leave_dist = _horiz(obj)
	_wf_obj = obj


## Horizontal clearance along `dir` (≤ max_dist): distance to the nearest thing that would
## actually stop the bot walking. Two rays — one just above step height, one at head height —
## distinguish real walls from climbable geometry: a wall's hits line up vertically, a
## walkable ramp reports a floor-like normal, and stair risers spread out with probe height.
func _clearance(space: PhysicsDirectSpaceState3D, dir: Vector3, max_dist := PROBE_DIST) -> float:
	var lo := _probe(space, dir, PROBE_LOW, max_dist)
	var lo_n := _probe_n
	var hi := _probe(space, dir, PROBE_HIGH, max_dist)
	# Near height first, so a low obstruction wins over the lintel above it: the surface wanted
	# is the one belonging to whatever the body is about to meet.
	_last_wall_n = lo_n if lo_n != Vector3.ZERO else _probe_n
	if lo.x < max_dist:
		if lo.y > 0.7:
			return max_dist  # walkable ramp, not a wall
		if hi.x - lo.x >= STAIR_GAP:
			return max_dist  # hits spread out with height → climbable stairs
	return minf(lo.x, hi.x)


## One probe ray at `height` along `dir`. Returns (hit distance, hit normal.y) as a Vector2;
## distance = max_dist when nothing was hit. Reuses _ray_query — probes run per bot per tick.
## The hit's HORIZONTAL normal goes to _probe_n (ZERO when there is none), because contact
## navigation wants the face it is touching and re-casting these rays to ask was the cost of a
## second copy of this function.
func _probe(space: PhysicsDirectSpaceState3D, dir: Vector3, height: float,
		max_dist: float) -> Vector2:
	var from := _bot.global_position + Vector3(0.0, height, 0.0)
	_ray_query.from = from
	_ray_query.to = from + dir * max_dist
	var r := space.intersect_ray(_ray_query)
	if r.is_empty():
		_probe_n = Vector3.ZERO
		return Vector2(max_dist, 0.0)
	var nrm: Vector3 = r["normal"]
	_probe_n = Vector3(nrm.x, 0.0, nrm.z)
	_probe_n = _probe_n.normalized() if _probe_n.length() > 0.01 else Vector3.ZERO
	return Vector2(from.distance_to(r.position), nrm.y)


func _tally(k: String) -> void:
	if not diag:
		return
	steer_tally[k] = int(steer_tally.get(k, 0)) + 1


## True when the floor just ahead along `dir` is a ledge deeper than DROP_MAX. Used to treat
## pit edges as walls while dodging/wall-following (a bot dodging sideways shouldn't fall in).
func _drop_ahead(space: PhysicsDirectSpaceState3D, dir: Vector3, depth := DROP_MAX) -> bool:
	return _drop_depth(space, dir, depth) > depth


## How far DOWN the floor is, 1.1m ahead along `dir` — INF past `depth`, which is as far as the ray
## is cast. The bool above is the same question with a threshold applied; asking for the depth lets
## one ray answer at several thresholds instead of one ray each (see _side_drops).
##
## Measured from 0.3m ABOVE the feet, where the ray starts, which is the convention `_drop_ahead`
## has always used: a depth of d means the floor is d - 0.3 below the bot's own.
func _drop_depth(space: PhysicsDirectSpaceState3D, dir: Vector3, depth := DROP_MAX) -> float:
	var from := _bot.global_position + dir * 1.1 + Vector3(0.0, 0.3, 0.0)
	_floor_query.from = from
	_floor_query.to = from + Vector3(0.0, -depth, 0.0)
	var hit := space.intersect_ray(_floor_query)
	return INF if hit.is_empty() else from.y - float(hit["position"].y)


## Ledge safety while route-following: if there's a deep drop just off to a side of our heading, the
## bot is on a narrow bridge — steer at the EXACT route-node centre instead of the wandered target, so
## the per-waypoint lateral offset can't nudge the bot off the edge, and lean slightly away from a
## one-sided drop. On open ground (no side drops) the natural offset is kept for path variety.
## Deep drops to either side of `dir`: bit 1 left, bit 2 right. Two rays, taken once a tick.
##
## Height only. Counting a submerged floor as "no footing" too was tried and measured WORSE on
## ww_roc2 (11 swims a match against 5): once a bot is actually in the water both sides report it,
## so the precision this gates stays latched on and the bot crawls instead of striking out for the
## bank. Water is a slow mistake, not a fall, and the two want different handling.
##
## Bits 4-8 are a second answer off the SAME rays, and they are the one ordinary walkways need. A
## 4.5m drop is a cliff, and almost nothing a bot walks beside is one: ww_2fort's base ramp
## descends from the battlement at 5.07 to the yard at 0.27 with the yard only 1.5-4.8m below it,
## so the whole length of it read as open ground and kept the full lateral roll — and cutting the
## corner off that ramp into the yard is what a player sees as a bot shortcutting a ramp. The
## threshold is FALL_REROUTE, since nothing in the graph climbs more than that, so past it there is
## no walking back up. Both thresholds are in the RAY's frame, which starts 0.3 above the feet
## (see _drop_depth), so they bite 0.3 shallower than they read — true of DROP_MAX here since
## long before this, and left alone so the numbers keep matching the soaks behind them.
##
## What the two answers are allowed to do is NOT the same, and that restraint is the measured part.
## A shallow drop cancels the wander offset and NOTHING else. Four richer ways of spending it were
## soaked on ww_2fort and three are worse than doing nothing — don't retry these blind:
##
##   tighter arrival radius + _ledge_safe's lean   falls 80 -> 126, captures 7.5 -> 6.5
##   tighter arrival radius alone                 basin climb-out falls 58 -> 198
##   goal.precise on every shallow drop           ramp falls 13 -> 26, and it puts precise
##                                                steering on 30% of all legs (from 8%), taking
##                                                contact navigation 2.9% -> 1.2%
##   all three together                           ramp 13 -> 18, basin 38 -> 69
##
## The lean is what does the damage: with this probe firing beside every ramp and curb, pushing 0.4
## sideways off a one-sided drop walks bots off the line it is there to hold them on.
##
## Cancelling the wander alone, against the committed brain, n=3 600s six-bot soaks: falls on the
## two base ramps 28/19/15 -> 14/11/15, falls overall 152/112/85 -> 134/89/83. Better, not fixed —
## bots still cut that corner about half as often, and the remaining cause is the arrival radius,
## which the second line above says cannot simply be tightened here.
func _side_drops(dir: Vector3) -> int:
	var space := _bot.get_world_3d().direct_space_state
	var side := Vector3(-dir.z, 0.0, dir.x)   # unit-ish left perpendicular of the heading
	var left := _drop_depth(space, (dir + side * 0.7).normalized())
	var right := _drop_depth(space, (dir - side * 0.7).normalized())
	var out := 0
	if left > DROP_MAX:
		out |= 1
	if right > DROP_MAX:
		out |= 2
	if left > FALL_REROUTE:
		out |= 4
	if right > FALL_REROUTE:
		out |= 8
	return out


## `centre` is passed in rather than re-read from the route: the give-up path can empty _route
## after wp_center was captured, and indexing it here then threw Out of bounds on an empty array.
func _ledge_safe(wish_dir: Vector3, centre: Vector3) -> Vector3:
	var side := Vector3(-wish_dir.z, 0.0, wish_dir.x)      # unit-ish left perpendicular of the heading
	var drop_l := (_ledge_sides & 1) != 0
	var drop_r := (_ledge_sides & 2) != 0
	if not drop_l and not drop_r:
		return wish_dir
	var cd := Vector3(centre.x - _bot.global_position.x, 0.0, centre.z - _bot.global_position.z)
	var safe := cd.normalized() if cd.length() > 0.1 else wish_dir
	if drop_l != drop_r:
		safe = (safe + side * (-0.4 if drop_l else 0.4)).normalized()   # step away from the drop side
	return safe


## Rate-limit the heading so it sweeps rather than snaps (see WISH_TURN_MAX). A climb is exempt:
## the movement layer reads the LOOK direction there, and easing into it would slow the grab.
func _slew(want: Vector3, delta: float) -> Vector3:
	if want == Vector3.ZERO or _wish_prev == Vector3.ZERO \
			or (_bot._move_ctx != null and _bot._move_ctx.ladder_normal != Vector3.ZERO):
		_wish_prev = want
		if want != Vector3.ZERO:
			_wish_yaw = atan2(-want.x, -want.z)
		return want
	var a := atan2(-_wish_prev.x, -_wish_prev.z)
	var b := atan2(-want.x, -want.z)
	var cap := WISH_TURN_MAX * delta
	if absf(angle_difference(a, b)) <= cap:
		_wish_prev = want
		_wish_yaw = b
	else:
		_wish_yaw = rotate_toward(a, b, cap)
		_wish_prev = Vector3(-sin(_wish_yaw), 0.0, -cos(_wish_yaw))
	return _wish_prev


## The one function that decides which way the bot walks. Returns the horizontal wish direction
## and leaves the look pitch in _steer_pitch. Everything above states a Goal; nothing above
## writes a heading.
func _steer(delta: float, g: Goal) -> Vector3:
	_steer_pitch = 0.0
	_tally("calls")
	if g.pos == Vector3.INF:
		return Vector3.ZERO
	var pos := _bot.global_position
	var to := g.pos - pos
	var flat := Vector3(to.x, 0.0, to.z)

	# A climb is not a walk. Inside a MASK_LADDER volume the movement layer overrides velocity
	# toward where the bot LOOKS (LadderWater.ladder_velocity), so the goal is met by facing up the
	# axis and pressing forward. No jump — that is a dismount.
	if g.climb != Vector3.INF:
		_tally("climb")
		return _steer_climb(g.climb)
	# Arrived? Horizontally AND vertically, for the reason arrive_vert exists: a bot standing on
	# the roof OVER its goal is not on it. Height used to be ignored for the objective and the
	# cost was silent — the bot stops pressing, so the wedge detector (which only arms while a
	# bot is trying to move) disarms itself and nothing can see it. Measured on ww_ravine:
	# carriers stood 2.8m directly above the flag at exactly 0.0 m/s for 90-120s at a stretch.
	#
	# A goal well BELOW is a drop not yet taken: stopping at the arrival radius would leave the
	# bot frozen a few cm shy of the lip, so keep pushing until it has actually stepped off.
	# Derived here rather than passed in, so it cannot describe a goal the caller has since
	# replaced — the lift block rewrites goal.pos and would otherwise carry the old leg's answer.
	var flen := flat.length()
	var pending_drop := to.y < -VERT_ARRIVE
	if flen < maxf(g.radius, 0.01) and absf(to.y) < VERT_ARRIVE and not pending_drop:
		return Vector3.ZERO
	if flen < 0.01:
		return Vector3.ZERO
	var dir := flat / flen
	_steer_pitch = asin(clampf(to.normalized().y, -1.0, 1.0))

	# Nothing guiding us but the goal itself: the full navigator, which can wall-follow out of a
	# concave room rather than just deviating around what is directly ahead.
	if g.free:
		_local_nav = true
		_tally("free")
		return _ladder_exit(_local_steer(delta, dir, g.pos))
	if g.rescue:
		_local_nav = true
		_tally("rescue")
		return _ladder_exit(
				_local_steer(delta, dir, g.centre if g.centre != Vector3.INF else g.pos, true))
	# Beside a drop the validated node line is the only safe one, so hug it (see _ledge_safe).
	if g.centre != Vector3.INF and not pending_drop and not g.precise:
		dir = _ledge_safe(dir, g.centre)
	_tally("precise" if g.precise else "dodge")
	return _ladder_exit(_dodge(delta, dir, g.pos, g.centre, g.precise))


## Where to stand when a lift is the question, i.e. once the bot is close enough that the answer
## is about the lift rather than about getting to it. Returns false when it is not, leaving the
## goal as the route or objective stated it.
##
## Three answers, and picking the wrong one is what wedges a lift: aboard, hold the middle of the
## deck and ride; the deck is here, walk on — which is also what summons it, a plat coming when
## its call volume is touched; otherwise stand CLEAR of the shaft, because a bot waiting inside
## it is what a descending deck blocks on. Each of those is a PLACE TO BE, so each is a goal with
## the tolerance that band actually needs, rather than a heading written straight into wish_dir.
func _lift_goal(goal: Goal, wp_center: Vector3) -> bool:
	var here := _deck_local(_bot.global_position)
	if not _ride_box.grow(LIFT_APPROACH).has_point(here):
		return false
	var col := Vector3(wp_center.x, _bot.global_position.y, wp_center.z)
	var deck_dy := absf(_lift_deck_y(wp_center) - _bot.global_position.y)
	var aboard := _ride_box.has_point(here) and deck_dy < LIFT_ON_DECK
	# Step on when the deck is at your feet. Requiring the lift to be SETTLED as well sounds safe
	# and is why bots stood beside lifts instead of riding them: measured on ww_storm, the lift is
	# in motion on 76% of the ticks a bot is near it and parked at the far stop on 80%, so the
	# stillness being waited for mostly never arrives — they boarded on 0.8% of ticks and waited
	# in the call band on 12%. A deck within LIFT_ON_DECK of the feet is level with you whatever
	# it is doing next, and stepping onto that is what a player does; settled is still required
	# for the wider LIFT_BOARD_STEP window, where a moving deck really can leave you in the shaft.
	var board := deck_dy < LIFT_BOARD_STEP \
			and (_lift_settled() or deck_dy < LIFT_ON_DECK)
	# Stated fresh rather than patched: a goal source says its whole goal, so a field added to
	# Goal later cannot arrive here still carrying the pre-lift leg's answer.
	goal.reset()
	goal.precise = true       # every one of these is a sub-metre placement
	if aboard or board:
		goal.pos = col                                   # the middle of the deck
		goal.radius = LIFT_CENTER_NEAR
		_tally("L_board" if not aboard else "L_aboard")
	elif _ride_box.grow(LIFT_CLEAR).has_point(here):
		goal.pos = _bot.global_position + _away_from_deck(here)   # out of the shaft
		_tally("L_backout")
	elif not _ride_box.grow(LIFT_CALL_REACH).has_point(here):
		goal.pos = col                                   # into the call band
		_tally("L_toband")
	else:
		goal.pos = _bot.global_position                  # in the band: wait here
		_tally("L_wait")
	if diag:
		_tally("L_settled" if _lift_settled() else "L_moving")
		if deck_dy >= LIFT_BOARD_STEP:
			_tally("L_deck_away")
	return true


## On the rungs with nothing left to climb, i.e. topped out. Steering at the landing pins the bot
## against the shaft: LadderWater.ladder_velocity splits the wish along the wall normal and remaps
## THAT component to climb/descend, so the one direction a body on a ladder cannot travel is
## straight off it, and it only gets the push-away once grounded, which a bot hovering in the
## hole never becomes. Measured on ww_ravine's 12m shaft: x held at 4.25 +/- 0.05 for 24s at
## every height from 43.4 to 44.4, so climbing higher does not help. Leave the way the ladder
## does allow — sideways along the wall, on whichever side the chosen heading already favours.
##
## LAST, and a projection rather than a replacement. Running it first — as a short-circuit before
## the navigator — starves contact navigation on exactly the ticks a bot is scraping a ladder
## volume: on ww_ravine2 that was 7.3% of steer calls against contact navigation's 6.9%, and it
## cost the map its whole coverage gain (247 -> 212 cells).
func _ladder_exit(dir: Vector3) -> Vector3:
	if dir == Vector3.ZERO or _bot._move_ctx == null \
			or _bot._move_ctx.ladder_normal == Vector3.ZERO:
		_exit_sign = 0               # off the rungs: the next contact picks a side afresh
		return dir
	var perp := Vector3.UP.cross(_bot._move_ctx.ladder_normal)
	if perp.length() <= 0.01:
		return dir
	perp = perp.normalized()
	if _exit_sign == 0:
		_exit_sign = 1 if dir.dot(perp) >= 0.0 else -1
	_tally("topout")
	_steer_pitch = 0.0
	return perp * float(_exit_sign)


## The climb half of _steer: ride the axis, self-centring into the rungs.
func _steer_climb(axis: Vector3) -> Vector3:
	var d := axis - _bot.global_position
	var dh := Vector3(d.x, 0.0, d.z)
	_steer_pitch = asin(clampf(d.normalized().y, -1.0, 1.0))  # look up the axis -> climb up
	if dh.length() > 1.0:
		return dh.normalized()                       # ramp/offset ladder: climb toward the axis
	if _bot._move_ctx == null or _bot._move_ctx.ladder_normal == Vector3.ZERO:
		return Vector3.ZERO
	var ln: Vector3 = _bot._move_ctx.ladder_normal
	var into := Vector3(-ln.x, 0.0, -ln.z)           # vertical ladder: press into the rungs
	if into.length() <= 0.01:
		return Vector3.ZERO
	into = into.normalized()
	# Pressing straight in holds the climb but never corrects a lateral offset, and the ladder
	# Volume is fatter than the rungs: a body that grabbed at the EDGE of the shaft rides up into
	# the wall beside it and stops dead — measured on ww_ravine, 1.1m up and then nothing, for
	# minutes. Blend a pull toward the shaft's own column and the climb self-centres.
	if dh.length() > 0.05:
		into = (into + dh.normalized() * LADDER_CENTER_PULL).normalized()
	return into


## Drop all local-steering state (whisker hold, wall-follow, progress watchdog) so a
## later engagement starts fresh.
func _reset_local_steer() -> void:
	_wf_hand = 0
	_avoid_dir = Vector3.ZERO
	_wf_force = false
	_prog_obj = Vector3.INF


func _otally(k: String) -> void:
	if diag:
		obj_tally[k] = int(obj_tally.get(k, 0)) + 1


## Hold the objective steady unless a change is worth the turn (see OBJ_HOLD).
func _commit_objective(want: Vector3, delta: float) -> Vector3:
	_obj_held_t += delta
	if want == Vector3.INF or _obj_held == Vector3.INF:
		_obj_held = want
		_obj_held_t = 0.0
		return want
	if _obj_held.distance_to(want) <= OBJ_SWITCH_DIST:
		_obj_held = want            # same intent, target drifting: follow it
		return want
	if _obj_held_t < OBJ_HOLD:
		return _obj_held            # too soon to change our mind; finish the turn we started
	_obj_held = want
	_obj_held_t = 0.0
	return want


## Objective destination, dispatched by the map's game mode (Vector3.INF if none). Navigation
## and combat are mode-agnostic; only this picks WHERE to go.
func _choose_objective(delta: float) -> Vector3:
	_obj_is_control = false
	_roaming = false
	if not _cp_positions.is_empty():
		# Sequential control-point map (ww_chasm): push the team's live capture point.
		var cp := _sequential_cap_target()
		if cp != Vector3.INF:
			_obj_is_control = true
			_otally("cp_sequential"); return cp
	if _is_ctf:
		# CTF: carry the flag to our cap dropoff, else go grab a flag.
		if not _bot.carried_items.is_empty():
			var cap := _home_cap_pos()
			if cap != Vector3.INF:
				_otally("ctf_cap"); return cap
		var flag := _find_grabbable_flag()
		if flag != null:
			_otally("ctf_flag"); return flag.global_position
		# Every enemy flag is in team-mate hands — head for our own dropoff, which is where the
		# carrier is going and where the defence that can stop it will be. Once we are there,
		# standing on it achieves nothing: fall through and go hunting instead.
		var escort := _home_cap_pos()
		if escort != Vector3.INF:
			# Latched, not a bare threshold: arriving satisfies the escort and only drifting well
			# clear of it re-arms one. See ESCORT_REARM.
			var ed := _bot.global_position.distance_to(escort)
			if ed <= ESCORT_NEAR:
				_escort_done = true
			elif ed > ESCORT_REARM:
				_escort_done = false
			if not _escort_done:
				_otally("escort"); return escort
	elif not _cap_zones.is_empty():
		# Territorial control: push the next zone the map will actually let us take.
		var zone := _capture_zone_target()
		if zone != Vector3.INF:
			_obj_is_control = true
			_otally("zone"); return zone
	elif _graph != null and _graph.loaded and not _graph.cap_positions.is_empty():
		# Control-point: contest the nearest marked control zone (the FL_CAP waypoint).
		var cp := _graph.cap_nearest(_bot.global_position)
		if cp != Vector3.INF:
			_obj_is_control = true
			_otally("cap_node"); return cp
	# No objective for this mode (or DM) → hunt whoever is in mind, else tour the map.
	#
	# Chasing the nearest enemy outright used to be the whole fallback, and on an objective-less
	# map it is a poor one: every bot beelines at its closest opponent from the moment it spawns,
	# so a deathmatch map collapses into one scrum wherever the spawns happen to face and the rest
	# of the level never gets walked (measured on ww_skytower: six bots spent 180s inside a 20m
	# ball at the foot of the tower and not one of them ever went up it). Roaming costs nothing in
	# fights — engagement is opportunistic and independent of the objective, so a roaming bot
	# still shoots anything entering its cone — and it spreads bots over the whole map.
	#
	# `_known` (seen, or felt through on_damaged) rather than the omniscient _nearest_enemy: it is
	# knowing where an unseen enemy is that produced the beeline in the first place.
	if _known != null and is_instance_valid(_known) \
			and _bot.global_position.distance_to(_known.global_position) <= HUNT_NEAR:
		_otally("hunt")
		return _known.global_position
	var roam := _roam_target(delta)
	if roam != Vector3.INF:
		_roaming = true
		_otally("roam")
		return roam
	# No graph to roam on: the old behaviour is still better than standing still.
	var enemy := _nearest_enemy()
	_otally("nearest" if enemy != null else "none")
	return enemy.global_position if enemy != null else Vector3.INF


## Somewhere to be on a map with no objective. Holds one waypoint until the bot gets there (or
## gives up on it), so the bot walks a leg of the map at a time instead of re-rolling a direction
## every tick and jittering on the spot. INF when there is no graph to pick from.
##
## Farthest of ROAM_TRIES random samples, rather than a single draw: a uniform pick is usually a
## near node (waypoints are dense and most of them are close to anywhere), which walks the bot a
## few metres and re-picks. Taking the farthest of a handful biases legs long enough to cross
## rooms and climb, without ever committing to the same far corner every time.
func _roam_target(delta: float) -> Vector3:
	if _graph == null or not _graph.loaded or _graph.positions.is_empty():
		return Vector3.INF
	_roam_t += delta
	if _roam_pos != Vector3.INF and _roam_t < ROAM_GIVEUP \
			and _horiz(_roam_pos) > ROAM_NEAR:
		return _roam_pos
	var here := _bot.global_position
	var best := Vector3.INF
	var best_d := ROAM_MIN
	for _i in ROAM_TRIES:
		var p: Vector3 = _graph.positions[randi() % _graph.positions.size()]
		var d := here.distance_to(p)
		if d > best_d:
			best_d = d
			best = p
	if best == Vector3.INF:
		return _roam_pos    # every sample was underfoot; keep whatever we had (may be INF)
	_roam_pos = best
	_roam_t = 0.0
	return _roam_pos


## The team's live capture point on a sequential control-point map (ww_chasm's PotatoC point1..N).
## Ownership lives in PotatoC.global_vars["point<i>"]: 0 neutral, 1 blue, 2 red (== the Team enum).
## Blue advances low→high and pushes the first point it doesn't own; red advances high→low. Returns
## the cap-volume centre to route to, or INF when the team already owns them all (round about to reset)
## or the pattern isn't loaded. Host-side read — bots run on the host, where these globals are truth.
func _sequential_cap_target() -> Vector3:
	var team: int = _bot.team
	# Allied non-base teams (chasm's dragonrider teams 3/4) inherit their ally's push direction.
	var descending: bool = team == GameConsts.Team.RED
	if not descending and team != GameConsts.Team.BLUE:
		var red_allies: int = GoalSystem.team_allies[GameConsts.Team.RED - 1] \
			if GameConsts.Team.RED - 1 < GoalSystem.team_allies.size() else 0
		descending = (red_allies & (1 << (team - 1))) != 0
	var mine: int = GameConsts.Team.RED if descending else GameConsts.Team.BLUE
	var n := _cp_positions.size()
	var order := range(n - 1, -1, -1) if descending else range(n)
	for i in order:
		if int(PotatoC.global_vars.get("point%d" % (i + 1), 0)) != mine:
			return _cp_positions[i]
	return Vector3.INF


## The capture zone to push on a territorial-control map: the nearest one whose activation
## criteria our team currently passes. The map's own goal wiring (if_goal_is_inactive /
## if_goal_is_removed chains between neighbouring zones) leaves only the live zone(s) qualifying,
## so the bot advances the warpath without the brain knowing the sequence. INF once everything
## takeable is held — falls through to hunting enemies.
##
## Re-evaluated on a timer, not per tick: check_activation walks every criterion (logging each
## failure), and the answer only changes when a zone flips.
func _capture_zone_target() -> Vector3:
	if _zone_t > 0.0:
		return _zone_pos
	_zone_t = ZONE_RECHECK
	_zone_pos = Vector3.INF
	var best_d := INF
	for i in _cap_zones.size():
		var g: InfoTFGoal = _cap_zones[i]
		if not is_instance_valid(g) or g.goal_state == TFGoalBase.GoalState.REMOVED:
			continue
		if not g.check_activation(_bot):
			continue
		var d: float = _bot.global_position.distance_squared_to(_cap_zone_pos[i])
		if d < best_d:
			best_d = d
			_zone_pos = _cap_zone_pos[i]
	return _zone_pos


## The nearest grabbable flag this bot's team can take (from the static set found at setup —
## the game only lets a player grab the flag whose req_team matches its team).
func _find_grabbable_flag() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for g in _my_flags:
		if not is_instance_valid(g) or g in _bot.carried_items:
			continue
		# A team-mate already has it: two bots converging on one flag is one bot wasted, and the
		# chaser tails the carrier around the map because the objective moves with it.
		var holder: Node = g.get("_carrier")
		if holder != null and is_instance_valid(holder) and holder.get("team") == _bot.team:
			continue
		var d: float = _bot.global_position.distance_squared_to(g.global_position)
		if d < best_d:
			best_d = d
			best = g
	return best


## Where to bring a carried flag to score. Preferred: the live capture goal found at setup (its
## `team_no` matched our team) — works on every map with no baked data. Fallback (hand-authored HPB
## maps that predate the goal scan): the DEFEND waypoint nearest our spawn, which sits in the cap
## brush. Cached (both branches populate _cap_pos).
func _home_cap_pos() -> Vector3:
	if _cap_pos != Vector3.INF:
		return _cap_pos
	if _graph == null or not _graph.loaded:
		return Vector3.INF
	_cap_pos = _graph.defend_nearest(_spawn_pos)
	return _cap_pos


## World-space centre of a goal entity's geometry. Brush goals (cap volumes) carry no `origin`, so
## their node is at world 0 and only the mesh/collision AABB gives the real location. Mirrors
## waypoint_bake.gd::_node_world_aabb. Falls back to the node origin for a point goal with neither.
func _goal_center(node: Node3D) -> Vector3:
	var out := AABB()
	var have := false
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null:
			continue
		var w := mi.global_transform * mi.mesh.get_aabb()
		out = w if not have else out.merge(w)
		have = true
	if not have:
		for c in node.find_children("*", "CollisionShape3D", true, false):
			var cs := c as CollisionShape3D
			if cs.shape == null:
				continue
			var w := cs.global_transform * cs.shape.get_debug_mesh().get_aabb()
			out = w if not have else out.merge(w)
			have = true
	return out.get_center() if have else node.global_position


## The origin a shot really leaves from: Combat.get_aim's reconstruction for a body with no
## camera, which is what a bot puppet is (Player._active_camera returns null for one).
func _eye() -> Vector3:
	var eye_y := EYE_HEIGHT
	var sm = _bot.get_server_movement()
	if sm != null:
		eye_y = sm.cfg.crouch_eye if sm.state.is_crouched else sm.cfg.stand_eye
	return _bot.global_position + Vector3(0.0, eye_y, 0.0)


## ...and the direction it leaves along: the rate-limited, wobbling look the command carries,
## which is what _fire_at hands the weapon. Never the straight line to the target.
func _look_dir() -> Vector3:
	var cp := cos(_face_pitch)
	return Vector3(-sin(_face_yaw) * cp, sin(_face_pitch), -cos(_face_yaw) * cp)


## Follow the live target's real motion, for _lead_point. Reset whenever the target changes or is
## lost, so a fresh sighting is never led on the velocity of the last one.
func _track_target(enemy: Node3D, delta: float) -> void:
	if enemy == null:
		_lead_tgt = null
		_lead_pos = Vector3.INF
		_lead_vel = Vector3.ZERO
		return
	# The origin rather than the collision centre the aim uses: the offset between them is
	# constant, so the velocity is identical, and the centre drops when a target ducks — which
	# would read as motion the target never made.
	var here: Vector3 = enemy.global_position
	if enemy != _lead_tgt or _lead_pos == Vector3.INF:
		_lead_tgt = enemy
		_lead_pos = here
		_lead_vel = Vector3.ZERO
		return
	if delta > 0.0:
		var v := (here - _lead_pos) / delta
		# A respawn or a teleport is not motion, and leading it throws the aim at a spot nothing
		# was ever travelling toward. Five times sv_maxspeed is past anything a body can run,
		# swim or be launched to and still be going there next tick.
		_lead_vel = Vector3.ZERO if v.length() > 40.0 \
				else _lead_vel.lerp(v, clampf(delta * LEAD_EASE, 0.0, 1.0))
	_lead_pos = here


## Where to aim so a projectile MEETS a moving target: its position advanced by the velocity
## measured above over the shot's flight time. Iterated twice, because the flight time depends on
## the distance to the lead point, which depends on the flight time. `speed` 0 — a hitscan weapon,
## or a homing spell that does its own chasing — aims straight at it. `_lead_frac` is what turns
## an exact solution back into a human one.
func _lead_point(aim_pos: Vector3, speed: float) -> Vector3:
	if speed <= 0.0 or aim_pos == Vector3.INF or _lead_vel == Vector3.ZERO:
		return aim_pos
	var from := _eye()
	var lead := aim_pos
	for _i in 2:
		var t := minf(from.distance_to(lead) / speed, LEAD_MAX_T)
		lead = aim_pos + _lead_vel * t * _lead_frac
	return lead


## Nearest living enemy at any range/LOS — the fallback "go chase someone" destination.
func _nearest_enemy() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	var origin := _bot.global_position
	for p in _bot.get_tree().get_nodes_in_group("damageable"):
		if p == _bot:
			continue
		# Before the property lookups below, which cost more than the group check. A bird carries
		# its caster's team, so without this a bot walks the map after one.
		if p.is_in_group("unhunted"):
			continue
		if p.get("is_dead") or p.get("team") == GameConsts.Team.NONE:
			continue
		if Teams.nodes_friendly(_bot, p):
			continue
		var d: float = origin.distance_squared_to(p.global_position)
		if d < best_d:
			best_d = d
			best = p
	return best


## Pick the weapon slot to engage a target at `dist`: the affordable, combat-enabled weapon
## (bot_range > 0) whose range best fits — the shortest range that still reaches, else the
## longest available. Falls back to slot 0 (the melee staff) when nothing ranged is usable.
func _choose_weapon(dist: float) -> int:
	var fit_idx := -1
	var fit_range := INF       # shortest bot_range that still reaches dist
	var reach_idx := -1
	var reach_range := 0.0     # longest bot_range, if nothing reaches dist
	for i in _bot.weapons.size():
		var w: Weapon = _bot.weapons[i]
		if w == null or w.bot_range <= 0.0:
			continue
		if w.mana_cost > 0.0 and _bot.mana < w.mana_cost:
			continue
		if w.bot_range > reach_range:
			reach_range = w.bot_range
			reach_idx = i
		if w.bot_range >= dist and w.bot_range < fit_range:
			fit_range = w.bot_range
			fit_idx = i
	if fit_idx >= 0:
		return fit_idx
	if reach_idx >= 0:
		return reach_idx
	return 0  # no ranged weapon available/affordable → the melee staff


## Stop the weapon we're holding, on our own puppet and on every observer. broadcast_stop_attack
## decides whether the event is worth sending — a sustained weapon's observers clear from the
## snapshot's PLAYER_FLAG_FIRING and drop it.
func _release_trigger() -> void:
	var w := _firing_weapon
	_firing_weapon = null
	_firing_hold = 0.0
	if w == null:
		return
	w.stop_firing(_bot)
	if NetworkManager.is_online():
		NetworkManager.broadcast_stop_attack(_bot.peer_id, w)


## Fire the active weapon along the bot's current look direction. Host is authority, so
## weapon.fire() applies damage directly; sync_attack replays the visuals on connected clients.
## Mirrors ServerRequests.attack. Aiming imperfection lives in _face_yaw/pitch
## (rate-limited + wobbling), so firing where we look is what makes bots miss naturally.
func _fire_at(_target: Node3D) -> void:
	if _bot.weapons.is_empty():
		return
	var idx: int = _bot.current_weapon_idx
	if idx < 0 or idx >= _bot.weapons.size():
		return
	var w: Weapon = _bot.weapons[idx]
	if w == null:
		return
	var aim_dir := _look_dir()
	if w.mana_cost > 0.0 and _bot.mana < w.mana_cost:
		return
	if not w.can_fire(_bot, aim_dir):
		return
	if not w.fire(_bot, Vector3.INF, aim_dir, 0.0, false):
		return
	if w.mana_cost > 0.0:
		_bot.mana = maxf(_bot.mana - w.mana_cost, 0.0)
	# Jitter the cadence so fire isn't metronomic; sloppier bots are streakier.
	_fire_cooldown = maxf(w.cooldown, 0.25) * randf_range(0.9, lerpf(1.6, 1.1, _skill))
	# The trigger is now held by this weapon. The hold outlives the jittered cadence above (whose
	# top multiplier is 1.6) so an ordinary gap between shots never reads as a release.
	_firing_weapon = w
	_firing_hold = _fire_cooldown * 2.0
	if NetworkManager.is_online():
		# Unreliable + PVS-filtered: only clients that can see this bot get the fire
		# visual. Matches ServerRequests.attack, which broadcasts every fire.
		NetworkManager.broadcast_attack(_bot.peer_id, idx, aim_dir, false)
