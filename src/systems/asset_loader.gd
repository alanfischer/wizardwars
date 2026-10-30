extends Node

const RESOURCE_DIR := "user://resources"


## Load a model from pre-converted native .scn, falling back to C++ plugin.
## rel_path is relative to  (e.g. "models/backpack.mdl").
func load_model(rel_path: String) -> Node3D:
	rel_path = rel_path.replace("\\", "/").replace("*", "")
	var model: Node3D = null
	# Try Godot-imported scene (res://models/backpack.mdl → PackedScene via mdl_importer)
	var res_path := "res://" + rel_path
	if ResourceLoader.exists(res_path):
		var scene: PackedScene = load(res_path)
		if scene:
			model = scene.instantiate()
	# Fallback: pre-converted scene in user://resources/ (server deployments)
	if not model:
		var native_path := "%s/%s.scn" % [RESOURCE_DIR, rel_path.get_basename()]
		if ResourceLoader.exists(native_path):
			var scene: PackedScene = load(native_path)
			if scene:
				model = scene.instantiate()
	# Fallback to C++ plugin (host-only) — extract to plain Node3D so no runtime
	# C++ dependency remains, matching the resource_converter.gd conversion path.
	if not model and ClassDB.class_exists(&"GoldSrcMDL"):
		var full_path := "res://" + rel_path
		var mdl = ClassDB.instantiate(&"GoldSrcMDL")
		mdl.set_scale_factor(GameConsts.SCALE_FACTOR)
		if mdl.load_mdl(full_path) == OK:
			mdl.build_model()
			var root := Node3D.new()
			root.name = rel_path.get_file().get_basename()
			root.rotation_degrees.y = 90.0
			for child in mdl.get_children().duplicate():
				mdl.remove_child(child)
				root.add_child(child)
			mdl.free()
			model = root
		else:
			mdl.free()
			push_warning("AssetLoader.load_model: failed to load %s" % full_path)
	if not model:
		push_warning("AssetLoader.load_model: no native scene and no plugin for %s" % rel_path)
		return null
	_apply_mdl_overbright(model, 2.0)
	EntityRender.apply_color_space(model)
	if rel_path in _EMISSIVE_TEXTURES:
		_apply_emissive_textures(model, _EMISSIVE_TEXTURES[rel_path])
	if light_grid and light_grid.is_valid():
		light_grid.apply_textures_to_node(model)
	return model


## Apply a team skin to a model. Works with both GoldSrcMDL (plugin) and .scn (converted).
func set_model_skin(model: Node3D, family: int) -> void:
	if family <= 0 or DisplayServer.get_name() == "headless":
		return
	if model.has_method("set_skin"):
		model.set_skin(family)
		return
	# Converted .scn path — skin materials stored as metadata on MeshInstance3D nodes
	_apply_skin_recursive(model, family)


func _apply_skin_recursive(node: Node, family: int) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if node is MeshInstance3D:
		var key := "skin_%d" % family
		if node.has_meta(key):
			var stored = node.get_meta(key)
			# One material per surface. A .scn converted before models merged their meshes into
			# one instance per bodypart stored a single material instead — those keep working.
			if stored is Array:
				for surf_idx in mini(stored.size(),
						(node as MeshInstance3D).get_surface_override_material_count()):
					if stored[surf_idx]:
						node.set_surface_override_material(surf_idx, stored[surf_idx])
			else:
				node.set_surface_override_material(0, stored)
	for child in node.get_children():
		_apply_skin_recursive(child, family)


## Drop the per-bone hitbox volumes an MDL ships with. First-person viewmodels are never
## targets, and on a listen host the view is not in the "damageable" group, so hitscan's
## exclude list (built from that group) never covered them: the host's own hand model sat in
## front of the camera eating their rays — and heal(), unlike take_damage(), has no group
## gate, so a life ray landing there overhealed the caster. Call before adding to the tree.
func strip_hitboxes(model: Node3D) -> void:
	var doomed: Array[Node] = []
	_collect_hitboxes(model, doomed)
	for area in doomed:
		var attach := area.get_parent()
		area.free()
		# The BoneAttachment3D exists only to carry the hitbox; without it, it just costs bone updates.
		if attach is BoneAttachment3D and attach.get_child_count() == 0:
			attach.free()


func _collect_hitboxes(node: Node, out: Array[Node]) -> void:
	if node is Area3D and node.has_meta("hitbox_group"):
		out.append(node)
		return
	for child in node.get_children():
		_collect_hitboxes(child, out)


## Model path -> list of albedo texture sizes (Vector2i) that should glow.
const _EMISSIVE_TEXTURES := {
	"models/hands/fire.mdl": [Vector2i(44, 47)],  # FireStaffburn.bmp
}


## Make surfaces whose albedo texture matches the given sizes glow via emission.
## Works with both StandardMaterial3D and ambient-cube ShaderMaterial.
func _apply_emissive_textures(node: Node, sizes: Array) -> void:
	if DisplayServer.get_name() == "headless":
		return
	for child in node.get_children():
		if child is MeshInstance3D:
			var mesh: Mesh = child.mesh
			if not mesh:
				continue
			for surf_idx in mesh.get_surface_count():
				var mat := mesh.surface_get_material(surf_idx)
				var tex: Texture2D
				if mat is StandardMaterial3D:
					tex = mat.albedo_texture
				elif mat is ShaderMaterial:
					tex = mat.get_shader_parameter("albedo_texture")
				if not tex:
					continue
				if _is_emissive_material(mat):
					continue
				var sz := Vector2i(tex.get_width(), tex.get_height())
				if sz in sizes:
					mesh.surface_set_material(surf_idx, _emissive_material(tex))
		_apply_emissive_textures(child, sizes)


## One glow material per texture, held for the session. The mesh is shared and cached, so a fresh
## material per load_model() dropped the previous one — and with it the last user of its
## generated shader, which Godot then frees and recompiles: ~110ms on every weapon switch.
var _emissive_materials := {}

