extends Node
## Draws the running game as text. Everything it knows about the game is in rules.json and
## templates.txt; the game knows nothing about it. See README.md.
##
## A frame is a ray per cell into the world (depth, normal, owner), then each tracked entity draws
## itself at its own depth, tested cell by cell against what the rays found.

const CELL_ASPECT := 2.0
const RANGE := 80.0
const WALL_RAMP := " .:;+*"
const CEILING_RAMP := "  ''"
const FLOOR_RAMP := "  ..,"
const LIGHT := Vector3(0.5, 0.75, 0.3)
const OPAQUE_BLANK := "`"
const MIRROR := {"/": "\\", "\\": "/", "(": ")", ")": "(", "<": ">", ">": "<",
	"[": "]", "]": "[", "{": "}", "}": "{", "d": "b", "b": "d", "p": "q", "q": "p"}
const MISS := 0
const SOLID := 1
const LIQUID := 2

var cols := 120
var rows := 40
var hfov := 90.0
var every := 0.2
var max_frames := 0
var start_delay := 3.0
var out_path := ""
var append := false
var color := false
var follow := ""

var _rules: Array = []
var _world_mask := 0
var _hitbox_mask := 0
var _part_bones: Array = []
var _part_glyphs := {}
var _liquid_color := ""
var _templates := {}

var _tracked := {}
var _drawn := {}
var _landed := 0
var _owner_cache := {}
var _clock := 0.0
var _next := 0.0
var _frames := 0
var _target_id := 0
var _cam := Transform3D()
var _cam_yaw := 0.0
var _tx := 1.0
var _ty := 1.0
var _query := PhysicsRayQueryParameters3D.new()
var _space: PhysicsDirectSpaceState3D

var _dirs := PackedVector3Array()
var _depth := PackedFloat32Array()
var _normal := PackedVector3Array()
var _pos := PackedVector3Array()
var _hit := PackedByteArray()
var _glyph := PackedStringArray()
var _tint := PackedStringArray()


func _ready() -> void:
	cols = _env_int("ASCII_COLS", cols)
	rows = _env_int("ASCII_ROWS", rows)
	hfov = _env_float("ASCII_FOV", hfov)
	every = _env_float("ASCII_EVERY", every)
	max_frames = _env_int("ASCII_FRAMES", max_frames)
	start_delay = _env_float("ASCII_START", start_delay)
	out_path = OS.get_environment("ASCII_OUT")
	append = OS.get_environment("ASCII_APPEND") == "1"
	color = OS.get_environment("ASCII_COLOR") == "1"
	follow = OS.get_environment("ASCII_FOLLOW")
	_load_rules(get_script().resource_path.get_base_dir().path_join("rules.json"))
	_load_templates(get_script().resource_path.get_base_dir().path_join("templates.txt"))

	_tx = tan(deg_to_rad(hfov) * 0.5)
	_ty = _tx * rows * CELL_ASPECT / cols
	var n := cols * rows
	_dirs.resize(n)
	_depth.resize(n)
	_normal.resize(n)
	_pos.resize(n)
	_hit.resize(n)
	_glyph.resize(n)
	_tint.resize(n)
	for r in rows:
		for c in cols:
			var x := (2.0 * (c + 0.5) / cols - 1.0) * _tx
			var y := (1.0 - 2.0 * (r + 0.5) / rows) * _ty
			_dirs[r * cols + c] = Vector3(x, y, -1.0)
	_query.collide_with_areas = true
	_query.collide_with_bodies = true
	get_tree().node_added.connect(_on_node_added)


func _process(delta: float) -> void:
	_clock += delta
	if _clock < start_delay or _clock < _next:
		return
	_next = _clock + every
	var world := get_tree().root.find_world_3d()
	_space = world.direct_space_state if world else null
	if _space == null:
		return
	var t0 := Time.get_ticks_usec()
	var target := _update_entities()
	if target.is_empty():
		return
	_place_camera(target)
	_cast_world()
	_shade_world()
	_draw_entities()
	_emit(target, (Time.get_ticks_usec() - t0) / 1000.0)
	_frames += 1
	if max_frames > 0 and _frames >= max_frames:
		get_tree().quit()


