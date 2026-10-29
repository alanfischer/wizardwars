extends Node
## Does a PLAYER ever reach the pose MonsterBody._check_stuck exists for?
##
##   godot --headless --path . res://src/tests/player_pin_probe.tscn -- --server --map ww_2fort
##
## Monsters meet it 150-240 times per 90 s even with hop holding bodies clear of the band, so the
## band is still reachable by ordinary sliding and "a player never lands in it" is an assumption.
## Bots are the instrument: a bot is a host-side RemotePlayer puppet running the same pmove kernel,
## the same PlayerMovementContext and the same 32x32x72 hull a human drives, so what pins one pins
## a player.
##
## What a bot has that a human does not is BotBrain's WEDGE_T rescue — 12 s of not moving at all
## and BotSystem returns it to spawn. So the number that matters is not how long a pin lasts here,
## it is whether a pin happens at all: a human in the same pose has nothing to end it.
##
## PIN_SECONDS=<n> (default 180) and PIN_BOTS=<n> (default 8).
##
## Read the durations with one caveat: dying ends an episode here, and bots die constantly, so a
## reported length is a lower bound on how long that pose would have held an idle player. The
## count and the absence of long episodes are the trustworthy halves.

const Movement = preload("res://addons/pmove/movement.gd")

const SAMPLE := 0.25
const BOT_RESCUE_T := 12.0      # BotBrain.WEDGE_T, for reporting what a human would NOT get

## One adapter per bot, kept because GodotBody pools its query params — and because asking
## Movement.is_pinned is the point: the probe has to measure the predicate the game acts on, not
## a second copy of it that can drift.
var _bodies := {}
var _pinned := {}               # instance id -> {since, at}
var _episodes: Array = []       # {name, at, seconds}


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var tree := get_tree()
	var main: Node = load("res://src/main.tscn").instantiate()
	tree.root.add_child(main)
	tree.current_scene = main
	var waited := 0.0
	while waited < 240.0 and not bool(main.get("_game_active")):
		await tree.create_timer(1.0).timeout
		waited += 1.0
	var map_name := str(main.get("_current_map_name"))
	if not bool(main.get("_game_active")):
		print("PIN %-16s FAIL  map never loaded" % map_name)
		tree.quit(1)
		return

	var want := int(OS.get_environment("PIN_BOTS")) if OS.has_environment("PIN_BOTS") else 8
	var seconds := float(OS.get_environment("PIN_SECONDS")) if OS.has_environment("PIN_SECONDS") else 180.0
	while BotSystem._bots.size() < want:
		if BotSystem.add_bot() == 0:
			break
	print("PIN %-16s %d bot(s), %.0fs" % [map_name, BotSystem._bots.size(), seconds])

	var t := 0.0
	while t < seconds:
		await tree.create_timer(SAMPLE).timeout
		t += SAMPLE
		for bot in BotSystem._bots:
			if not is_instance_valid(bot) or bool(bot.get("is_dead")):
				_close(bot, t)
				continue
			if _is_live(bot):
				_close(bot, t)
			elif not _pinned.has(bot.get_instance_id()):
				_pinned[bot.get_instance_id()] = {"since": t, "at": bot.global_position,
						"name": str(bot.name)}
	for bot in BotSystem._bots:
		_close(bot, t)

	var total := 0.0
	var longest := 0.0
	var human_stuck := 0
	for e in _episodes:
		total += float(e["seconds"])
		longest = maxf(longest, float(e["seconds"]))
		if float(e["seconds"]) >= BOT_RESCUE_T:
			human_stuck += 1
	print("PIN %-16s done  episodes %d  pinned-seconds %.1f  longest %.1fs  past-bot-rescue %d"
			% [map_name, _episodes.size(), total, longest, human_stuck])
	for e in _episodes:
		print("    pin %-18s %6.2f,%6.2f,%6.2f  for %.2fs  (t=%.0fs)" % [e["name"],
				e["at"].x, e["at"].y, e["at"].z, e["seconds"], e["start"]])
	tree.quit(0)


## Close an open pin episode for `bot`, if it has one.
func _close(bot, t: float) -> void:
	if not is_instance_valid(bot):
		return
	var id: int = bot.get_instance_id()
	if not _pinned.has(id):
		return
	var rec: Dictionary = _pinned[id]
	_episodes.append({"name": rec["name"], "at": rec["at"], "start": rec["since"],
			"seconds": t - float(rec["since"])})
	_pinned.erase(id)


## Pinned, by the game's own definition — Movement.is_pinned over the body's adapter.
func _is_live(body: CharacterBody3D) -> bool:
	var id: int = body.get_instance_id()
	if not _bodies.has(id):
		_bodies[id] = GodotBody.new(body)
	return not Movement.is_pinned(_bodies[id])