func _emissive_material(tex: Texture2D) -> StandardMaterial3D:
	if _emissive_materials.has(tex):
		return _emissive_materials[tex]
	var glow_mat := StandardMaterial3D.new()
	glow_mat.albedo_texture = tex
	glow_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.emission_enabled = true
	glow_mat.emission = Color(1.0, 0.6, 0.1)
	glow_mat.emission_energy_multiplier = 2.0
	_emissive_materials[tex] = glow_mat
	return glow_mat


func _is_emissive_material(mat: Material) -> bool:
	return mat is StandardMaterial3D and _emissive_materials.get(mat.albedo_texture) == mat


## Light grid for ambient cube textures on MDL models.
## Set by main.gd after map load; used by load_model to bind 3D textures.
var light_grid: LightGrid

## Shared ambient cube shaders for MDL models (loaded lazily; shaders not present on server).
var _mdl_acube_shader: Shader
var _mdl_acube_fade_shader: Shader

func _get_mdl_acube_shader() -> Shader:
	if not _mdl_acube_shader:
		_mdl_acube_shader = load("res://shaders/mdl_ambient_cube.gdshader")
	return _mdl_acube_shader

func _get_mdl_acube_fade_shader() -> Shader:
	if not _mdl_acube_fade_shader:
		_mdl_acube_fade_shader = load("res://shaders/mdl_ambient_cube_fade.gdshader")
	return _mdl_acube_fade_shader


# An MDL model's two per-instance looks. Both are held on the model root rather than worked out
# from the material, because either can be set while the other is mid-change and neither setter
# knows what the other wanted. Read back through _apply_model_look.
const _META_ALPHA := &"mdl_alpha"
const _META_GLOW := &"mdl_glow"  # [Color, strength]


## Set alpha on an MDL model by swapping to the fade shader variant. At 1.0 it swaps back —
## unless the model is also glowing, which needs the override material either way.
func set_model_alpha(node: Node, value: float) -> void:
	node.set_meta(_META_ALPHA, value)
	_apply_model_look(node)


## Light an MDL model from inside, brightest at its silhouette: GoldSrc's glow shell without the
## second hull (see the shader). Strength 0 turns it off and hands the model back its shared
## material, so this is cheap to leave switched off.
func set_model_glow(node: Node, color: Color, strength: float) -> void:
	node.set_meta(_META_GLOW, [color, strength])
	_apply_model_look(node)


func _apply_model_look(root: Node) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var glow: Array = root.get_meta(_META_GLOW, [Color.BLACK, 0.0])
	_apply_model_look_to(root, float(root.get_meta(_META_ALPHA, 1.0)), glow[0], glow[1])


func _apply_model_look_to(node: Node, alpha: float, glow_color: Color, glow_strength: float) -> void:
	var fading := alpha < 1.0
	if node is MeshInstance3D and node.mesh:
		for surf_idx in node.mesh.get_surface_count():
			var mat: Material = node.get_active_material(surf_idx)
			var opaque_shader := _get_mdl_acube_shader()
			var fade_shader := _get_mdl_acube_fade_shader()

			if not mat is ShaderMaterial or mat.shader not in [opaque_shader, fade_shader]:
				continue

			if not fading and glow_strength <= 0.0:
				# Nothing left to say about this surface — drop the override and let the shared
				# (opaque) material draw it again.
				node.set_surface_override_material(surf_idx, null)
				continue

			# Ensure we have a per-instance override (don't mutate shared materials)
			if not node.get_surface_override_material(surf_idx):
				mat = mat.duplicate()
				node.set_surface_override_material(surf_idx, mat)
			else:
				mat = node.get_surface_override_material(surf_idx)

			# ONLY swap the shader when the variant actually has to change.
			# In Godot 4, re-assigning the .shader property clears all parameters.
			var want_shader := fade_shader if fading else opaque_shader
			if mat.shader != want_shader:
				# Cache existing parameters before they are wiped
				var params := {}
				var smat := mat as ShaderMaterial
				# We only need to preserve the common parameters between acube/acube_fade
				for p in ["albedo_texture", "overbright", "grid_origin", "grid_size",
						"acube_pos_x", "acube_neg_x", "acube_pos_y", "acube_neg_y",
						"acube_pos_z", "acube_neg_z", "lightstyle_brightness", "linear_output"]:
					params[p] = smat.get_shader_parameter(p)

				smat.shader = want_shader

				for p in params:
					if params[p] != null:
						smat.set_shader_parameter(p, params[p])

			if fading:
				mat.set_shader_parameter("alpha", alpha)
			mat.set_shader_parameter("glow_color", Vector3(glow_color.r, glow_color.g, glow_color.b))
			mat.set_shader_parameter("glow_strength", glow_strength)
	for child in node.get_children():
		_apply_model_look_to(child, alpha, glow_color, glow_strength)


## Convert a StandardMaterial3D to a ShaderMaterial with ambient cube support.
func _std_to_acube_material(std_mat: StandardMaterial3D, scale: float) -> ShaderMaterial:
	var smat := ShaderMaterial.new()
	smat.shader = _get_mdl_acube_shader()
	smat.set_shader_parameter("albedo_texture", std_mat.albedo_texture)
	smat.set_shader_parameter("overbright", scale)
	return smat


## Apply overbright scaling and ambient cube shader to MDL model materials.
func _apply_mdl_overbright(node: Node, scale: float) -> void:
	if DisplayServer.get_name() == "headless":
		return
	for child in node.get_children():
		if child is MeshInstance3D:
			var mesh: Mesh = child.mesh
			if not mesh:
				continue
			for surf_idx in mesh.get_surface_count():
				var mat := mesh.surface_get_material(surf_idx)
				if mat is StandardMaterial3D and not _is_emissive_material(mat):
					mesh.surface_set_material(surf_idx, _std_to_acube_material(mat, scale))
			# Also convert skin override materials stored as metadata
			for key in child.get_meta_list():
				if key.begins_with("skin_"):
					var skin_mat = child.get_meta(key)
					if skin_mat is StandardMaterial3D:
						child.set_meta(key, _std_to_acube_material(skin_mat, scale))
		_apply_mdl_overbright(child, scale)