# --- what things are ---------------------------------------------------------------------------

func _on_node_added(node: Node) -> void:
	if not node is Node3D:
		return
	var rule := _match(node)
	if rule.is_empty():
		return
	_tracked[node.get_instance_id()] = {
		"node": node, "rule": rule, "kind": rule.kind, "hitboxes": [], "hb_at": -1.0,
		"pos": (node as Node3D).global_position, "at": _clock, "vel": Vector3.ZERO, "facing": 1,
	}


func _match(node: Node) -> Dictionary:
	var names := _script_names(node)
	for rule: Dictionary in _rules:
		if rule.has("script") and not names.has(rule.script):
			continue
		if rule.has("native") and not node.is_class(rule.native):
			continue
		if rule.has("name") and not String(node.name).match(rule.name):
			continue
		return rule
	return {}


func _script_names(node: Node) -> PackedStringArray:
	var out := PackedStringArray()
	var s: Script = node.get_script()
	while s:
		var g := s.get_global_name()
		if g != &"":
			out.append(g)
		s = s.get_base_script()
	return out


## The tracked entity a collider belongs to, or 0 for the world.
func _owner_of(collider: Object) -> int:
	if collider == null:
		return 0
	var cid := collider.get_instance_id()
	if _owner_cache.has(cid):
		return _owner_cache[cid]
	var n := collider as Node
	var found := 0
	while n:
		if _tracked.has(n.get_instance_id()):
			found = n.get_instance_id()
			break
		n = n.get_parent()
	_owner_cache[cid] = found
	return found


func _part_of(area: Node) -> String:
	if int(area.get_meta("hitbox_group", 0)) == 1:
		return "head"
	var bone := String(area.get_meta("hitbox_bone", ""))
	for pb: Array in _part_bones:
		if (pb[0] as RegEx).search(bone):
			return pb[1]
	return "body"


## A rule's {property: {value: result}} lookup; "" as the property is a constant.
func _lookup(spec: Variant, node: Node) -> String:
	if not spec is Dictionary:
		return ""
	for prop: String in spec:
		var table: Dictionary = spec[prop]
		if prop == "":
			return table.get("", "")
		var v: Variant = node.get(prop)
		if v != null and table.has(str(v)):
			return table[str(v)]
	return ""


func _tags_of(rule: Dictionary, node: Node) -> PackedStringArray:
	var out := PackedStringArray()
	var spec: Dictionary = rule.get("tags", {})
	for prop: String in spec:
		var tag := _lookup({prop: spec[prop]}, node)
		if tag != "":
			out.append(tag)
	return out


# --- frame -------------------------------------------------------------------------------------

func _update_entities() -> Dictionary:
	if int(_clock) % 2 == 0:
		_owner_cache.clear()
	for id: int in _tracked.keys():
		var e: Dictionary = _tracked[id]
		if not is_instance_valid(e.node) or not (e.node as Node).is_inside_tree():
			_tracked.erase(id)
			continue
		var n: Node3D = e.node
		var p := n.global_position
		var dt: float = _clock - e.at
		if dt > 0.0:
			e.vel = (e.vel as Vector3).lerp((p - e.pos) / dt, 0.5)
		e.pos = p
		e.at = _clock
		if _clock - e.hb_at > 1.0:
			e.hb_at = _clock
			e.hitboxes = n.find_children("*", "Area3D", true, false).filter(
				func(a: Node) -> bool: return a.has_meta("hitbox_group"))
	return _pick_target()


func _pick_target() -> Dictionary:
	var cur: Dictionary = _tracked.get(_target_id, {})
	if not cur.is_empty() and _followable(cur):
		return cur
	var best := {}
	for id: int in _tracked:
		var e: Dictionary = _tracked[id]
		if follow != "" and String((e.node as Node).name).contains(follow) \
				and (e.node as Node3D).is_visible_in_tree():
			best = e
			break
		if best.is_empty() and _followable(e):
			best = e
	if not best.is_empty():
		_target_id = (best.node as Node).get_instance_id()
		_cam_yaw = (best.node as Node3D).global_rotation.y
	return best


