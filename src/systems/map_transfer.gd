extends Node
## Getting a joining client the map and resources it is missing, over HTTP.
##
## The host pre-converts every map to .scn before it is advertised, so the transfer only ever moves
## .scn files and a manifest of loose resources; nothing here converts anything. On join the host
## sends metadata (name, hash, its HTTP base URL) and the client decides for itself what to fetch:
## a matching .hash sidecar is a cache hit, anything else is a download. The file bytes never touch
## the replication wire — resource_http_server.gd serves them and resource_downloader.gd pulls them,
## and this is the half that was still living in NetworkManager.
##
## main.gd drives the host side (set_host_map + load_resource_manifest after each map load) and
## listens on the client side, activating the local player only once both map and resources land.
##
## No class_name — autoloaded as MapTransfer.

signal map_transfer_complete(map_name: String)
signal map_transfer_failed()
signal map_already_cached(map_name: String)
signal resources_transfer_progress(current: int, total: int)
signal resources_ready()

const HTTP_PORT := 8080  # resource/download HTTP server port
const CACHE_DIR := "user://resources/maps"  # converted .scn output + downloaded copies share this dir

# Host map metadata (no file bytes — the HTTP server serves the file directly).
# Both BSP and Blender maps are pre-converted to .scn on the host before this
# point, so the transfer pipeline only ever moves .scn files.
var host_map_name := ""
var _host_map_hash := ""

var _host_resource_manifest := ""  # JSON string of manifest.json
## The same, compressed for the wire: at 142 KB it is the biggest message a join sends, and it is
## mostly hashes and repeated keys, which zstd takes to about a quarter.
var _host_manifest_packed := PackedByteArray()
var _host_manifest_size := 0  # its uncompressed size, which decompress() needs
const MANIFEST_COMPRESSION := FileAccess.COMPRESSION_ZSTD

# Directory served at / (launcher scripts, client zips, version.txt). Override via --http-downloads-dir
# before calling NetworkManager.host(). Defaults to the dir containing the game binary.
var http_downloads_dir: String = OS.get_executable_path().get_base_dir()
# Public-facing HTTP base URL override (--http-base-url), sent to clients instead of the auto-detected
# local IP. Needed for VPS deployments where the server's IP is private (e.g. 10.x.x.x).
var http_base_url_override: String = ""

var _transfer_map_name := ""
var _transfer_hash := ""
var _transfer_map_url := ""
var _active_map_request: HTTPRequest = null
var _map_download_attempts := 0
const _MAP_DOWNLOAD_MAX_ATTEMPTS := 3

var _res_downloader: Node = null  # ResourceDownloader instance, client side

var _http_server: RefCounted = null
var _status_timer := 0.0
const STATUS_INTERVAL := 1.0  # how often the host refreshes /status.json


# --- Host side ---

func set_host_map(map_name: String, map_hash: String) -> void:
	host_map_name = map_name
	_host_map_hash = map_hash


func load_resource_manifest() -> void:
	var manifest_path := "%s/manifest.json" % AssetLoader.RESOURCE_DIR
	if FileAccess.file_exists(manifest_path):
		var f := FileAccess.open(manifest_path, FileAccess.READ)
		if f:
			_host_resource_manifest = f.get_as_text()
			f.close()
			Log.info("Loaded resource manifest (%d bytes)" % _host_resource_manifest.length())
	else:
		_host_resource_manifest = ""
		Log.warn("No resource manifest found at %s" % manifest_path)
	_pack_manifest()


## Host → one peer, on connect: what map we are running and where to fetch it from.
func send_to_peer(id: int) -> void:
	if host_map_name.is_empty():
		return
	var http_url := _get_http_base_url()
	Log.info("Sending HTTP URL to peer %d: %s" % [id, http_url])
	_send_map_info.rpc_id(id, host_map_name, _host_map_hash, http_url)
	# manifest always sent (empty = "{}") so client gets resources_ready
	_send_manifest_to(id, http_url)


## Re-send map info to all connected peers after a map change so they trigger the normal
## download/cache flow. NetworkManager.sync_map_change.rpc(), set_host_map(), and
## load_resource_manifest() must already have been called before this.
func notify_map_change() -> void:
	var http_url := _get_http_base_url()
	for id in multiplayer.get_peers():
		_send_map_info.rpc_id(id, host_map_name, _host_map_hash, http_url)
		_send_manifest_to(id, http_url)


func _manifest_json() -> String:
	return _host_resource_manifest if not _host_resource_manifest.is_empty() else "{}"