## Load sprite frames: the pck's imported scene, then pre-converted PNGs (sprites the pck lacks),
## then the C++ plugin.
## rel_path is relative to  (e.g. "sprites/fire.spr").
## Returns a dictionary with: textures (Array[ImageTexture]), frame_count, width, height.
## Returns empty dictionary on failure.
func load_sprite(rel_path: String) -> Dictionary:
	rel_path = rel_path.replace("\\", "/").replace("*", "")
	# The pck's own import first: a host on an older build sends its frames to user://, and
	# those must not stand in for the art this build ships.
	if ResourceLoader.exists("res://" + rel_path):
		var packed := _sprite_data_from_scene(load("res://" + rel_path) as PackedScene)
		if not packed.is_empty():
			return packed
	var base_dir := "%s/%s" % [RESOURCE_DIR, rel_path.get_basename()]
	var meta_path := base_dir + "/meta.json"
	if FileAccess.file_exists(meta_path):
		var f := FileAccess.open(meta_path, FileAccess.READ)
		if f:
			var meta = JSON.parse_string(f.get_as_text())
			f.close()
			if meta is Dictionary:
				var textures: Array[ImageTexture] = []
				var frame_count: int = meta.get("frame_count", 0)
				var origins: Array = meta.get("origins", [])
				for i in frame_count:
					var png_path := "%s/%d.png" % [base_dir, i]
					var img := Image.load_from_file(png_path)
					if img:
						textures.append(ImageTexture.create_from_image(img))
				return {
					"textures": textures,
					"frame_count": frame_count,
					"width": meta.get("width", 0),
					"height": meta.get("height", 0),
					"origins": origins,
				}
	# Fallback to C++ plugin (host-only)
	if ClassDB.class_exists(&"GoldSrcSPR"):
		var full_path := "res://" + rel_path
		var spr = ClassDB.instantiate(&"GoldSrcSPR")
		if spr.load_spr(full_path) == OK:
			var textures: Array[ImageTexture] = []
			var frame_count: int = spr.get_frame_count()
			var width := 0
			var height := 0
			var origins: Array = []
			for i in frame_count:
				var tex: Texture2D = spr.get_frame_texture(i)
				if tex:
					if i == 0:
						width = tex.get_width()
						height = tex.get_height()
					# Convert to ImageTexture (no plugin dependency for the texture itself)
					var img := tex.get_image()
					if img:
						textures.append(ImageTexture.create_from_image(img))
				var origin: Vector2i = spr.get_frame_origin(i)
				origins.append([origin.x, origin.y])
			return {
				"textures": textures,
				"frame_count": frame_count,
				"width": width,
				"height": height,
				"origins": origins,
			}
		else:
			push_warning("AssetLoader.load_sprite: failed to load %s" % full_path)
	else:
		push_warning("AssetLoader.load_sprite: no native data and no plugin for %s" % rel_path)
	return {}


## load_sprite()'s dictionary from an imported sprite scene, whose root Sprite3D carries every
## frame and origin as tex_anim_frames / tex_anim_origins metadata. Read from the packed state,
## so nothing is instantiated. Empty when the scene isn't one of those.
static func _sprite_data_from_scene(scene: PackedScene) -> Dictionary:
	var state := scene.get_state() if scene else null
	if state == null or state.get_node_count() == 0:
		return {}
	var frames: Array = []
	var origins: Array = []
	for i in state.get_node_property_count(0):
		match state.get_node_property_name(0, i):
			&"metadata/tex_anim_frames":
				frames = state.get_node_property_value(0, i)
			&"metadata/tex_anim_origins":
				origins = state.get_node_property_value(0, i)
	var textures: Array[ImageTexture] = []
	for t in frames:
		if not t is ImageTexture:
			return {}
		textures.append(t)
	if textures.is_empty():
		return {}
	return {
		"textures": textures,
		"frame_count": textures.size(),
		"width": textures[0].get_width(),
		"height": textures[0].get_height(),
		"origins": origins,
	}


## Load a sprite as a self-animating Sprite3D from a pre-converted .scn.
## The returned node animates its own frames — no Timer needed.
## Falls back to a static Sprite3D from PNG data if no .scn exists.
## Returns null on failure.
func load_sprite_node(rel_path: String) -> Sprite3D:
	rel_path = rel_path.replace("\\", "/").replace("*", "")
	# Try Godot-imported scene (res://sprites/fire.spr → PackedScene via spr_importer)
	var res_path := "res://" + rel_path
	if ResourceLoader.exists(res_path):
		var scene: PackedScene = load(res_path)
		if scene:
			var res_sprite := scene.instantiate() as Sprite3D
			fix_additive_fog(res_sprite)
			return res_sprite
	# Fallback: pre-converted scene in user://resources/ (server deployments)
	var scn_path := "%s/%s.scn" % [RESOURCE_DIR, rel_path.get_basename()]
	if ResourceLoader.exists(scn_path):
		var scene: PackedScene = load(scn_path)
		if scene:
			var scn_sprite := scene.instantiate() as Sprite3D
			fix_additive_fog(scn_sprite)
			return scn_sprite
	# Fallback: static sprite from PNG data (no inline animation)
	var data := load_sprite(rel_path)
	if data.is_empty():
		return null
	var textures: Array = data.get("textures", [])
	if textures.is_empty():
		return null
	var sprite := Sprite3D.new()
	sprite.texture = textures[0]
	return sprite


## Cached first-frame texture of a sprite, for emitters/particles that only need
## a single billboard image. load_sprite() can fall through to re-decoding every
## frame on each call, so this avoids that redundant I/O when many instances
## (e.g. a map full of ww_emitters) share one sprite path. Returns null on failure.
func load_sprite_first_frame(rel_path: String) -> Texture2D:
	var key := "sprite_frame0_%s" % rel_path
	if _material_cache.has(key):
		return _material_cache[key]
	var textures: Array = load_sprite(rel_path).get("textures", [])
	var tex: Texture2D = textures[0] if not textures.is_empty() else null
	_material_cache[key] = tex
	return tex