func _followable(e: Dictionary) -> bool:
	if follow != "" and String((e.node as Node).name).contains(follow):
		return (e.node as Node3D).is_visible_in_tree()
	return e.rule.get("follow", false) and (e.node as Node3D).is_visible_in_tree() \
			and not _tags_of(e.rule, e.node).has("dead")


func _place_camera(target: Dictionary) -> void:
	var h: float = target.rule.get("height", 1.8)
	var head: Vector3 = target.pos + Vector3.UP * h * 0.9
	var v: Vector3 = target.vel
	v.y = 0.0
	if v.length() > 0.5:
		_cam_yaw = lerp_angle(_cam_yaw, atan2(-v.x, -v.z), 0.35)
	var fwd := Vector3(-sin(_cam_yaw), 0.0, -cos(_cam_yaw))
	var eye := head - fwd * 4.0 + Vector3.UP * 1.0
	_query.collision_mask = _world_mask
	_query.collide_with_areas = false
	_query.from = head
	_query.to = eye
	var r := _space.intersect_ray(_query)
	_query.collide_with_areas = true
	if not r.is_empty():
		eye = r.position + (head - r.position).normalized() * 0.3
	_cam = Transform3D(Basis.looking_at(head + fwd * 6.0 - Vector3.UP * 0.8 - eye), eye)


func _cast_world() -> void:
	var o := _cam.origin
	var b := _cam.basis
	var fwd := -b.z
	_query.collision_mask = _world_mask
	for i in _dirs.size():
		_query.from = o
		_query.to = o + b * _dirs[i] * RANGE
		var r := _space.intersect_ray(_query)
		if r.is_empty():
			_hit[i] = MISS
			_depth[i] = INF
			continue
		_depth[i] = (r.position - o).dot(fwd)
		_normal[i] = r.normal
		_pos[i] = r.position
		var owner_id := _owner_of(r.collider)
		var kind: String = _tracked[owner_id].kind if owner_id != 0 else ""
		_hit[i] = LIQUID if kind == "liquid" else SOLID


func _shade_world() -> void:
	for r in rows:
		for c in cols:
			var i := r * cols + c
			_tint[i] = ""
			if _hit[i] == MISS:
				_glyph[i] = " "
				continue
			if _hit[i] == LIQUID:
				_glyph[i] = "~"
				_tint[i] = _liquid_color
				continue
			var edge := _edge_glyph(r, c)
			if edge != "":
				_glyph[i] = edge
				continue
			var n := _normal[i]
			var fog := clampf(1.0 - _depth[i] / RANGE, 0.0, 1.0)
			if n.y > 0.7:
				_glyph[i] = FLOOR_RAMP[int(round(fog * (FLOOR_RAMP.length() - 1)))]
			elif n.y < -0.7:
				_glyph[i] = CEILING_RAMP[int(round(fog * (CEILING_RAMP.length() - 1)))]
			else:
				var s := (0.2 + 0.8 * maxf(0.0, n.dot(LIGHT.normalized()))) * fog
				_glyph[i] = WALL_RAMP[int(round(s * (WALL_RAMP.length() - 1)))]


func _edge_glyph(r: int, c: int) -> String:
	var i := r * cols + c
	var lft := c > 0 and _edge_between(i, i - 1, false)
	var rgt := c < cols - 1 and _edge_between(i, i + 1, true)
	var up := r > 0 and _edge_between(i, i - cols, false)
	var dn := r < rows - 1 and _edge_between(i, i + cols, true)
	var ex := lft or rgt
	var ey := up or dn
	if not ex and not ey:
		return ""
	if ex and not ey:
		return "|"
	if ey and not ex:
		return "_" if dn else "-"
	var sx := int(rgt) - int(lft)
	var sy := int(dn) - int(up)
	if sx == 0 and sy == 0:
		return "+"
	if sx == 0:
		return "_" if dn else "-"
	if sy == 0:
		return "|"
	return "/" if sx * sy > 0 else "\\"