func _pack_manifest() -> void:
	var raw := _manifest_json().to_utf8_buffer()
	_host_manifest_size = raw.size()
	_host_manifest_packed = raw.compress(MANIFEST_COMPRESSION)


func _send_manifest_to(id: int, http_url: String) -> void:
	if _host_manifest_packed.is_empty():
		_pack_manifest()
	_send_resource_manifest.rpc_id(id, _host_manifest_packed, _host_manifest_size, http_url)


# --- HTTP server (host) ---

func start_http_server() -> void:
	var srv := preload("res://src/systems/resource_http_server.gd").new()
	var resource_dir := ProjectSettings.globalize_path(AssetLoader.RESOURCE_DIR)
	srv.add_mount("/resources", resource_dir)
	# BSP- and Blender-converted output plus any previously-downloaded copy share this dir, so a
	# former client can re-serve a map without reconverting.
	srv.add_mount("/maps", ProjectSettings.globalize_path(CACHE_DIR))
	srv.add_mount("/", http_downloads_dir)  # launcher scripts, client zips, version.txt
	var err := srv.start(HTTP_PORT)
	if err == OK:
		_http_server = srv
		Log.info("HTTP server on port %d  resources=%s  downloads=%s" % [
				HTTP_PORT, resource_dir, http_downloads_dir])
	else:
		push_warning("HTTP server failed to start: %s" % error_string(err))


func stop_http_server() -> void:
	if _http_server != null:
		_http_server.stop()
		_http_server = null


## Must stop the HTTP serve thread here, not later: on quit the GDScript VM frees bytecode out from
## under a still-running serve thread otherwise, crashing with "Internal script error! Opcode: 0".
func _exit_tree() -> void:
	stop_http_server()


## Refresh the JSON the HTTP server hands out at /status.json (host only). Built here on the main
## thread — the connection threads only ever read the finished string.
func _process(delta: float) -> void:
	if _http_server == null:
		return
	_status_timer += delta
	if _status_timer < STATUS_INTERVAL:
		return
	_status_timer = 0.0
	_http_server.set_status(JSON.stringify(NetworkManager.build_status()))


# --- Client side ---

## Leaving a session: drop any in-flight download and stop serving.
func reset() -> void:
	_transfer_map_name = ""
	if _active_map_request != null:
		_active_map_request.cancel_request()
		_active_map_request.queue_free()
		_active_map_request = null
	if _res_downloader != null:
		_res_downloader.queue_free()
		_res_downloader = null
	stop_http_server()


## Client checks its cache and downloads the .scn from /maps if the hash doesn't match.
@rpc("authority", "call_remote", "reliable")
func _send_map_info(map_name: String, map_hash: String, http_base_url: String) -> void:
	Log.info("Received map info: %s (hash=%s, url=%s)" % [map_name, map_hash, http_base_url])
	_transfer_map_name = map_name
	_transfer_hash = map_hash
	_map_download_attempts = 0

	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var hash_path := "%s/%s.hash" % [CACHE_DIR, map_name]
	if FileAccess.file_exists(hash_path):
		var f := FileAccess.open(hash_path, FileAccess.READ)
		var local_hash := f.get_as_text().strip_edges() if f != null else ""
		if f != null:
			f.close()
		if local_hash == map_hash:
			Log.info("Map cache hit for %s" % map_name)
			map_already_cached.emit(map_name)
			_map_cache_hit.rpc_id(1)
			return

	Log.info("Map cache miss for %s, downloading via HTTP" % map_name)
	_transfer_map_url = "%s/maps/%s.scn" % [http_base_url, map_name]
	_start_map_download()


func _start_map_download() -> void:
	if _active_map_request != null:
		_active_map_request.cancel_request()
		_active_map_request.queue_free()
	_active_map_request = HTTPRequest.new()
	_active_map_request.use_threads = true
	add_child(_active_map_request)
	_active_map_request.request_completed.connect(_on_map_download_done)
	var err := _active_map_request.request(_transfer_map_url)
	if err != OK:
		_active_map_request.queue_free()
		_active_map_request = null
		_map_download_attempts += 1
		if _map_download_attempts < _MAP_DOWNLOAD_MAX_ATTEMPTS:
			push_warning("Map HTTP request failed (attempt %d/%d): %s — retrying" % [
					_map_download_attempts, _MAP_DOWNLOAD_MAX_ATTEMPTS, error_string(err)])
			_start_map_download()
		else:
			push_error("Map download failed after %d attempts: %s" % [
					_map_download_attempts, error_string(err)])
			map_transfer_failed.emit()


