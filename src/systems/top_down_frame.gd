extends RefCounted
## The one definition of "a map seen from straight above", shared by everything that films one.
##
## Two things frame a map this way — tools/map_top.gd for a static backdrop and
## systems/top_view_recorder.gd for live frames — and tools/match_gif.py overlays markers on
## either using the `meta` dict below. The camera placement and that dict therefore have to agree
## exactly: a backdrop framed even slightly differently from the transform it publishes puts
## every marker in the wrong place, and the failure is silent. So neither caller writes its own.
##
## Orthographic on purpose: it makes world -> pixel a plain linear map the compositor can apply
## without knowing anything about the camera.

const PAD := 2.0            # metres of margin around the map bounds
## Fraction of the map's height cut off the top. Whatever is above the camera is behind it and
## simply not drawn, which is how the roof comes off; a map's top quarter is sky and ceiling
## brushes. Callers take a per-map override for the maps this guess is wrong for.
const ROOF_CUT := 0.22


## Box, square span, centre and cut height for `box`. Squared because the compositor assumes one
## pixel scale on both axes.
static func frame(raw: AABB, cut_override := INF) -> Dictionary:
	var box := raw.grow(PAD)
	var cut: float = box.end.y - box.size.y * ROOF_CUT if cut_override == INF else cut_override
	return {
		"box": box,
		"span": maxf(box.size.x, box.size.z),
		"mid": box.get_center(),
		"cut": cut,
	}


## The camera that framing describes, looking straight down from the cut height.
static func make_camera(f: Dictionary) -> Camera3D:
	var box: AABB = f["box"]
	var mid: Vector3 = f["mid"]
	var cut: float = f["cut"]
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = f["span"]
	cam.near = 0.05
	cam.far = cut - box.position.y + 20.0
	cam.position = Vector3(mid.x, cut, mid.z)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	return cam


## The world -> pixel contract the compositor reads. World +X runs LEFT across the image at this
## orientation, so the note spells the mapping out rather than making the reader rediscover it.
static func meta(map_name: String, pixels: int, f: Dictionary) -> Dictionary:
	var box: AABB = f["box"]
	var mid: Vector3 = f["mid"]
	var span: float = f["span"]
	return {
		"map": map_name, "pixels": pixels, "span_m": span,
		"centre": [mid.x, mid.z], "y_range": [box.position.y, box.end.y],
		"note": "px = pixels/2 + (world.x - cx) * scale ; py = pixels/2 + (world.z - cz) * scale",
		"scale_px_per_m": float(pixels) / span,
		"cut_y": f["cut"],
	}


## World-space AABB of everything drawn under `root`.
static func world_aabb(root: Node) -> AABB:
	var box := AABB()
	var seeded := false
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is MeshInstance3D) or (n as MeshInstance3D).mesh == null:
			continue
		var mi := n as MeshInstance3D
		var b: AABB = mi.global_transform * mi.mesh.get_aabb()
		box = b if not seeded else box.merge(b)
		seeded = true
	return box