## Sound aliases (sounds/aliases.txt): one "<alias> <target>" pair per line, both relative
## to sounds/. Lets a single wav answer to every name GoldSrc content spells it by — VOX
## says both "3" and "three" — instead of shipping byte-identical copies. Loaded once, on
## first use, and resolved for one hop only: a target must name a real file.
var _sound_aliases: Dictionary = {}
var _sound_aliases_loaded := false


func resolve_sound_alias(rel_path: String) -> String:
	if not _sound_aliases_loaded:
		_load_sound_aliases()
	return _sound_aliases.get(rel_path.to_lower(), rel_path)


func _load_sound_aliases() -> void:
	_sound_aliases_loaded = true
	for path in ["res://sounds/aliases.txt", RESOURCE_DIR + "/sounds/aliases.txt"]:
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		while not f.eof_reached():
			var line := f.get_line().strip_edges().replace("\t", " ")
			if line.is_empty() or line.begins_with("//"):
				continue
			var parts := line.split(" ", false)
			if parts.size() < 2:
				continue
			_sound_aliases[String(parts[0]).to_lower()] = String(parts[1])
	if not _sound_aliases.is_empty():
		Log.info("[Sounds] %d sound aliases" % _sound_aliases.size())


## Load a sound from res:// (imported) or user://resources/ (cached WAV).
## rel_path is relative to sounds/ (e.g. "ambience/drip1.wav").
func load_sound(rel_path: String) -> AudioStream:
	# Sanitize GoldSrc paths: backslashes -> forward slashes, strip leading '*' (random pitch)
	rel_path = rel_path.replace("\\", "/")
	rel_path = rel_path.replace("*", "")
	rel_path = resolve_sound_alias(rel_path)
	# Try res:// first (Godot-imported)
	var res_path := "sounds/" + rel_path
	if ResourceLoader.exists(res_path):
		return load(res_path)
	# Try cached WAV with runtime loader
	var cache_path := "%s/sounds/%s" % [RESOURCE_DIR, rel_path]
	if FileAccess.file_exists(cache_path):
		return _load_wav_runtime(cache_path)
	push_warning("AssetLoader.load_sound: sound not found '%s'" % rel_path)
	return null


## Load a decal texture from pre-converted PNGs.
func load_decal_texture(tex_name: String) -> ImageTexture:
	var png_path := "%s/decals/%s.png" % [RESOURCE_DIR, tex_name]
	var img := Image.load_from_file(png_path)
	if img:
		return ImageTexture.create_from_image(img)
	return null


## Load a skybox face image from pre-converted PNGs.
func load_sky_image(sky_name: String, suffix: String) -> Image:
	var png_path := "%s/sky/%s/%s.png" % [RESOURCE_DIR, sky_name, suffix]
	return Image.load_from_file(png_path)


## PackedScenes held so ResourceLoader keeps them cached. Without a live reference the
## scene is released and the next load_model() pays the full resource load again — 24ms
## for a wizard model, which lands as a hitch the first time a class is seen mid-match.
var _pinned_scenes := {}


## Keep a model or sprite's PackedScene resident, so later load_model() calls cost an instantiate
## (~1ms) instead of a resource load (~24ms). Mirrors load_model's path resolution.
func pin_model_scene(rel_path: String) -> void:
	if rel_path.is_empty() or _pinned_scenes.has(rel_path):
		return
	rel_path = rel_path.replace("\\", "/").replace("*", "")
	var res_path := "res://" + rel_path
	if ResourceLoader.exists(res_path):
		_pinned_scenes[rel_path] = load(res_path)
		return
	var native_path := "%s/%s.scn" % [RESOURCE_DIR, rel_path.get_basename()]
	if ResourceLoader.exists(native_path):
		_pinned_scenes[rel_path] = load(native_path)


## Stage a model for GPU shader warmup. Collected into the SubViewport by _warm_gpu_shaders.
var _model_warmup_nodes := {}
func precache_model(path: String) -> void:
	if _model_warmup_nodes.has(path):
		return
	# The load is what warms the resource cache; the node exists only to be rendered, so a
	# headless server keeps the load and drops the node instead of orphaning it. The path is
	# recorded either way, so nothing loads twice.
	var m := load_model(path)
	if m:
		if DisplayServer.get_name() == "headless":
			m.free()
			m = null
		else:
			m.scale = Vector3(0.01, 0.01, 0.01)  # tiny so it fits in the warmup viewport
	_model_warmup_nodes[path] = m


## Precache a sprite (loads PNGs into memory).
func precache_sprite(path: String) -> void:
	load_sprite(path)


## Runtime WAV file loader — parses RIFF headers and creates AudioStreamWAV.
func _load_wav_runtime(path: String) -> AudioStreamWAV:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null

	# RIFF header
	var riff := file.get_buffer(4).get_string_from_ascii()
	if riff != "RIFF":
		return null
	var _file_size := file.get_32()
	var wave := file.get_buffer(4).get_string_from_ascii()
	if wave != "WAVE":
		return null

	var format_tag := 0
	var channels := 1
	var sample_rate := 22050
	var bits_per_sample := 16
	var pcm_data := PackedByteArray()

	# Parse chunks
	while file.get_position() < file.get_length():
		var chunk_id := file.get_buffer(4).get_string_from_ascii()
		var chunk_size := file.get_32()
		if chunk_id == "fmt ":
			format_tag = file.get_16()
			channels = file.get_16()
			sample_rate = file.get_32()
			var _byte_rate := file.get_32()
			var _block_align := file.get_16()
			bits_per_sample = file.get_16()
			# Skip extra format bytes
			if chunk_size > 16:
				file.get_buffer(chunk_size - 16)
		elif chunk_id == "data":
			pcm_data = file.get_buffer(chunk_size)
		else:
			file.get_buffer(chunk_size)
		# RIFF chunks are word-aligned: skip pad byte after odd-sized chunks
		if chunk_size % 2 != 0 and file.get_position() < file.get_length():
			file.get_8()

	if format_tag != 1:  # PCM only
		push_warning("AssetLoader._load_wav_runtime: unsupported format %d in %s" % [format_tag, path])
		return null

	# WAV 8-bit is unsigned (0-255, center=128); Godot expects signed (-128..127, center=0)
	if bits_per_sample == 8:
		for i in pcm_data.size():
			pcm_data[i] = (pcm_data[i] + 128) % 256

	var stream := AudioStreamWAV.new()
	stream.data = pcm_data
	stream.mix_rate = sample_rate
	stream.stereo = (channels == 2)
	if bits_per_sample == 8:
		stream.format = AudioStreamWAV.FORMAT_8_BITS
	else:
		stream.format = AudioStreamWAV.FORMAT_16_BITS
	return stream


