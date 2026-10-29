extends Node
## The things main.gd builds that the rest of the game has to reach, in one typed place.
##
## Null is the ordinary answer — lobby, test runner, dedicated server — so callers check. main.gd
## holds these as properties backed by this node rather than fields of its own, so there is only
## ever one copy: client_sync drives 56 call sites off local_player, and a stale second copy would
## land healing and damage on a freed player.
##
## Not the place for "the world node to parent an effect into". That is current_scene, legitimately.

var hud: HUD = null
## The predicted first-person view of the player at this keyboard, not their server puppet — that
## is a RemotePlayer like anyone else's.
var local_player: LocalPlayer = null
var decal_system: DecalSystem = null
var weather_system: WeatherSystem = null

## True once a map is up and gameplay is running; false in the lobby and during a map change.
var game_active := false
var current_map_name := ""


## Map unload. The two flags belong to the load path, not here: game_active is false for the whole
## changeover, and current_map_name is overwritten by the incoming map rather than blanked between.
func clear_world() -> void:
	hud = null
	local_player = null
	decal_system = null
	weather_system = null


## Rattle this peer's own view, for something it already spawned for itself (a comet's impact)
## and so has nothing to broadcast. Picks the same way the server does for everyone else
## (NetworkManager.shakes), then goes through LocalPlayer.shake_view like the RPC does — it owns
## the GoldSrc amplitude scale, the VR opt-out, and the one tween allowed to be moving the camera.
func shake_view_local(origin: Vector3, amplitude: float, radius: float,
		duration: float, frequency: float) -> void:
	if local_player and NetworkManager.shakes(local_player.global_position,
			local_player.is_on_floor(), origin, radius):
		local_player.shake_view(amplitude, duration, frequency)
