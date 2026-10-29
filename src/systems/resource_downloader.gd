extends Node
## Downloads a list of resource files from an HTTP server in parallel.

signal progress(done: int, total: int)
signal all_complete()

const MAX_CONCURRENT := 4

var _base_url: String
var _dest_dir: String
var _pending: Array[String] = []
var _active: int = 0
var _done: int = 0
var _total: int = 0


func start(base_url: String, rel_paths: Array[String], dest_dir: String) -> void:
	_base_url = base_url.trim_suffix("/")
	_dest_dir = dest_dir.trim_suffix("/")
	_pending = rel_paths.duplicate()
	_total = rel_paths.size()
	_done = 0
	_active = 0
	_pump()


func _pump() -> void:
	while _active < MAX_CONCURRENT and not _pending.is_empty():
		_fetch_one(_pending.pop_front())
	if _active == 0 and _pending.is_empty():
		all_complete.emit()


func _fetch_one(rel_path: String) -> void:
	_active += 1
	var req := HTTPRequest.new()
	add_child(req)
	req.use_threads = true
	req.request_completed.connect(_on_file_done.bind(req, rel_path))
	# GoldSrc decal names carry '{' and '#'; a raw '#' would cut the URL off as a fragment.
	var url := "%s/%s" % [_base_url, "/".join(Array(rel_path.split("/")).map(
			func(part: String) -> String: return part.uri_encode()))]
	var err := req.request(url)
	if err != OK:
		push_warning("ResourceDownloader: request failed for %s (%s)" % [rel_path, error_string(err)])
		req.queue_free()
		_active -= 1
		_done += 1
		progress.emit(_done, _total)
		_pump()


func _on_file_done(
		result: int,
		response_code: int,
		_headers: PackedStringArray,
		body: PackedByteArray,
		req: HTTPRequest,
		rel_path: String) -> void:
	req.queue_free()
	_active -= 1
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
		var full_path := "%s/%s" % [_dest_dir, rel_path]
		DirAccess.make_dir_recursive_absolute(full_path.get_base_dir())
		var f := FileAccess.open(full_path, FileAccess.WRITE)
		if f:
			f.store_buffer(body)
			f.close()
	else:
		push_warning("ResourceDownloader: failed %s (result=%d, http=%d)" % [rel_path, result, response_code])
	_done += 1
	progress.emit(_done, _total)
	_pump()