var _material_cache := {}
var _beam_gradient: ImageTexture  # built once by get_beam_gradient()


## Switch a material to additive blending — always use this instead of setting
## blend_mode directly, because additive surfaces must also opt out of fog.
## Godot fogs a fragment by blending it toward the fog colour
## (color = mix(color, fog_color, fog_amount)) and BLEND_MODE_ADD then *adds* that
## result to the framebuffer over the whole quad, transparent texels included — so
## underwater an additive sprite reads as a glowing rectangle instead of a sprite.
## GoldSrc fogs additive passes toward black, which for an add blend is the same as
## not fogging them at all, so this matches the original renderer.
func set_additive_blend(mat: BaseMaterial3D) -> void:
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.disable_fog = true


## Recursively clear fog on any additive material already baked into a node tree
## (imported .scn sprites, BSP-embedded sprites) — same reason as set_additive_blend().
func fix_additive_fog(node: Node) -> void:
	if node is GeometryInstance3D:
		var gi := node as GeometryInstance3D
		_clear_fog_if_additive(gi.material_override)
		if gi is MeshInstance3D:
			var mi := gi as MeshInstance3D
			for i in mi.get_surface_override_material_count():
				_clear_fog_if_additive(mi.get_surface_override_material(i))
			if mi.mesh:
				for i in mi.mesh.get_surface_count():
					_clear_fog_if_additive(mi.mesh.surface_get_material(i))
	for child in node.get_children():
		fix_additive_fog(child)


func _clear_fog_if_additive(mat: Material) -> void:
	if mat is BaseMaterial3D and (mat as BaseMaterial3D).blend_mode == BaseMaterial3D.BLEND_MODE_ADD:
		(mat as BaseMaterial3D).disable_fog = true


## Where a spell effect sorts in the transparent queue: over decals (1), and over the liquid
## colour pass (0) so a fireball flying above a pool is not blended away by the water behind it.
const EFFECT_PRIORITY := 2


## Move an effect's OWN materials to the far side of the liquid colour pass, or back.
##
## GoldSrc sorted every transparent surface back to front, so a fireball inside a pool was drawn
## before the water and came out dimmed by it. Godot's transparent queue is priority-major, so an
## effect at EFFECT_PRIORITY beats the water from either side of the surface — which is why a
## submerged fireball used to sit on top of ww_hunt's harbour at full strength. Nor can the depth
## buffer settle it: the liquid depth in there is WaterSurfaces' prepass twin, and a depth test
## can only reject a fragment outright, never dim it. So the side is decided per object, by
## whoever knows which side of the surface the effect is on.
##
## Only ever pass materials the caller owns — the shared ones out of this file are on every
## effect in the game at once.
func sort_for_liquid(mats: Array, submerged: bool) -> void:
	var priority := WaterSurfaces.PRIORITY_SUBMERGED if submerged else EFFECT_PRIORITY
	for mat in mats:
		mat.render_priority = priority


## Create an additive-blend, unshaded, vertex-color material for beams/effects.
func create_additive_material(depth_test := true) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	set_additive_blend(mat)
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = not depth_test
	mat.render_priority = EFFECT_PRIORITY
	return mat


## Shared additive beam material (vertex color, cull disabled, depth test on).
## Do NOT modify the returned instance — it is shared.
func get_additive_material() -> StandardMaterial3D:
	if not _material_cache.has("additive"):
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		set_additive_blend(mat)
		mat.vertex_color_use_as_albedo = true
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.no_depth_test = false
		mat.render_priority = EFFECT_PRIORITY
		_material_cache["additive"] = mat
	return _material_cache["additive"]

## Trail material — same as additive, alias for clarity.
func get_trail_material() -> StandardMaterial3D:
	return get_additive_material()


## Cross-section profile for a BeamSystem strip: solid down the middle, fading to nothing at the
## edges. The strip's vertex writer already lays v across the beam's width (beam_system.gd
## write_attr), and until now nothing sampled it — the ribbon was one flat band of colour with cut
## edges. Sampling it turns the band into a core with a soft halo, and lets the core stay at full
## white where the strip's own colour tints only the shoulders, which is what the Environment's
## glow pass can actually find. Uniform along u so a beam tiling its length shows no seam.
func get_beam_gradient() -> ImageTexture:
	if not _beam_gradient:
		var h := 64
		var img := Image.create(4, h, true, Image.FORMAT_RGBA8)
		for y in h:
			var v := (float(y) + 0.5) / h
			var x := 1.0 - absf(v * 2.0 - 1.0)   # 0 at both edges, 1 down the centre
			var a := x * x * (3.0 - 2.0 * x)     # smoothstep: broad core, soft shoulders
			for px in 4:
				img.set_pixel(px, y, Color(1.0, 1.0, 1.0, a))
		img.generate_mipmaps()
		_beam_gradient = ImageTexture.create_from_image(img)
	return _beam_gradient


## Fresh beam material. One-shot beams fade themselves by writing albedo_color, so they cannot
## share the cached one.
func create_beam_material() -> StandardMaterial3D:
	var mat := create_additive_material()
	mat.albedo_texture = get_beam_gradient()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return mat


## Shared beam material (gradient cross-section, additive).
## Do NOT modify the returned instance — it is shared.
func get_beam_material() -> StandardMaterial3D:
	if not _material_cache.has("beam"):
		_material_cache["beam"] = create_beam_material()
	return _material_cache["beam"]