@rpc("any_peer", "reliable")
func _map_cache_hit() -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	Log.info("Peer %d has map cached" % peer_id)


func _on_map_download_done(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _active_map_request != null:
		_active_map_request.queue_free()
		_active_map_request = null
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_map_download_attempts += 1
		if _map_download_attempts < _MAP_DOWNLOAD_MAX_ATTEMPTS:
			push_warning("Map download failed (attempt %d/%d): result=%d http=%d — retrying" % [
					_map_download_attempts, _MAP_DOWNLOAD_MAX_ATTEMPTS, result, response_code])
			_start_map_download()
		else:
			push_error("Map download failed after %d attempts: result=%d http=%d" % [
					_map_download_attempts, result, response_code])
			map_transfer_failed.emit()
		return
	Log.info("Map download complete: %s (%d bytes)" % [_transfer_map_name, body.size()])
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var map_path := "%s/%s.scn" % [CACHE_DIR, _transfer_map_name]
	var f := FileAccess.open(map_path, FileAccess.WRITE)
	if f != null:
		f.store_buffer(body)
		f.close()
	var hash_path := "%s/%s.hash" % [CACHE_DIR, _transfer_map_name]
	var hf := FileAccess.open(hash_path, FileAccess.WRITE)
	if hf != null:
		hf.store_string(_transfer_hash)
		hf.close()
	map_transfer_complete.emit(_transfer_map_name)


@rpc("authority", "call_remote", "reliable")
func _send_resource_manifest(packed: PackedByteArray, size: int, http_base_url: String) -> void:
	var manifest_json := packed.decompress(size, MANIFEST_COMPRESSION).get_string_from_utf8()
	Log.info("Received resource manifest (%d bytes, %d on the wire)" % [manifest_json.length(), packed.size()])
	var manifest = JSON.parse_string(manifest_json)
	if not manifest is Dictionary:
		Log.warn("Invalid resource manifest")
		resources_ready.emit()
		return

	var missing: Array[String] = []
	for rel_path in manifest:
		var entry: Dictionary = manifest[rel_path]
		var local_path := "%s/%s" % [AssetLoader.RESOURCE_DIR, rel_path]
		if FileAccess.file_exists(local_path):
			if FileAccess.get_md5(local_path) == entry.get("hash", ""):
				continue
		missing.append(rel_path)

	if missing.is_empty():
		Log.info("All resources cached locally")
		resources_ready.emit()
		_resources_cache_hit.rpc_id(1)
		return

	Log.info("Downloading %d missing resources via HTTP" % missing.size())
	if _res_downloader != null:
		_res_downloader.queue_free()
	var downloader := preload("res://src/systems/resource_downloader.gd").new()
	_res_downloader = downloader
	add_child(downloader)
	downloader.progress.connect(func(done: int, total: int): resources_transfer_progress.emit(done, total))
	downloader.all_complete.connect(_on_resources_download_complete)
	downloader.start(http_base_url + "/resources", missing, AssetLoader.RESOURCE_DIR)


@rpc("any_peer", "reliable")
func _resources_cache_hit() -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	Log.info("Peer %d has all resources cached" % peer_id)


func _on_resources_download_complete() -> void:
	if _res_downloader != null:
		_res_downloader.queue_free()
		_res_downloader = null
	Log.info("Resource HTTP download complete")
	resources_ready.emit()


# --- HTTP base URL ---

func _get_http_base_url() -> String:
	if not http_base_url_override.is_empty():
		return http_base_url_override.trim_suffix("/")
	return "http://%s:%d" % [_get_local_ip(), HTTP_PORT]


func _get_local_ip() -> String:
	# Prefer RFC-1918 addresses (LAN play); fall back to any non-loopback IPv4.
	for addr: String in IP.get_local_addresses():
		if _is_private_ipv4(addr):
			return addr
	for addr: String in IP.get_local_addresses():
		if not addr.contains(":") and addr != "127.0.0.1":
			return addr
	return "127.0.0.1"


## True for RFC-1918 private IPv4 addresses: 10/8, 192.168/16, and 172.16/12
## (172.16.x.x–172.31.x.x only — the rest of 172.x is public space).
func _is_private_ipv4(addr: String) -> bool:
	if addr.begins_with("10.") or addr.begins_with("192.168."):
		return true
	if addr.begins_with("172."):
		var second := addr.get_slice(".", 1)
		return second.is_valid_int() and int(second) >= 16 and int(second) <= 31
	return false
