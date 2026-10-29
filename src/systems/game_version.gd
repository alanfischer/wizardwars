extends Object
## What build this is. Two halves, from two places:
##
##   semver()   "1.0.0"     — application/config/version in project.godot, the number we bump
##                            by hand for a release. Also what the export presets stamp into the
##                            Windows .exe and the Android manifest, so keep those in step.
##   build_id() "1ae53e54"  — the commit build.sh exported from, written to res://build_id.txt at
##                            export time. Empty when running from source or from the editor.
##
## Together they answer "what exactly is this player running", which a bug report needs and a
## <git-sha>-<timestamp> in the launcher's own version.txt cannot give us once the game is open.
##
## No class_name — preloaded by its consumers; see README, "class_name and preload".

## Wire identity: the token the LAN beacon and /status.json tag themselves with, so a stray
## broadcast from another game on BEACON_PORT is ignored rather than listed as a server.
const GAME_ID := "WizardWars"

const VERSION_SETTING := "application/config/version"
const BUILD_ID_PATH := "res://build_id.txt"
const DEFAULT_SERVER_PATH := "res://default_server.txt"

const UNKNOWN_SEMVER := "0.0.0"
## What build_id() reports when there is no stamp — running from source, or from the editor.
const SOURCE_BUILD := "dev"


static func semver() -> String:
	var v := str(ProjectSettings.get_setting(VERSION_SETTING, UNKNOWN_SEMVER))
	return v if not v.is_empty() else UNKNOWN_SEMVER


## The commit this was exported from, or SOURCE_BUILD. build_id.txt is generated, never committed,
## so its absence is the normal case in a checkout and must not read as an error.
static func build_id() -> String:
	if not FileAccess.file_exists(BUILD_ID_PATH):
		return SOURCE_BUILD
	var f := FileAccess.open(BUILD_ID_PATH, FileAccess.READ)
	if f == null:
		return SOURCE_BUILD
	var id := f.get_as_text().strip_edges()
	return id if not id.is_empty() else SOURCE_BUILD


## The lobby's default join address, which build.sh stamps from release.env so the source never
## names the server. Empty when running from source or from a build with no host set.
static func default_server() -> String:
	if not FileAccess.file_exists(DEFAULT_SERVER_PATH):
		return ""
	var f := FileAccess.open(DEFAULT_SERVER_PATH, FileAccess.READ)
	return f.get_as_text().strip_edges() if f != null else ""


## The one string to put in front of a player: "1.0.0 (1ae53e54)".
static func display() -> String:
	return "%s (%s)" % [semver(), build_id()]