## Template for animated sprite materials — caller must .duplicate() then set albedo_texture.
func get_sprite_material_template(billboard := BaseMaterial3D.BILLBOARD_ENABLED) -> StandardMaterial3D:
	var key := "sprite_template_%d" % billboard
	if not _material_cache.has(key):
		var mat := StandardMaterial3D.new()
		mat.billboard_mode = billboard
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		set_additive_blend(mat)
		mat.no_depth_test = false
		mat.render_priority = EFFECT_PRIORITY
		_material_cache[key] = mat
	return _material_cache[key]

## Cached billboard spark quad mesh with shared material. Safe to share across GPUParticles3D.
func get_spark_quad(size := Vector2(0.15, 0.15)) -> QuadMesh:
	var key := "spark_quad_%s" % str(size)
	if not _material_cache.has(key):
		var quad := QuadMesh.new()
		quad.size = size
		var mat := StandardMaterial3D.new()
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		set_additive_blend(mat)
		mat.vertex_color_use_as_albedo = true
		mat.render_priority = EFFECT_PRIORITY
		quad.material = mat
		_material_cache[key] = quad
	return _material_cache[key]

## What a liquid's droplets are coloured, keyed by the particle type SplashEffect asks for.
const SPLASH_TINTS := {
	"splash_water": Color(0.7, 0.9, 1.0),
	"splash_slime": Color(0.6, 1.0, 0.4),
	"splash_lava": Color(1.0, 0.6, 0.2),
}

## Per-effect-type particle process materials. Never modified — safe to share.
func get_spark_particle_material(effect_type: String) -> ParticleProcessMaterial:
	var key := "spark_pm_%s" % effect_type
	if not _material_cache.has(key):
		_material_cache[key] = _create_spark_particle_material(effect_type)
	return _material_cache[key]