## Whether the outline between cells i and j is drawn in i. Neighbours on one plane share no
## outline however fast the depth runs along it; a step belongs to the nearer side, and a crease
## to whichever of the two sits left of or above the other.
func _edge_between(i: int, j: int, own_crease: bool) -> bool:
	if _hit[j] == MISS:
		return true
	var di := _depth[i]
	var dj := _depth[j]
	var tol := 0.05 + 0.02 * di
	var off_plane := absf(_normal[i].dot(_pos[j] - _pos[i])) > tol \
			or absf(_normal[j].dot(_pos[i] - _pos[j])) > tol
	var bent := _normal[i].dot(_normal[j]) < 0.8
	if not off_plane and not bent:
		return false
	if _pos[i].distance_to(_pos[j]) > 0.5 + 0.1 * di:
		return di < dj
	return own_crease


# --- entities ----------------------------------------------------------------------------------

func _project(p: Vector3) -> Vector3:
	var l := _cam.affine_inverse() * p
	var d := -l.z
	if d <= 0.05:
		return Vector3(0.0, 0.0, -1.0)
	return Vector3((l.x / (d * _tx) + 1.0) * 0.5 * cols, (1.0 - l.y / (d * _ty)) * 0.5 * rows, d)


func _draw_entities() -> void:
	var order: Array = []
	for id: int in _tracked:
		var e: Dictionary = _tracked[id]
		if e.kind == "liquid" or not (e.node as Node3D).is_visible_in_tree():
			continue
		var d := _project(e.pos).z
		if d > 0.0 and d < RANGE:
			order.append([d, e])
	order.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	_drawn.clear()
	for pair: Array in order:
		if _draw_entity(pair[1]):
			_drawn[pair[1].kind] = _drawn.get(pair[1].kind, 0) + 1


## Whether any of it landed on screen.
func _draw_entity(e: Dictionary) -> bool:
	_landed = 0
	_draw_entity_glyphs(e)
	return _landed > 0


func _draw_entity_glyphs(e: Dictionary) -> void:
	var node: Node3D = e.node
	var rule: Dictionary = e.rule
	var foot: Vector3 = e.pos
	var top := foot + Vector3.UP * float(rule.get("height", 0.3))
	var boxes: Array = e.hitboxes.filter(func(a: Node) -> bool: return is_instance_valid(a))
	if not boxes.is_empty():
		var hi := -INF
		for a: Node3D in boxes:
			hi = maxf(hi, a.global_position.y)
		top = Vector3(foot.x, hi + 0.2, foot.z)
	var centered: bool = e.kind == "projectile"
	if centered:
		var half := (top - foot) * 0.5
		foot -= half
		top -= half
	var pf := _project(foot)
	var pt := _project(top)
	if pf.z <= 0.0 or pt.z <= 0.0:
		return
	var depth := (pf.z + pt.z) * 0.5
	var height := pf.y - pt.y
	var tint := _lookup(rule.get("color"), node)

	var s := _project(foot - (e.vel as Vector3) * 0.2)
	if s.z > 0.0 and absf(pf.x - s.x) > 0.3:
		e.facing = 1 if pf.x > s.x else -1

	var tags := _tags_of(rule, node)
	var tmpl := _choose_template(e.kind, tags, height)
	var tallest := _tallest(e.kind, tags)
	if e.kind == "figure" and not boxes.is_empty() and height > tallest + 2:
		_draw_by_parts(e, boxes, tint)
		return
	if e.kind == "projectile":
		_draw_trail(e, depth, tint)
	if tmpl.is_empty() or (rule.has("glyph") and (tmpl.h <= 1 or not _templates.has(e.kind))):
		_put(int(floor(pf.x)), int(floor(pf.y if not centered else (pf.y + pt.y) * 0.5)),
				rule.get("glyph", "?"), depth, tint)
		return
	var hat := _lookup(rule.get("hat"), node)
	var th: int = tmpl.h
	var bottom: int = int(floor(pf.y)) if not centered else int(floor((pf.y + pt.y) * 0.5)) + int(th * 0.5)
	var left: int = int(round(pf.x - float(tmpl.w) * 0.5))
	for k in th:
		var line := _template_line(tmpl, k, hat, e.facing < 0)
		var row: int = bottom - th + 1 + k
		for x in line.length():
			if line[x] != " ":
				_put(left + x, row, " " if line[x] == OPAQUE_BLANK else line[x], depth, tint)


