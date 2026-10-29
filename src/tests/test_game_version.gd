extends "res://src/tests/test_base.gd"
## The build's identity. The semver has to come from project.godot rather than a literal in the
## script, and a checkout with no stamp has to report "dev" rather than an empty or broken string —
## running from source is the normal case, not an error.

const GameVersion = preload("res://src/systems/game_version.gd")


func test_semver_comes_from_project_settings() -> void:
	assert_eq(GameVersion.semver(),
		str(ProjectSettings.get_setting(GameVersion.VERSION_SETTING, "")),
		"semver() must read application/config/version, not a literal")


func test_semver_is_set_and_not_the_unknown_fallback() -> void:
	assert_ne(GameVersion.semver(), GameVersion.UNKNOWN_SEMVER,
		"application/config/version is unset in project.godot")
	assert_ne(GameVersion.semver(), "", "semver() must never be empty")


## An unstamped checkout is the normal case: build.sh writes build_id.txt, git never carries it.
func test_build_id_falls_back_to_dev_without_a_stamp() -> void:
	if FileAccess.file_exists(GameVersion.BUILD_ID_PATH):
		# A stamped build (someone ran build.sh in this tree) — then it must not be the fallback.
		assert_ne(GameVersion.build_id(), GameVersion.SOURCE_BUILD,
			"build_id.txt exists but read as unstamped")
		return
	assert_eq(GameVersion.build_id(), GameVersion.SOURCE_BUILD,
		"a checkout with no build_id.txt must report dev")


func test_display_carries_both_halves() -> void:
	var shown := GameVersion.display()
	assert_true(shown.contains(GameVersion.semver()), "display() dropped the semver: %s" % shown)
	assert_true(shown.contains(GameVersion.build_id()), "display() dropped the build id: %s" % shown)