func _create_spark_particle_material(effect_type: String) -> ParticleProcessMaterial:
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 180.0
	# Each ramp sets both ends before its middle stops: add_point re-sorts, so index 1 is only
	# the end stop until the first one goes in.
	var gradient := Gradient.new()
	match effect_type:
		"spotbolt":
			mat.initial_velocity_min = 3.0
			mat.initial_velocity_max = 8.0
			mat.gravity = Vector3(0, -6.0, 0)
			mat.damping_min = 1.0
			mat.damping_max = 3.0
			mat.scale_min = 0.4
			mat.scale_max = 1.0
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(1.0, 1.0, 0.8, 1.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(0.5, 0.2, 0.05, 0.0))
			gradient.add_point(0.3, Color(1.0, 0.9, 0.3, 1.0))
			gradient.add_point(0.6, Color(1.0, 0.6, 0.1, 0.8))
		"lightning":
			mat.initial_velocity_min = 2.0
			mat.initial_velocity_max = 6.0
			mat.gravity = Vector3(0, -4.0, 0)
			mat.damping_min = 1.0
			mat.damping_max = 3.0
			mat.scale_min = 0.2
			mat.scale_max = 0.6
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(0.3, 0.4, 0.8, 0.0))
			gradient.add_point(0.3, Color(0.8, 0.9, 1.0, 1.0))
			gradient.add_point(0.6, Color(0.5, 0.7, 1.0, 0.8))
		"freezeray":
			mat.initial_velocity_min = 1.0
			mat.initial_velocity_max = 3.0
			mat.gravity = Vector3(0, -2.0, 0)
			mat.damping_min = 1.0
			mat.damping_max = 2.0
			mat.scale_min = 0.1
			mat.scale_max = 0.3
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(0.8, 0.9, 1.0, 1.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(0.2, 0.4, 0.9, 0.0))
			gradient.add_point(0.4, Color(0.4, 0.7, 1.0, 0.9))
		"deathray":
			mat.initial_velocity_min = 1.0
			mat.initial_velocity_max = 3.0
			mat.gravity = Vector3(0, -2.0, 0)
			mat.damping_min = 1.0
			mat.damping_max = 2.0
			mat.scale_min = 0.1
			mat.scale_max = 0.3
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(1.0, 0.6, 0.6, 1.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(0.4, 0.0, 0.0, 0.0))
			gradient.add_point(0.4, Color(0.8, 0.2, 0.2, 0.9))
		"liferay":
			mat.initial_velocity_min = 1.0
			mat.initial_velocity_max = 3.0
			mat.gravity = Vector3(0, -2.0, 0)
			mat.damping_min = 1.0
			mat.damping_max = 2.0
			mat.scale_min = 0.1
			mat.scale_max = 0.3
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(0.8, 1.0, 0.8, 1.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(0.1, 0.4, 0.2, 0.0))
			gradient.add_point(0.4, Color(0.3, 0.8, 0.5, 0.9))
		"lifesatchel":
			mat.initial_velocity_min = 3.0
			mat.initial_velocity_max = 7.0
			mat.gravity = Vector3(0, 1.0, 0)
			mat.damping_min = 3.0
			mat.damping_max = 6.0
			mat.scale_min = 0.4
			mat.scale_max = 1.0
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(0.1, 0.5, 0.2, 0.0))
			gradient.add_point(0.35, Color(0.7, 1.0, 0.7, 1.0))
			gradient.add_point(0.7, Color(0.3, 0.9, 0.45, 0.7))
		"lifering":
			# Flat sweep out to the satchel's blast radius: v^2 / (2 * damping) = 3.2 m.
			mat.direction = Vector3(1, 0, 0)
			mat.flatness = 1.0
			mat.initial_velocity_min = 8.0
			mat.initial_velocity_max = 8.0
			mat.gravity = Vector3.ZERO
			mat.damping_min = 10.0
			mat.damping_max = 10.0
			mat.scale_min = 0.6
			mat.scale_max = 1.0
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(0.9, 1.0, 0.9, 1.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(0.3, 0.9, 0.4, 0.0))
			gradient.add_point(0.6, Color(0.6, 1.0, 0.7, 0.8))
		"lifemote":
			# Slow motes rising through the blast radius, fading in and out.
			mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
			mat.emission_sphere_radius = 1.6
			mat.initial_velocity_min = 0.1
			mat.initial_velocity_max = 0.6
			mat.gravity = Vector3(0, 1.2, 0)
			mat.damping_min = 0.0
			mat.damping_max = 0.5
			mat.scale_min = 0.5
			mat.scale_max = 1.2
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(0.8, 1.0, 0.8, 0.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(0.2, 0.7, 0.3, 0.0))
			gradient.add_point(0.15, Color(0.9, 1.0, 0.85, 1.0))
			gradient.add_point(0.6, Color(0.5, 1.0, 0.6, 0.8))
		"windgust":
			# Flat sweep out over the knockback radius: v^2 / (2 * damping) = 3.4 m.
			mat.direction = Vector3(1, 0, 0)
			mat.flatness = 1.0
			mat.initial_velocity_min = 11.0
			mat.initial_velocity_max = 12.0
			mat.gravity = Vector3.ZERO
			mat.damping_min = 18.0
			mat.damping_max = 20.0
			mat.scale_min = 0.5
			mat.scale_max = 1.0
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(0.6, 0.4, 1.0, 0.0))
			gradient.add_point(0.6, Color(0.85, 0.75, 1.0, 1.0))
		"windswirl":
			# A vortex: lifted off a ring at the blast and spun round it as it climbs.
			mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
			mat.emission_ring_axis = Vector3(0, 1, 0)
			mat.emission_ring_radius = 2.2
			mat.emission_ring_inner_radius = 1.4
			mat.emission_ring_height = 0.2
			mat.spread = 15.0
			mat.initial_velocity_min = 0.8
			mat.initial_velocity_max = 1.6
			mat.orbit_velocity_min = 0.5
			mat.orbit_velocity_max = 0.8
			mat.gravity = Vector3(0, 1.2, 0)
			mat.damping_min = 0.5
			mat.damping_max = 1.0
			mat.scale_min = 0.5
			mat.scale_max = 1.0
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(0.9, 0.85, 1.0, 0.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(0.55, 0.35, 0.9, 0.0))
			gradient.add_point(0.15, Color(0.95, 0.9, 1.0, 1.0))
			gradient.add_point(0.6, Color(0.75, 0.6, 1.0, 0.9))
		"necrosplash":
			# Toxic droplets thrown up out of the smoke and raining back down.
			mat.spread = 50.0
			mat.initial_velocity_min = 3.0
			mat.initial_velocity_max = 6.5
			mat.gravity = Vector3(0, -12.0, 0)
			mat.damping_min = 0.0
			mat.damping_max = 0.5
			mat.scale_min = 0.5
			mat.scale_max = 1.2
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(0.7, 1.0, 0.5, 1.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(0.05, 0.3, 0.05, 0.0))
			gradient.add_point(0.4, Color(0.3, 0.9, 0.2, 0.9))
		"necrowisp":
			# Slow wisps seeping up through the blast radius, fading in and out.
			mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
			mat.emission_sphere_radius = 1.4
			mat.initial_velocity_min = 0.2
			mat.initial_velocity_max = 0.8
			mat.gravity = Vector3(0, 1.0, 0)
			mat.damping_min = 0.5
			mat.damping_max = 1.0
			mat.scale_min = 0.6
			mat.scale_max = 1.3
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(0.4, 1.0, 0.3, 0.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(0.05, 0.3, 0.05, 0.0))
			gradient.add_point(0.2, Color(0.6, 1.0, 0.4, 1.0))
			gradient.add_point(0.7, Color(0.3, 0.85, 0.2, 0.8))
		"iceshard":
			mat.initial_velocity_min = 1.5
			mat.initial_velocity_max = 5.0
			mat.gravity = Vector3(0, -3.0, 0)
			mat.damping_min = 1.0
			mat.damping_max = 3.0
			mat.scale_min = 0.15
			mat.scale_max = 0.5
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(0.9, 0.95, 1.0, 1.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(0.1, 0.3, 0.8, 0.0))
			gradient.add_point(0.3, Color(0.5, 0.8, 1.0, 1.0))
			gradient.add_point(0.6, Color(0.3, 0.6, 1.0, 0.8))
		"splash_water", "splash_slime", "splash_lava":
			# Droplets, not sparks: thrown up in a tight cone and pulled straight back down.
			mat.spread = 32.0
			mat.initial_velocity_min = 2.0
			mat.initial_velocity_max = 5.5
			mat.gravity = Vector3(0, -14.0, 0)
			mat.damping_min = 0.0
			mat.damping_max = 0.5
			mat.scale_min = 0.3
			mat.scale_max = 1.0
			var tint := SPLASH_TINTS.get(effect_type, Color.WHITE) as Color
			gradient.set_offset(0, 0.0)
			gradient.set_color(0, Color(tint, 1.0))
			gradient.set_offset(1, 1.0)
			gradient.set_color(1, Color(tint, 0.0))
			gradient.add_point(0.6, Color(tint, 0.7))
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	mat.color_ramp = ramp
	return mat