## Close enough that the hitboxes are bigger than any template: draw the body itself, part by
## part, with rays capped at whatever the world rays hit.
func _draw_by_parts(e: Dictionary, boxes: Array, tint: String) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for a: Node3D in boxes:
		var p := _project(a.global_position)
		if p.z <= 0.0:
			continue
		lo = lo.min(Vector2(p.x, p.y))
		hi = hi.max(Vector2(p.x, p.y))
	if lo.x == INF:
		return
	var pad := maxf(2.0, (hi.y - lo.y) * 0.25)
	var o := _cam.origin
	var b := _cam.basis
	var own := (e.node as Node).get_instance_id()
	var parts := {}
	_query.collision_mask = _hitbox_mask
	for r in range(maxi(0, int(lo.y - pad)), mini(rows, int(hi.y + pad) + 1)):
		for c in range(maxi(0, int(lo.x - pad)), mini(cols, int(hi.x + pad) + 1)):
			var i := r * cols + c
			_query.from = o
			_query.to = o + b * _dirs[i] * minf(_depth[i], RANGE)
			var hit := _space.intersect_ray(_query)
			if not hit.is_empty() and _owner_of(hit.collider) == own:
				parts[i] = _part_of(hit.collider)
	for i: int in parts:
		var part: String = parts[i]
		var g: String = _part_glyphs.get(part, "#")
		if part != "head":
			var outline := _outline(parts, i)
			if outline != "":
				g = outline
		_glyph[i] = " " if g == OPAQUE_BLANK else g
		_tint[i] = tint
		_landed += 1


## The edge glyph for cell i on the border of `cells`, or "" inside it.
func _outline(cells: Dictionary, i: int) -> String:
	var c := i % cols
	var lft := c == 0 or not cells.has(i - 1)
	var rgt := c == cols - 1 or not cells.has(i + 1)
	var up := not cells.has(i - cols)
	var dn := not cells.has(i + cols)
	if lft and rgt:
		return "|"
	if up and dn:
		return "-"
	if lft or rgt:
		if up:
			return "/" if lft else "\\"
		if dn:
			return "\\" if lft else "/"
		return "|"
	if up:
		return "-"
	if dn:
		return "_"
	return ""


func _draw_trail(e: Dictionary, depth: float, tint: String) -> void:
	var v: Vector3 = e.vel
	if v.length() < 2.0:
		return
	var a := _project(e.pos)
	for k in range(1, 4):
		var p := _project(e.pos - v.normalized() * 0.5 * k)
		if p.z <= 0.0:
			return
		var g := "."
		if k == 1:
			var dx := p.x - a.x
			var dy := (p.y - a.y) * CELL_ASPECT
			var ang := fposmod(rad_to_deg(atan2(-dy, dx)), 180.0)
			g = "-" if ang < 22.5 or ang >= 157.5 else ("/" if ang < 67.5 else ("|" if ang < 112.5 else "\\"))
		_put(int(floor(p.x)), int(floor(p.y)), g, depth, tint)


## The depth test: a glyph lands only where the world rays hit something farther away.
func _put(c: int, r: int, g: String, depth: float, tint: String) -> void:
	if c < 0 or c >= cols or r < 0 or r >= rows:
		return
	var i := r * cols + c
	if _depth[i] < depth - 0.4:
		return
	_glyph[i] = g
	_tint[i] = tint
	_landed += 1


func _choose_template(kind: String, tags: PackedStringArray, height: float) -> Dictionary:
	var best := {}
	var best_score := -INF
	for t: Dictionary in _templates.get(kind, []):
		if not _has_all(tags, t.tags):
			continue
		var fits: bool = t.h <= maxf(1.0, height * 1.2)
		var score: float = t.tags.size() * 1000.0 + (t.h if fits else -t.h * 10.0)
		if score > best_score:
			best_score = score
			best = t
	return best


