extends Node
## Throwaway demo: skeletons march out of one base and attack the wizards holding the other,
## filmed from above through the real render.
##
##   godot --path . res://src/tests/siege_demo.tscn -- --host --map ww_2fort --team 1 --class 0
##   tools/match_gif.py --frames <dir printed at the end> --out /tmp/demo.mp4
##
## NOT --headless: TopViewRecorder is a second camera on the live scene, so there has to be
## something rendering. A window opens; it does not need focus.
##
## Env: DEMO_SECONDS (default 60), DEMO_BOTS (6, the defenders), DEMO_SKELETONS (10, the attackers),
##      DEMO_WAVE (12, seconds between waves of attackers).

const TopViewRecorder = preload("res://src/systems/top_view_recorder.gd")

const DEFENDER_TEAM := GameConsts.Team.BLUE
const ATTACKER_TEAM := GameConsts.Team.RED

## Marker log, in MatchRecorder's own column order so tools/match_gif.py can overlay it on the
## frames. Its own rather than /record's because /record logs players and bots only — the
## attacking skeletons are the whole subject here, and at 6 px/m a skeleton is five pixels.
const CSV_HZ := 10.0

var _main: Node
var _rec: Node
var _csv: FileAccess
var _csv_path := ""
var _clock := 0.0
var _next_sample := 0.0
var _attackers: Array = []
var _goal := Vector3.INF   # where the attackers are headed: the defenders' own spawn
var _seconds := 60.0
var _bots := 6
var _skeletons := 10
var _wave := 12.0
var _spawned := 0


func _ready() -> void:
	_seconds = float(OS.get_environment("DEMO_SECONDS")) if OS.has_environment("DEMO_SECONDS") else 60.0
	_bots = int(OS.get_environment("DEMO_BOTS")) if OS.has_environment("DEMO_BOTS") else 6
	_skeletons = int(OS.get_environment("DEMO_SKELETONS")) if OS.has_environment("DEMO_SKELETONS") else 10
	_wave = float(OS.get_environment("DEMO_WAVE")) if OS.has_environment("DEMO_WAVE") else 12.0
	_run.call_deferred()


func _run() -> void:
	var tree := get_tree()
	_main = load("res://src/main.tscn").instantiate()
	tree.root.add_child(_main)
	tree.current_scene = _main

	var waited := 0.0
	while waited < 240.0 and not bool(_main.get("_game_active")):
		await tree.create_timer(1.0).timeout
		waited += 1.0
	if not bool(_main.get("_game_active")):
		print("[Demo] game never became active")
		tree.quit(1)
		return

	# The defenders. All on one team so every skeleton reads every wizard as an enemy.
	while BotSystem._bots.size() < _bots:
		if BotSystem.add_bot(-1, DEFENDER_TEAM) == 0:
			break
	print("[Demo] %d defender(s) on %s" % [BotSystem._bots.size(),
			GoalSystem.get_team_name(DEFENDER_TEAM)])

	_rec = TopViewRecorder.new()
	_rec.name = "TopViewRecorder"
	_main.add_child(_rec)
	var dir: String = _rec.start(str(_main.get("_current_map_name")), _seconds + 2.0)
	if dir.is_empty():
		print("[Demo] recorder refused to start (no renderer?)")
		tree.quit(1)
		return

	# Same origin as the recorder's times.csv — the compositor interpolates markers to frame
	# timestamps, so the two clocks have to start together.
	_csv_path = dir + "/markers.csv"
	_csv = FileAccess.open(_csv_path, FileAccess.WRITE)
	_csv.store_line("# map=%s hz=%.1f" % [_main.get("_current_map_name"), CSV_HZ])
	_csv.store_line("t,id,name,team,x,y,z,yaw,alive,carrying,state,tx,tz,element")
	set_process(true)

	# The thing they are attacking: the defenders' base.
	var home := SpawnSystem.get_spawn_for_team(DEFENDER_TEAM)
	if home == null:
		print("[Demo] no spawn point for the defending team")
		tree.quit(1)
		return
	_goal = home.get_spawn_position()
	print("[Demo] attackers headed for %.0f,%.0f,%.0f" % [_goal.x, _goal.y, _goal.z])

	_send_wave()
	var t := 0.0
	while t < _seconds:
		await tree.create_timer(1.0).timeout
		t += 1.0
		if fmod(t, _wave) < 0.5:
			_send_wave()

	set_process(false)
	_rec.stop()
	if _csv != null:
		_csv.close()
	print("[Demo] %d frames -> %s" % [_rec.frames(), ProjectSettings.globalize_path(dir)])
	print("[Demo] markers -> %s" % ProjectSettings.globalize_path(_csv_path))
	tree.quit(0)


func _process(delta: float) -> void:
	_clock += delta
	if _clock < _next_sample or _csv == null:
		return
	_next_sample = _clock + 1.0 / CSV_HZ
	for bot in BotSystem._bots:
		if is_instance_valid(bot):
			_row(bot, int(bot.get("peer_id")), "wizard", DEFENDER_TEAM, "player")
	for i in range(_attackers.size() - 1, -1, -1):
		var s = _attackers[i]
		if not is_instance_valid(s):
			_attackers.remove_at(i)
			continue
		_row(s, 100000 + s.get_instance_id() % 100000, "skeleton", ATTACKER_TEAM, "fighting")


func _row(node: Node3D, id: int, label: String, team: int, state: String) -> void:
	var p: Vector3 = node.global_position
	var alive := 0 if node.get("is_dead") else 1
	_csv.store_line("%.2f,%d,%s,%d,%.2f,%.2f,%.2f,%.3f,%d,0,%s,0,0,-1"
			% [_clock, id, label, team, p.x, p.y, p.z, node.rotation.y, alive, state])


## A wave out of the attackers' base. Spread around the spawn point rather than stacked on it:
## they are solid to the world, and a pile all pathing the same way looks like one skeleton.
func _send_wave() -> void:
	var sp := SpawnSystem.get_spawn_for_team(ATTACKER_TEAM)
	if sp == null:
		print("[Demo] no spawn point for the attacking team")
		return
	var origin: Vector3 = sp.get_spawn_position()
	for i in _skeletons:
		var angle := TAU * float(i) / float(_skeletons)
		var ring := 1.0 + 2.0 * randf()
		var s := NetworkManager.spawn_dynamic_entity({
			"script_path": "res://src/monsters/skeleton.gd",
			"position": origin + Vector3(sin(angle) * ring, 0.3, cos(angle) * ring),
			"team": ATTACKER_TEAM,
		})
		if s != null:
			# What a siege will set to the altar. Without it a skeleton holds its ground until
			# something walks into its 25.6 m of sight, which is correct for a summon and no use
			# to an attacker.
			s.objective = _goal
			_attackers.append(s)
	_spawned += _skeletons
	print("[Demo] wave away — %d skeletons total" % _spawned)
