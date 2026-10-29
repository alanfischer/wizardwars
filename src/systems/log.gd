extends Node

enum Level { DEBUG, INFO, WARN, ERROR }
var level: Level = Level.INFO
var _file: FileAccess
var _file_path := ""
var _disabled_tags: Dictionary = { "tfgoal": true }


func enable_file_logging(filename: String = "server.log") -> void:
	var path := "user://%s" % filename
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file:
		_file_path = path
		print("Logging to: %s" % ProjectSettings.globalize_path(path))


func is_file_logging() -> bool:
	return _file != null


## Absolute path of the open log file, for telling a player which file to send. "" when the
## session is logging to stdout only — which a listen host does, since neither the dedicated-server
## nor the join path ran.
func get_file_path() -> String:
	return ProjectSettings.globalize_path(_file_path) if _file else ""


func enable_tag(tag: String) -> void:
	_disabled_tags.erase(tag)


func debug(msg: String, tag: String = "") -> void:
	if tag != "" and _disabled_tags.has(tag):
		return
	if level <= Level.DEBUG:
		var line := ("[%s] %s" % [tag, msg]) if tag != "" else msg
		print(line)
		_write(line)


func info(msg: String, tag: String = "") -> void:
	if tag != "" and _disabled_tags.has(tag):
		return
	if level <= Level.INFO:
		var line := ("[%s] %s" % [tag, msg]) if tag != "" else msg
		print(line)
		_write(line)


func warn(msg: String, tag: String = "") -> void:
	if tag != "" and _disabled_tags.has(tag):
		return
	if level <= Level.WARN:
		var line := ("[%s] %s" % [tag, msg]) if tag != "" else msg
		push_warning(line)
		_write("WARN: " + line)


func _write(msg: String) -> void:
	if _file:
		_file.store_line(msg)
		_file.flush()
