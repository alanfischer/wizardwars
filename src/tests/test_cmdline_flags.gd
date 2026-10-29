extends "res://src/tests/test_base.gd"
## Pins main.gd's command-line flag table and the walk over it.
##
## The table replaced a 120-line elif chain whose failure mode was silence: a flag typed without
## its value, or misspelled entirely, was a no-op. A dedicated server has no console, so it came
## up misconfigured with nothing in the log. These cover both diagnostics and the arity of every
## flag, since an arity typo is the new way to go quietly wrong — it eats the NEXT argument.

const MainScript = preload("res://src/main.gd")

## flag -> argument count. Exact: a flag added or removed without updating this fails, which is the
## point — run.sh, the launcher scripts and the renderer relaunch all type these by hand.
const EXPECTED_ARITY := {
	"--server": 0, "--host": 0,
	"--auto-walk": 0, "--auto-walk-turn": 1, "--auto-fire": 0, "--auto-fire-slot": 1,
	"--perf-log": 1, "--perf-quit": 1,
	"--bsp-hulls": 1, "--log-tag": 1, "--bake-waypoints": 0,
	"--map": 1, "--connect": 1, "--team": 1, "--class": 1, "--name": 1,
	"--cl-updaterate": 1, "--sv-updaterate": 1, "--interp-diag": 0, "--view-diag": 0, "--nudge-players": 1, "--rate": 1, "--cl-cmdrate": 1, "--net-profile": 1,
	"--bots": 1, "--botskill": 1, "--mapcycle": 1,
	"--timelimit": 1, "--scorelimit": 1, "--fraglimit": 1,
	"--http-downloads-dir": 1, "--http-base-url": 1, "--admin-password": 1,
	"--renderer-applied": 0, "--goldnet": 0, "--stock": 0,
}


## A bare instance is enough: _flag_handlers only builds lambdas, and nothing in it reads a child
## or the tree. The node is never added, so the autoload-touching handlers stay unfired unless a
## test picks them.
func _new_main() -> Node:
	return _keep(MainScript.new())


func test_table_matches_declared_arity() -> void:
	var handlers: Dictionary = _new_main()._flag_handlers()
	var got := handlers.keys()
	got.sort()
	var want := EXPECTED_ARITY.keys()
	want.sort()
	assert_eq(got, want, "flag set")
	for flag in EXPECTED_ARITY:
		if not handlers.has(flag):
			continue
		var handler: Callable = handlers[flag]
		assert_eq(handler.get_argument_count(), EXPECTED_ARITY[flag], "arity of %s" % flag)


func test_values_consumed_switches_are_not() -> void:
	var seen: Array = []
	var handlers := {
		"--switch": func() -> void: seen.append("switch"),
		"--valued": func(v: String) -> void: seen.append(v),
	}
	var problems := MainScript.apply_flags(
			PackedStringArray(["--switch", "--valued", "one", "--valued", "two"]), handlers)
	assert_eq(problems.size(), 0, "clean line")
	assert_eq(seen, ["switch", "one", "two"], "handlers fired in order, repeats allowed")


func test_flag_shaped_value_is_taken_verbatim() -> void:
	# --name and --admin-password may legitimately be anything, so the walk cannot second-guess a
	# value that starts with "--". `--map --bots` names a map "--bots".
	var seen: Array = []
	var handlers := {
		"--switch": func() -> void: seen.append("switch"),
		"--valued": func(v: String) -> void: seen.append(v),
	}
	MainScript.apply_flags(PackedStringArray(["--valued", "--switch"]), handlers)
	assert_eq(seen, ["--switch"], "consumed as a value, not run as a flag")


func test_missing_value_is_reported() -> void:
	var fired := [false]
	var handlers := {"--valued": func(_v: String) -> void: fired[0] = true}
	var problems := MainScript.apply_flags(PackedStringArray(["--valued"]), handlers)
	assert_eq(problems.size(), 1, "one problem")
	assert_true(problems[0].contains("--valued"), "names the flag: %s" % problems[0])
	assert_false(fired[0], "handler not called without its value")


func test_one_bad_token_does_not_void_the_line() -> void:
	var switched := [false]
	var handlers := {
		"--switch": func() -> void: switched[0] = true,
		"--valued": func(_v: String) -> void: pass,
	}
	var problems := MainScript.apply_flags(PackedStringArray(["--switch", "--valued"]), handlers)
	assert_eq(problems.size(), 1, "just the one problem")
	assert_true(switched[0], "the flag before it applied")


func test_unknown_flag_is_reported() -> void:
	var fired := [false]
	var handlers := {"--map": func(_v: String) -> void: fired[0] = true}
	# A typo'd flag is skipped as a single token, so its value is then read as a flag too — both
	# are reported, and the valid flag after them still lands.
	var problems := MainScript.apply_flags(
			PackedStringArray(["--mpa", "ww_hunt", "--map", "ww_2fort"]), handlers)
	assert_eq(problems.size(), 2, "the typo and its orphaned value")
	assert_true(problems[0].contains("--mpa"), "names the typo: %s" % problems[0])
	assert_true(fired[0], "the valid flag after it still applied")


func test_empty_line_is_clean() -> void:
	assert_eq(MainScript.apply_flags(PackedStringArray([]), {}).size(), 0, "nothing to report")


func test_real_handlers_write_their_fields() -> void:
	# Only the handlers that write main's own fields — the ones reaching NetworkManager/MatchSystem
	# would mutate autoloads the rest of the suite shares.
	var m := _new_main()
	var handlers: Dictionary = m._flag_handlers()
	var subset := {}
	for flag in ["--server", "--host", "--map", "--team", "--class", "--bots", "--bsp-hulls",
			"--stock", "--auto-fire-slot", "--timelimit"]:
		subset[flag] = handlers[flag]
	var problems := MainScript.apply_flags(PackedStringArray([
			"--server", "--host", "--map", "ww_hunt", "--team", "2", "--class", "ice",
			"--bots", "4", "--bsp-hulls", " ON ", "--stock", "--auto-fire-slot", "3",
			"--timelimit", " 15 "]), subset)
	assert_eq(problems.size(), 0, "clean line")
	assert_true(m._is_dedicated_server, "--server")
	assert_true(m._is_listen_host, "--host")
	assert_eq(m._current_map_name, "ww_hunt", "--map")
	assert_eq(m._auto_team, 2, "--team")
	assert_eq(m._auto_class, GameConsts.element_from_name("ice"), "--class resolves a name")
	assert_eq(m._auto_bots, 4, "--bots")
	assert_eq(m._bsp_hulls_arg, "on", "--bsp-hulls trimmed and lowercased")
	assert_false(m._use_goldnet, "--stock opts out of the default transport")
	assert_eq(m._auto_fire_slot, 3, "--auto-fire-slot")
	assert_eq(m._limit_args.get("timelimit"), "15", "--timelimit trimmed into _limit_args")