## Apply additive overrides to all mesh surfaces, caching per source material.
## Uses set_surface_override_material so the original mesh materials stay untouched.
func apply_additive_overrides(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			var m: Mesh = child.mesh
			if m:
				for surf_idx in m.get_surface_count():
					var mat := m.surface_get_material(surf_idx)
					if mat is StandardMaterial3D:
						var key := "additive_override_%d" % mat.get_rid().get_id()
						if not _material_cache.has(key):
							var dup := mat.duplicate() as StandardMaterial3D
							dup.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
							set_additive_blend(dup)
							dup.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
							_material_cache[key] = dup
						child.set_surface_override_material(surf_idx, _material_cache[key])
		apply_additive_overrides(child)


## Precache all weapon/effect resources so the first shot has no hitch.
## Call once after map load. Uses a SubViewport to force GPU shader compilation
## (Godot 4.3 frustum-culls off-camera objects, so a SubViewport with its own
## camera is needed to actually render warmup geometry).
func precache_resources(scene_root: Node) -> void:
	var count := 0
	for element in GameConsts.Element.values():
		var wizard := Wizard.create(element)
		for w in wizard.weapons:
			_precache_weapon(w)
			count += 1
		# The combo spells belong to no class, so nothing else would ever warm them — and a
		# spellbook is found mid-match, the worst moment to pay for a model and its shaders.
		for w in wizard.pickup_weapons():
			_precache_weapon(w)
			count += 1
		_precache_player_class(GameConsts.ELEMENT_NAMES[element])
	_precache_player_class("bear")  # earth wizard morph
	# Call-for-help: a sprite and five voice lines nothing else in the game touches, so without
	# this the first Z of a match loads them mid-frame.
	pin_model_scene(Player.HELP_SPRITE)  # load_sprite_node resolves a .spr by the same two paths
	for sound_path in Player.HELP_SOUNDS + Player.HELP_POISON_SOUNDS:
		SoundSystem.precache(sound_path)
	# A death goes one of two ways and both cost a first load: the cry a corpse falls with, or
	# the flesh gibs and the squelch of one that comes apart instead of falling.
	pin_model_scene(GibEffect.model_for_material(GibEffect.MAT_FLESH))
	for sound_path in TumblingCorpse.DEATH_SOUNDS + [GibEffect.FLESH_BURST_SOUND]:
		SoundSystem.precache(sound_path)
	# Satchels aren't weapons, so nothing above reaches them.
	Satchel.precache()
	_warm_gpu_shaders(scene_root)
	Log.info("Precached resources for %d weapons and %d player classes" % [
		count, GameConsts.Element.values().size() + 1])


func _precache_weapon(w: Weapon) -> void:
	w.precache()
	pin_model_scene(w.hand_model_path)


## Warm both first-sighting costs of a player class: the PackedScene load and the stripped
## attack AnimationLibrary. Paid here during map load instead of mid-match, where the pair
## measured 54-64ms and showed up as a frame spike.
func _precache_player_class(element_name: String) -> void:
	var model_path := "models/player/%s.mdl" % element_name
	pin_model_scene(model_path)
	var model := load_model(model_path)
	if model == null:
		return
	var anim := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if anim:
		BoneUtil.get_attack_animation_library(element_name, anim)
	model.free()
	precache_model(model_path)


## Render every cached material, model, and effect through a SubViewport that mirrors
## the gameplay viewport's render settings and environment, forcing the GPU to compile
## the exact shader variants (and upload the textures/meshes) the first shot will use.
## A bare warmup viewport compiles the wrong variant of the lit ambient-cube model
## shader and never touches the additive trail pipeline, so each new weapon still
## re-compiled on first fire. Matching the real env + a dynamic light fixes that.
func _warm_gpu_shaders(scene_root: Node) -> void:
	if DisplayServer.get_name() == "headless":
		_model_warmup_nodes.clear()
		return

	var vp := SubViewport.new()
	vp.size = Vector2i(64, 64)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d = true  # isolated world so our env/light apply without touching gameplay

	# Mirror the main viewport's render settings so compiled pipelines match the
	# framebuffer format / specialization the gameplay scene draws into.
	var main_vp := scene_root.get_viewport()
	if main_vp:
		vp.msaa_3d = main_vp.msaa_3d
		vp.screen_space_aa = main_vp.screen_space_aa
		vp.use_hdr_2d = main_vp.use_hdr_2d

	# Reuse the gameplay Environment resource so scene-global shader defines
	# (ambient source, fog, etc.) match exactly — otherwise the model shader's
	# variant differs and recompiles on first real draw.
	var world_env := scene_root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if world_env and world_env.environment:
		var we := WorldEnvironment.new()
		we.environment = world_env.environment
		vp.add_child(we)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 2)
	vp.add_child(cam)

	# Projectiles light themselves with a dynamic OmniLight3D (projectile.gd), so the
	# lit variant of the model shader must compile here, not on first fire.
	var light := OmniLight3D.new()
	light.position = Vector3(0, 0, 1)
	light.omni_range = 4.0
	light.omni_attenuation = 1.5
	light.shadow_enabled = false
	light.light_cull_mask = GameConsts.LIGHT_CULL_ALL
	vp.add_child(light)

	var warmup_quad := QuadMesh.new()
	for key in _material_cache:
		var res = _material_cache[key]
		if res is QuadMesh:
			var mi := MeshInstance3D.new()
			mi.mesh = res
			vp.add_child(mi)
		elif res is StandardMaterial3D:
			var mi := MeshInstance3D.new()
			mi.mesh = warmup_quad
			mi.material_override = res
			vp.add_child(mi)
		elif res is ParticleProcessMaterial:
			var particles := GPUParticles3D.new()
			particles.amount = 1
			particles.lifetime = 0.1
			particles.one_shot = true
			particles.explosiveness = 1.0
			particles.process_material = res
			particles.draw_pass_1 = get_spark_quad()
			particles.emitting = true
			vp.add_child(particles)

	# Warm the ribbon-trail pipeline by driving a real TrailFader: its _ready assigns the
	# shared additive material and _rebuild emits the triangle-strip, so the warmed pipeline
	# always matches the runtime one instead of a hand-copied draw signature that can drift.
	var trail := TrailFader.new()
	vp.add_child(trail)
	trail.add_point(Vector3(0.0, 0.0, 0.0))
	trail.add_point(Vector3(0.1, 0.0, 0.0))
	trail.add_point(Vector3(0.2, 0.0, 0.0))

	# Anything drawn see-through — a tornado, a fading corpse — runs the fade variant of the model
	# shader, a pipeline an opaque draw never compiles, so each staged model is warmed both ways.
	for key in _model_warmup_nodes:
		var staged: Node3D = _model_warmup_nodes[key]
		if staged == null:
			continue
		var faded := staged.duplicate()
		vp.add_child(staged)
		vp.add_child(faded)
		set_model_alpha(faded, 0.5)
	_model_warmup_nodes.clear()

	scene_root.add_child(vp)
	# Keep alive a few frames so every pass (incl. one-shot particles) actually draws.
	scene_root.get_tree().create_timer(0.3).timeout.connect(vp.queue_free)