func _tallest(kind: String, tags: PackedStringArray) -> int:
	var h := 0
	for t: Dictionary in _templates.get(kind, []):
		if _has_all(tags, t.tags):
			h = maxi(h, t.h)
	return h


func _has_all(have: PackedStringArray, need: PackedStringArray) -> bool:
	for t in need:
		if not have.has(t):
			return false
	return true


func _template_line(t: Dictionary, k: int, hat: String, mirrored: bool) -> String:
	var line: String = t.lines[k]
	var at := line.find("$")
	if at >= 0:
		var h := hat if hat != "" else " "
		line = line.substr(0, at) + h + line.substr(at + 1)
	line = line.rpad(t.w)
	if not mirrored:
		return line
	var out := ""
	for x in range(line.length() - 1, -1, -1):
		out += MIRROR.get(line[x], line[x])
	return out


# --- output ------------------------------------------------------------------------------------

func _emit(target: Dictionary, ms: float) -> void:
	var tnode: Node = target.node
	var tags := _tags_of(target.rule, tnode)
	var seen := PackedStringArray()
	for kind: String in _drawn:
		seen.append("%s %d" % [kind, _drawn[kind]])
	var header := "t=%.1fs  following %s [%s]  on screen: %s  %.0f ms" % [
		_clock, tnode.name, ", ".join(tags), ", ".join(seen), ms]
	var lines := PackedStringArray([header])
	for r in rows:
		var s := ""
		var cur := ""
		for c in cols:
			var i := r * cols + c
			if color and _tint[i] != cur:
				cur = _tint[i]
				s += "\u001b[0m" if cur == "" else "\u001b[%sm" % cur
			s += _glyph[i]
		if color and cur != "":
			s += "\u001b[0m"
		lines.append(s)
	var frame := "\n".join(lines) + "\n"
	if out_path == "":
		print(frame)
		return
	if append:
		var f := FileAccess.open(out_path, FileAccess.READ_WRITE if FileAccess.file_exists(out_path) else FileAccess.WRITE)
		f.seek_end()
		f.store_string(frame + "\n")
		return
	var tmp := out_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_string(frame)
	f.close()
	DirAccess.rename_absolute(tmp, out_path)


# --- config ------------------------------------------------------------------------------------

func _load_rules(path: String) -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_rules = data.get("rules", [])
	for layer: float in data.get("world_layers", []):
		_world_mask |= 1 << (int(layer) - 1)
	for layer: float in data.get("hitbox_layers", []):
		_hitbox_mask |= 1 << (int(layer) - 1)
	var bones: Dictionary = data.get("part_bones", {})
	for pattern: String in bones:
		var re := RegEx.new()
		re.compile(pattern)
		_part_bones.append([re, bones[pattern]])
	_part_glyphs = data.get("part_glyphs", {})
	_liquid_color = data.get("liquid_color", "")


func _load_templates(path: String) -> void:
	var cur := {}
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		var line := raw.rstrip(" \r")
		if line.begins_with("=== "):
			var words := line.substr(4).split(" ", false)
			cur = {"tags": words.slice(1), "lines": PackedStringArray()}
			if not _templates.has(words[0]):
				_templates[words[0]] = []
			_templates[words[0]].append(cur)
		elif not cur.is_empty():
			cur.lines.append(line)
	for kind: String in _templates:
		for t: Dictionary in _templates[kind]:
			var lines: PackedStringArray = t.lines
			while not lines.is_empty() and lines[lines.size() - 1].strip_edges() == "":
				lines.remove_at(lines.size() - 1)
			t.lines = lines
			t.h = lines.size()
			var w := 0
			for l in lines:
				w = maxi(w, l.length())
			t.w = w


func _env_int(key: String, fallback: int) -> int:
	var v := OS.get_environment(key)
	return int(v) if v.is_valid_int() else fallback


func _env_float(key: String, fallback: float) -> float:
	var v := OS.get_environment(key)
	return float(v) if v.is_valid_float() else fallback
