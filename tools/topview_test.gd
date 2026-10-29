extends Node
## Throwaway: boot the real game with bots and film it from above.
##   REC_SECONDS=40 godot --path . res://tools/topview_test.tscn -- --server --map ww_storm
const Top = preload("res://src/systems/top_view_recorder.gd")
const Rec = preload("res://src/systems/match_recorder.gd")
func _ready() -> void: _run.call_deferred()
func _carried() -> Array:
	var out: Array = []
	for g in GoalSystem.get_carriable_flags():
		out.append(int(g._carrier_peer_id))
	return out


func _run() -> void:
	var tree := get_tree()
	var main = load("res://src/main.tscn").instantiate()
	tree.root.add_child(main); tree.current_scene = main
	var w := 0.0
	while w < 240.0 and not bool(main.get("_game_active")):
		await tree.create_timer(1.0).timeout; w += 1.0
	# Fixed per-team counts, so an asymmetric fight can be set up: REC_T1=2 REC_T2=4.
	var t1 := 3
	var t2 := 3
	if not OS.get_environment("REC_T1").is_empty(): t1 = int(OS.get_environment("REC_T1"))
	if not OS.get_environment("REC_T2").is_empty(): t2 = int(OS.get_environment("REC_T2"))
	for _i in t1:
		if BotSystem.add_bot(-1, 1) == 0: break
	for _i in t2:
		if BotSystem.add_bot(-1, 2) == 0: break
	var n1 := 0
	var n2 := 0
	for b in BotSystem._bots:
		if b.team == 1: n1 += 1
		elif b.team == 2: n2 += 1
	print("[TopTest] teams: %d vs %d" % [n1, n2])
	var secs := 40.0
	if not OS.get_environment("REC_SECONDS").is_empty():
		secs = float(OS.get_environment("REC_SECONDS"))
	var r = Rec.new(); r.name = "MatchRecorder"; main.add_child(r)
	print("[TopTest] csv ", ProjectSettings.globalize_path(r.start(String(main.get("_current_map_name")), secs)))
	var t = Top.new(); t.name = "TopViewRecorder"; main.add_child(t)
	var out: String = t.start(String(main.get("_current_map_name")), secs)
	print("[TopTest] ", ProjectSettings.globalize_path(out))
	# Report the score as it goes — the question is whether anyone actually caps.
	var left := secs
	while left > 0.0:
		await tree.create_timer(15.0).timeout
		left -= 15.0
		print("[TopTest] t=%4.0fs scores=%s carried=%s" % [
			secs - left, str(GoalSystem.team_scores), str(_carried())])
	await tree.create_timer(4.0).timeout
	print("[TopTest] frames=", t.frames())
	t.stop(); r.stop()
	tree.quit()
