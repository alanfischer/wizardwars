extends Node
## LAN server discovery over a UDP beacon: a host broadcasts what it is running once a second, a
## client in the lobby listens and keeps a live list.
##
## Deliberately not part of NetworkManager: this runs with no session at all (the lobby browses
## before anything is connected), it holds no gameplay state, and it never touches the replication
## wire. The only coupling left is the beacon payload, which advertises NetworkManager's listen
## port and player count.
##
## No class_name — autoloaded as ServerBrowser.

const GameVersion = preload("res://src/systems/game_version.gd")

signal server_found(ip: String, info: Dictionary)
signal server_lost(ip: String)

const BEACON_PORT := 9051
const BEACON_INTERVAL := 1.0
const BEACON_TIMEOUT := 5.0

var _beacon_udp: PacketPeerUDP
var _listen_udp: PacketPeerUDP
var _beacon_timer := 0.0
var _beacon_data := {}
var _known_servers: Dictionary = {}  # ip -> {info, last_seen}
var _is_broadcasting := false
var _is_listening := false


func start_beacon(map_name: String, map_hash: String = "") -> void:
	stop_beacon()
	_beacon_udp = PacketPeerUDP.new()
	_beacon_udp.set_broadcast_enabled(true)
	# Bind to any available port so the OS assigns a source address — required on macOS for broadcast
	# to actually leave the network interface.
	var err := _beacon_udp.bind(0)
	if err != OK:
		push_warning("Beacon: failed to bind UDP socket: %s" % error_string(err))
	_beacon_udp.set_dest_address("255.255.255.255", BEACON_PORT)
	_beacon_data = {
		"game": GameVersion.GAME_ID,
		"map": map_name,
		"max": NetworkManager.MAX_CLIENTS,
		"port": NetworkManager.PORT,
		"map_hash": map_hash,
	}
	_beacon_timer = BEACON_INTERVAL
	_is_broadcasting = true
	Log.info("LAN beacon started for map: %s" % map_name)


func stop_beacon() -> void:
	if _beacon_udp:
		_beacon_udp.close()
		_beacon_udp = null
	_is_broadcasting = false


func start_listening() -> void:
	stop_listening()
	_listen_udp = PacketPeerUDP.new()
	var err := _listen_udp.bind(BEACON_PORT)
	if err != OK:
		push_warning("Failed to bind beacon listener on port %d: %s" % [BEACON_PORT, error_string(err)])
		_listen_udp = null
		return
	_known_servers.clear()
	_is_listening = true
	Log.info("LAN beacon listener started on port %d" % BEACON_PORT)


func stop_listening() -> void:
	if _listen_udp:
		_listen_udp.close()
		_listen_udp = null
	_is_listening = false
	_known_servers.clear()


func _process(delta: float) -> void:
	if _is_broadcasting:
		_beacon_timer += delta
		if _beacon_timer >= BEACON_INTERVAL:
			_beacon_timer = 0.0
			# Derived here rather than pushed from every spawn and despawn, the way
			# NetworkManager.build_status() does it — the count cannot go stale if nothing caches it.
			_beacon_data["players"] = NetworkManager.player_count()
			var json := JSON.stringify(_beacon_data)
			_beacon_udp.put_packet(json.to_utf8_buffer())

	if _is_listening and _listen_udp:
		while _listen_udp.get_available_packet_count() > 0:
			var packet := _listen_udp.get_packet()
			var ip := _listen_udp.get_packet_ip()
			var json_str := packet.get_string_from_utf8()
			var parsed = JSON.parse_string(json_str)
			if parsed is Dictionary and parsed.get("game", "") == GameVersion.GAME_ID:
				var info := {
					"map": parsed.get("map", ""),
					"players": int(parsed.get("players", 0)),
					"max": int(parsed.get("max", 0)),
					"port": int(parsed.get("port", NetworkManager.PORT)),
					"map_hash": str(parsed.get("map_hash", "")),
				}
				_known_servers[ip] = {"info": info, "last_seen": Time.get_ticks_msec()}
				server_found.emit(ip, info)

		var now := Time.get_ticks_msec()
		var stale: Array[String] = []
		for ip in _known_servers:
			if (now - _known_servers[ip]["last_seen"]) > BEACON_TIMEOUT * 1000:
				stale.append(ip)
		for ip in stale:
			_known_servers.erase(ip)
			server_lost.emit(ip)
