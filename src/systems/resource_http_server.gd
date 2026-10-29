extends RefCounted
## Minimal single-threaded HTTP file server running on a background GDScript
## Thread.  Supports multiple URL-prefix → directory mounts so one server can
## serve both game resources and client downloads (launcher, executable, etc.).
##
## Handles multiple connections concurrently — each accepted connection is
## served on its own Thread so parallel client downloads don't serialize.
##
## Usage:
##   var srv = ResourceHttpServer.new()
##   srv.add_mount("/resources", "/abs/path/to/resources")
##   srv.add_mount("/", "/abs/path/to/downloads")
##   srv.start(9052)
##
## Also serves STATUS_PATH from a JSON string the main thread refreshes with
## set_status() — a server browser (or Home Assistant) can poll it over HTTP.

const READ_TIMEOUT_MS := 500
const MAX_PATH_LEN    := 1024
const STATUS_PATH     := "/status.json"

# Array of {prefix, dir} dicts, sorted longest-prefix-first so the most
# specific mount wins.  Frozen before start() — never written after that.
var _mounts: Array[Dictionary] = []
var _mounts_mutex := Mutex.new()

# Live server status, published by the main thread and read by connection threads.
var _status_json := "{}"
var _status_mutex := Mutex.new()

var _tcp    := TCPServer.new()
var _thread := Thread.new()
var _conn_threads: Array[Thread] = []
var _conn_mutex  := Mutex.new()
var _running := false


func add_mount(url_prefix: String, abs_dir: String) -> void:
	_mounts_mutex.lock()
	_mounts.append({"prefix": url_prefix.trim_suffix("/"), "dir": abs_dir.trim_suffix("/")})
	_mounts.sort_custom(func(a, b): return a.prefix.length() > b.prefix.length())
	_mounts_mutex.unlock()


## Publish the JSON served at STATUS_PATH. Callable from the main thread at any time.
func set_status(json: String) -> void:
	_status_mutex.lock()
	_status_json = json
	_status_mutex.unlock()


func start(port: int) -> Error:
	if _mounts.is_empty():
		push_warning("ResourceHttpServer: no mounts configured")
		return ERR_UNCONFIGURED
	var err := _tcp.listen(port)
	if err != OK:
		return err
	_running = true
	_thread.start(_serve)
	return OK


func stop() -> void:
	_running = false
	_tcp.stop()
	if _thread.is_started():
		_thread.wait_to_finish()
	# Serve thread is done; snapshot and clear the thread list under the mutex,
	# then join each connection thread outside the lock so _handle can still run.
	_conn_mutex.lock()
	var pending := _conn_threads.duplicate()
	_conn_threads.clear()
	_conn_mutex.unlock()
	for t in pending:
		if t.is_started():
			t.wait_to_finish()


func _serve() -> void:
	while _running:
		if _tcp.is_connection_available():
			var peer := _tcp.take_connection()
			var t := Thread.new()
			_conn_mutex.lock()
			_conn_threads.append(t)
			_conn_mutex.unlock()
			t.start(_handle.bind(peer))
		else:
			OS.delay_msec(2)


func _handle(peer: StreamPeerTCP) -> void:
	peer.set_no_delay(true)

	# Accumulate bytes until we see the blank line ending the headers.
	var raw := PackedByteArray()
	var deadline := Time.get_ticks_msec() + READ_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		var avail := peer.get_available_bytes()
		if avail > 0:
			var res := peer.get_data(avail)
			if res[0] == OK:
				raw.append_array(res[1])
			if _has_header_end(raw):
				break
		else:
			OS.delay_msec(1)

	if raw.is_empty():
		peer.disconnect_from_host()
		return

	var first_line := raw.get_string_from_utf8().split("\r\n")[0]
	var parts := first_line.split(" ")
	if parts.size() < 2 or parts[0] != "GET":
		_respond(peer, 405, PackedByteArray())
		peer.disconnect_from_host()
		return

	var raw_path: String = parts[1]
	if raw_path.length() > MAX_PATH_LEN:
		_respond(peer, 414, PackedByteArray())
		peer.disconnect_from_host()
		return

	# Strip query string, decode percent-encoding.
	var path: String = raw_path.split("?")[0].uri_decode()

	if path == STATUS_PATH:
		_status_mutex.lock()
		var status := _status_json
		_status_mutex.unlock()
		_respond(peer, 200, status.to_utf8_buffer(), "application/json")
		peer.disconnect_from_host()
		return

	# Block path traversal in the URL before resolving — the mount root dir
	# may itself contain ".." (e.g. ../dist) and must not be flagged.
	if ".." in path:
		_respond(peer, 403, PackedByteArray())
		peer.disconnect_from_host()
		return

	# Find the longest matching mount prefix.
	var resolved := _resolve(path)
	if resolved.is_empty():
		_respond(peer, 404, PackedByteArray())
		peer.disconnect_from_host()
		return

	if not FileAccess.file_exists(resolved):
		_respond(peer, 404, PackedByteArray())
		peer.disconnect_from_host()
		return

	var body := FileAccess.get_file_as_bytes(resolved)
	_respond(peer, 200, body)
	peer.disconnect_from_host()


func _resolve(url_path: String) -> String:
	_mounts_mutex.lock()
	var mounts_snap := _mounts.duplicate()
	_mounts_mutex.unlock()
	for mount: Dictionary in mounts_snap:
		var prefix: String = mount.prefix
		if url_path == prefix or url_path.begins_with(prefix + "/"):
			var rel: String = url_path.substr(prefix.length()).lstrip("/")
			var full: String = mount.dir + "/" + rel if rel != "" else mount.dir
			return full
	return ""


func _respond(peer: StreamPeerTCP, code: int, body: PackedByteArray, content_type := "application/octet-stream") -> void:
	var status: String = {200: "OK", 403: "Forbidden", 404: "Not Found",
			405: "Method Not Allowed", 414: "URI Too Long"}.get(code, "Error")
	var header := "HTTP/1.1 %d %s\r\nContent-Length: %d\r\nContent-Type: %s\r\nConnection: close\r\n\r\n" \
			% [code, status, body.size(), content_type]
	peer.put_data(header.to_utf8_buffer())
	if body.size() > 0:
		peer.put_data(body)


func _has_header_end(data: PackedByteArray) -> bool:
	var n := data.size()
	for i in range(n - 3):
		if data[i] == 13 and data[i+1] == 10 and data[i+2] == 13 and data[i+3] == 10:
			return true
	return false
