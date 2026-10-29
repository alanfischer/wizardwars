class_name SpawnCodec
extends RefCounted

## Packs a dynamic entity's spawn data for the wire. goldnet resends a spawn until the client acks
## it, and var_to_bytes of the dictionary spent most of a magic missile's 224 bytes on key strings
## and the script path. Here a known key is one byte, a script path loses the prefix and suffix
## every one shares, and the common value types drop Variant's 4-byte padding; anything else falls
## back to var_to_bytes. Not resource UIDs: *.uid is gitignored, so each checkout mints its own.

## Append only: an index is what goes on the wire, so both peers must agree on the order.
const KEYS: Array[String] = ["script_path", "entity_id", "born_ms", "position", "direction",
	"team", "sync_state", "owner_peer_id", "yaw", "speed", "lifetime", "damage", "damage_type",
	"velocity", "target_pos", "team_no", "ent", "start_angle", "staff_path", "radius", "model_path",
	"level", "lead", "is_first", "headroom", "fuse_remaining", "element", "charge_percent",
	"spr_scale", "spr_path", "sound_path", "ring_color", "players", "light_color", "shot_seq"]
const KEY_STRING := 255  ## a key not in KEYS: its name follows

enum { T_INT, T_FLOAT, T_DOUBLE, T_VEC3, T_TRUE, T_FALSE, T_STRING, T_SCRIPT, T_VARIANT }
const SCRIPT_PREFIX := "res://src/"
const SCRIPT_SUFFIX := ".gd"

static var _key_index := {}


static func pack(data: Dictionary) -> PackedByteArray:
	if _key_index.is_empty():
		for i in KEYS.size():
			_key_index[KEYS[i]] = i
	var out := StreamPeerBuffer.new()
	for key in data:
		var k: int = _key_index.get(key, KEY_STRING) if key is String else KEY_STRING
		out.put_u8(k)
		if k == KEY_STRING:
			_put_variant(out, key)
		_put_value(out, data[key], k == 0)  # KEYS[0] is script_path
	return out.data_array


static func unpack(bytes: PackedByteArray) -> Dictionary:
	var data := {}
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	while buf.get_position() < buf.get_size():
		var k := buf.get_u8()
		var key: Variant = _get_variant(buf) if k == KEY_STRING else KEYS[k]
		data[key] = _get_value(buf)
	return data


static func _put_value(out: StreamPeerBuffer, v: Variant, is_script: bool) -> void:
	match typeof(v):
		TYPE_INT:
			out.put_u8(T_INT)
			_put_varint(out, v)
		TYPE_FLOAT:
			# f32 when that loses nothing (5.0, 0.5), so a value survives the trip exactly.
			if float(_as_f32(v)) == v:
				out.put_u8(T_FLOAT)
				out.put_float(v)
			else:
				out.put_u8(T_DOUBLE)
				out.put_double(v)
		TYPE_VECTOR3:
			out.put_u8(T_VEC3)
			out.put_float(v.x)
			out.put_float(v.y)
			out.put_float(v.z)
		TYPE_BOOL:
			out.put_u8(T_TRUE if v else T_FALSE)
		TYPE_STRING:
			if is_script and v.begins_with(SCRIPT_PREFIX) and v.ends_with(SCRIPT_SUFFIX):
				out.put_u8(T_SCRIPT)
				_put_string(out, v.trim_prefix(SCRIPT_PREFIX).trim_suffix(SCRIPT_SUFFIX))
			else:
				out.put_u8(T_STRING)
				_put_string(out, v)
		_:
			out.put_u8(T_VARIANT)
			_put_variant(out, v)


static func _get_value(buf: StreamPeerBuffer) -> Variant:
	match buf.get_u8():
		T_INT:
			return _get_varint(buf)
		T_FLOAT:
			return buf.get_float()
		T_DOUBLE:
			return buf.get_double()
		T_VEC3:
			return Vector3(buf.get_float(), buf.get_float(), buf.get_float())
		T_TRUE:
			return true
		T_FALSE:
			return false
		T_STRING:
			return _get_string(buf)
		T_SCRIPT:
			return SCRIPT_PREFIX + _get_string(buf) + SCRIPT_SUFFIX
		_:
			return _get_variant(buf)


static func _as_f32(v: float) -> float:
	var b := PackedFloat32Array([v])
	return b[0]


## Zig-zag, then 7 bits a byte.
static func _put_varint(out: StreamPeerBuffer, v: int) -> void:
	var u := (v << 1) ^ (v >> 63)
	while true:
		var byte := u & 0x7f
		u = (u >> 7) & 0x01ffffffffffffff  # logical shift: GDScript's >> keeps the sign
		if u == 0:
			out.put_u8(byte)
			return
		out.put_u8(byte | 0x80)


static func _get_varint(buf: StreamPeerBuffer) -> int:
	var u := 0
	var shift := 0
	while shift < 64:
		var byte := buf.get_u8()
		u |= (byte & 0x7f) << shift
		if byte & 0x80 == 0:
			break
		shift += 7
	return ((u >> 1) & 0x7fffffffffffffff) ^ -(u & 1)


static func _put_string(out: StreamPeerBuffer, s: String) -> void:
	var b := s.to_utf8_buffer()
	_put_varint(out, b.size())
	out.put_data(b)


static func _get_string(buf: StreamPeerBuffer) -> String:
	var n := _get_varint(buf)
	return buf.get_utf8_string(n)


static func _put_variant(out: StreamPeerBuffer, v: Variant) -> void:
	var b := var_to_bytes(v)
	_put_varint(out, b.size())
	out.put_data(b)


static func _get_variant(buf: StreamPeerBuffer) -> Variant:
	var n := _get_varint(buf)
	var got: Array = buf.get_data(n)
	return bytes_to_var(got[1])
