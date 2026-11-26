class_name HolidayProps
extends RefCounted
## Procedural harvest props, vertex-coloured over a detail layer, metres, standing on y = 0 at the
## origin. Each takes the builder, the transform it lands under, the rng and its size.

## Layers of models/holiday/detail.png, drawn by tools/holiday_art.py (same order).
enum { LAYER_PLAIN, LAYER_PUMPKIN, LAYER_GOURD, LAYER_KERNEL, LAYER_HUSK, LAYER_WICKER, LAYER_STEM, LAYER_APPLE,
		LAYER_NEEDLES, LAYER_SNOW, LAYER_PAPER_DOTS, LAYER_PAPER_STRIPES, LAYER_CANDY, LAYER_BARK }
const DETAIL_PATH := "res://models/holiday/detail.png"

const _ORANGES: Array[Color] = [Color(0.93, 0.45, 0.08), Color(0.85, 0.37, 0.05),
		Color(0.96, 0.56, 0.16), Color(0.80, 0.31, 0.06)]
const _WHITE_PUMPKIN := Color(0.90, 0.87, 0.78)
const _GREY_PUMPKIN := Color(0.52, 0.60, 0.56)
const _STEM := Color(0.42, 0.38, 0.20)
const _GOURD_COLORS: Array[Color] = [Color(0.95, 0.80, 0.20), Color(0.25, 0.45, 0.15),
		Color(0.93, 0.88, 0.70), Color(0.95, 0.58, 0.16), Color(0.55, 0.62, 0.20)]
const _KERNELS: Array[Color] = [Color(0.55, 0.08, 0.08), Color(0.35, 0.05, 0.12),
		Color(0.28, 0.12, 0.38), Color(0.14, 0.11, 0.24), Color(0.92, 0.74, 0.25),
		Color(0.95, 0.90, 0.75), Color(0.86, 0.45, 0.12)]
const _HUSK := Color(0.86, 0.77, 0.52)
const _COB := Color(0.30, 0.22, 0.14)
const _WICKER_LIGHT := Color(0.66, 0.48, 0.26)
const _WICKER_DARK := Color(0.47, 0.32, 0.16)
const _FIR := Color(0.13, 0.33, 0.16)
const _PAPERS: Array[Color] = [Color(0.72, 0.08, 0.08), Color(0.10, 0.42, 0.20), Color(0.14, 0.24, 0.58),
		Color(0.85, 0.68, 0.20), Color(0.88, 0.88, 0.86), Color(0.45, 0.12, 0.40)]
const _RIBBONS: Array[Color] = [Color(0.95, 0.80, 0.30), Color(0.95, 0.95, 0.92), Color(0.75, 0.06, 0.08),
		Color(0.12, 0.45, 0.20), Color(0.78, 0.80, 0.84)]
const _BAUBLES: Array[Color] = [Color(0.80, 0.06, 0.06), Color(0.95, 0.75, 0.25), Color(0.15, 0.30, 0.80),
		Color(0.85, 0.86, 0.90), Color(0.55, 0.10, 0.55)]
const _BULBS: Array[Color] = [Color(1.0, 0.85, 0.45, 0.0), Color(1.0, 0.25, 0.2, 0.0), Color(0.3, 1.0, 0.35, 0.0),
		Color(0.35, 0.55, 1.0, 0.0), Color(1.0, 0.8, 0.2, 0.0)]
const _SNOW := Color(0.95, 0.96, 1.0)
const _COAL := Color(0.08, 0.07, 0.07)


## Triangles under a transform; normals come from the faces once everything is in.
class Geo:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var layers := PackedVector2Array()  # UV2: x the detail layer, y the prop
	var prop := 0  # what is built from here on belongs to this prop (bit `prop` of `popped`)
	var indices := PackedInt32Array()
	var seams := PackedInt32Array()  # pairs of vertices at one point, to share a normal

	## (rows + 1) rings of cols + 1 points; with `wraps` the last column closes the surface on the
	## first, at u = rep.x. Faces point out of a surface whose rows climb its axis and whose columns
	## turn from +X toward +Z. The detail layer repeats rep times across it.
	func grid(xf: Transform3D, rows: int, cols: int, wraps: bool, point: Callable, color: Callable,
			reverse := false, layer := LAYER_PLAIN, rep := Vector2.ONE) -> void:
		var base := verts.size()
		var width := cols + 1
		for i in rows + 1:
			for j in width:
				verts.append(xf * (point.call(i, j) as Vector3))
				colors.append(color.call(i, j % cols if wraps else j))
				uvs.append(Vector2(float(j) / cols * rep.x, float(i) / rows * rep.y))
				layers.append(Vector2(layer, prop))
			if wraps:
				seams.append_array([base + i * width, base + i * width + cols])
		for i in rows:
			for j in cols:
				var a := base + i * width + j
				var b := a + 1
				var c := a + width
				var d := b + width
				if reverse:
					indices.append_array([a, c, b, b, c, d])
				else:
					indices.append_array([a, b, c, b, d, c])

	## One face from its four corners, in grid order: p00 -> p01 runs u, p00 -> p10 runs v.
	func quad(xf: Transform3D, p00: Vector3, p01: Vector3, p10: Vector3, p11: Vector3, color: Color,
			reverse := false, layer := LAYER_PLAIN, rep := Vector2.ONE) -> void:
		var a := verts.size()
		for k in 4:
			colors.append(color)
			layers.append(Vector2(layer, prop))
		verts.append_array([xf * p00, xf * p01, xf * p10, xf * p11])
		uvs.append_array([Vector2.ZERO, Vector2(rep.x, 0), Vector2(0, rep.y), rep])
		if reverse:
			indices.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
		else:
			indices.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])

	func append(other: Geo, xf: Transform3D) -> void:
		var base := verts.size()
		for v in other.verts:
			verts.append(xf * v)
		colors.append_array(other.colors)
		uvs.append_array(other.uvs)
		for l in other.layers:
			layers.append(Vector2(l.x, prop))
		for i in other.indices:
			indices.append(base + i)
		for i in other.seams:
			seams.append(base + i)

	func lowest() -> float:
		var low := INF
		for v in verts:
			low = minf(low, v.y)
		return low

	func is_empty() -> bool:
		return indices.is_empty()

	func normals() -> PackedVector3Array:
		var out := PackedVector3Array()
		out.resize(verts.size())
		for t in range(0, indices.size(), 3):
			var a := verts[indices[t]]
			var n := (verts[indices[t + 2]] - a).cross(verts[indices[t + 1]] - a)
			for k in 3:
				out[indices[t + k]] += n
		for k in range(0, seams.size(), 2):
			var shared := out[seams[k]] + out[seams[k + 1]]
			out[seams[k]] = shared
			out[seams[k + 1]] = shared
		for i in out.size():
			out[i] = out[i].normalized() if out[i].length_squared() > 0.0 else Vector3.UP
		return out

	func to_mesh() -> ArrayMesh:
		var mesh := ArrayMesh.new()
		add_to(mesh)
		return mesh

	## This geometry as one more surface of `mesh`.
	func add_to(mesh: ArrayMesh) -> void:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals()
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_TEX_UV2] = layers
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


## The detail strip as a texture array, one layer per square. Built once.
static var _detail: Texture2DArray


static func detail_texture() -> Texture2DArray:
	if _detail == null:
		var strip := (load(DETAIL_PATH) as Texture2D).get_image()
		strip.decompress()
		strip.convert(Image.FORMAT_RGBA8)
		var size := strip.get_height()
		var images: Array[Image] = []
		for k in floori(float(strip.get_width()) / size):
			var layer := strip.get_region(Rect2i(k * size, 0, size, size))
			layer.generate_mipmaps()
			images.append(layer)
		_detail = Texture2DArray.new()
		_detail.create_from_images(images)
	return _detail


## Prop `kind` from a HolidayDecor record, at `xf`; `seed` makes it the same on every peer.
static func build(g: Geo, xf: Transform3D, kind: String, size: float, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	match kind:
		"corn": _leaning(g, xf, rng, size, 3, 0.28, corn_ear)
		"canes": _leaning(g, xf, rng, size, 2, 0.6, candy_cane)
		_:
			var make: Callable = {"pumpkin": _pumpkin, "gourd": _gourd, "cornucopia": _cornucopia,
				"tree": _tree, "present": _present, "snowman": _snowman}[kind]
			_place(g, xf, make, rng, size)


## `count` of something long (an ear of corn, a candy cane) standing on its end and leaning back
## toward -Z (the wall), fanned `spread` radians apart.
static func _leaning(g: Geo, foot: Transform3D, rng: RandomNumberGenerator, length: float,
		count: int, spread: float, make: Callable) -> void:
	var lean := atan2(0.16, length * 0.95)
	for k in count:
		var fan := (k - (count - 1) * 0.5) * spread + rng.randf_range(-0.08, 0.08)
		var spin := rng.randf() * TAU if count > 2 else rng.randf_range(-0.4, 0.4) + PI * k  # canes hook apart
		var b := Basis(Vector3.RIGHT, -lean) * Basis(Vector3.BACK, fan * 0.5) * Basis(Vector3.UP, spin)
		make.call(g, foot * Transform3D(b, Vector3((k - (count - 1) * 0.5) * 0.05, 0.01, rng.randf_range(-0.02, 0.02))),
				rng, length * rng.randf_range(0.9, 1.05))


## A builder's prop made at the origin, then set down at `xf` with its lowest point on the floor.
static func _place(g: Geo, xf: Transform3D, make: Callable, rng: RandomNumberGenerator, size: float) -> void:
	var local := Geo.new()
	make.call(local, Transform3D.IDENTITY, rng, size)
	if not local.is_empty():
		g.append(local, xf * Transform3D(Basis.IDENTITY, Vector3(0, -local.lowest(), 0)))


static func _jitter(rng: RandomNumberGenerator, c: Color, amount := 0.06) -> Color:
	var k := 1.0 + rng.randf_range(-amount, amount)
	return Color(clampf(c.r * k, 0, 1), clampf(c.g * k, 0, 1), clampf(c.b * k, 0, 1))


## A surface of revolution about +Y: profile(t) is (radius, height) from the bottom pole, t 0..1.
static func _lathe(g: Geo, xf: Transform3D, rows: int, cols: int, profile: Callable,
		color: Callable, radial := Callable(), layer := LAYER_PLAIN, rep := Vector2.ONE) -> void:
	g.grid(xf, rows, cols, true, func(i: int, j: int) -> Vector3:
		var t := float(i) / rows
		var a := TAU * j / cols
		var p: Vector2 = profile.call(t)
		var r: float = p.x * (radial.call(t, a) if radial.is_valid() else 1.0)
		return Vector3(r * cos(a), p.y, r * sin(a)),
		func(i: int, j: int) -> Color: return color.call(float(i) / rows, TAU * j / cols), false, layer, rep)


static func _sphere(g: Geo, xf: Transform3D, radius: float, color: Color, rows := 6, cols := 8,
		layer := LAYER_PLAIN) -> void:
	_lathe(g, xf, rows, cols, func(t: float) -> Vector2:
		return Vector2(sin(t * PI), -cos(t * PI) + 1.0) * radius,
		func(_t: float, _a: float) -> Color: return color, Callable(), layer, Vector2(2, 1))


## A ring about +Y: tube radius `r` round a circle of radius `big`, lying flat.
static func _torus(g: Geo, xf: Transform3D, big: float, r: float, color: Color, layer := LAYER_PLAIN,
		rep := Vector2(4, 1)) -> void:
	_lathe(g, xf, 8, 16, func(t: float) -> Vector2:
		return Vector2(big + r * cos(t * TAU), r * sin(t * TAU)),
		func(_t: float, _a: float) -> Color: return color, Callable(), layer, Vector2(rep.y, rep.x))


## One flat face round `centre`, half-extents `hu` (u) and `hv` (v), facing `out`.
static func _quad(g: Geo, xf: Transform3D, centre: Vector3, out: Vector3, hu: Vector3, hv: Vector3,
		color: Color, layer := LAYER_PLAIN, rep := Vector2.ONE) -> void:
	g.quad(xf, centre - hu - hv, centre + hu - hv, centre - hu + hv, centre + hu + hv, color,
		hv.cross(hu).dot(out) < 0.0, layer, rep)


## A tube down a spine that bends in the XY plane: radius(i) at spine[i], `cols` round it.
static func _tube(g: Geo, xf: Transform3D, spine: Array[Vector3], tangent: Array[Vector3], radius: Callable,
		cols: int, color: Callable, reverse := false, layer := LAYER_PLAIN, rep := Vector2.ONE) -> void:
	g.grid(xf, spine.size() - 1, cols, true, func(i: int, j: int) -> Vector3:
		var t := tangent[i]
		var n := Vector3(-t.y, t.x, 0)
		var a := TAU * j / cols
		return spine[i] + (n * cos(a) + n.cross(t) * sin(a)) * (radius.call(i) as float),
		color, reverse, layer, rep)


## A tapered, bent stalk up from the origin.
static func _stem(g: Geo, xf: Transform3D, rng: RandomNumberGenerator, length: float, radius: float) -> void:
	var bend := Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized() * length * 0.4
	var col := _jitter(rng, _STEM, 0.12)
	g.grid(xf, 3, 6, true, func(i: int, j: int) -> Vector3:
		var t := i / 3.0
		var a := TAU * j / 6
		var r := radius * (1.0 - 0.45 * t) * (1.0 + 0.15 * cos(a * 3.0))
		return Vector3(r * cos(a), t * length, r * sin(a)) + bend * t * t,
		func(i: int, _j: int) -> Color: return col.darkened(0.25 * i / 3.0), false, LAYER_STEM, Vector2(1, 0.5))


## radius 0.2..0.4.
static func _pumpkin(g: Geo, xf: Transform3D, rng: RandomNumberGenerator, radius: float) -> void:
	var height := radius * rng.randf_range(0.62, 0.9)
	var lobes := rng.randi_range(8, 12)
	var dip := height * 0.22
	var roll := rng.randf()
	var base := (_WHITE_PUMPKIN if roll < 0.1 else (_GREY_PUMPKIN if roll < 0.15
			else _ORANGES[rng.randi() % _ORANGES.size()]))
	base = _jitter(rng, base)
	var groove := func(a: float) -> float:
		return 1.0 - pow(absf(sin(lobes * a * 0.5)), 0.4)
	_lathe(g, xf, 12, lobes * 4,
		func(t: float) -> Vector2:
			var phi := t * PI
			var s := sin(phi)
			var y := -cos(phi) * height * 0.5 + height * 0.5
			y += (dip if t < 0.5 else -dip) * pow(1.0 - s, 2.0)
			return Vector2(radius * s, y),
		func(t: float, a: float) -> Color:
			# Darker in the grooves and underneath, not on top: the top is what everyone sees.
			var shade: float = 1.0 - 0.26 * groove.call(a) * (0.6 + 0.4 * sin(t * PI)) \
					- (0.18 * (1.0 - sin(t * PI)) if t < 0.5 else 0.0)
			return Color(base.r * shade, base.g * shade, base.b * shade),
		func(t: float, a: float) -> float:
			return 1.0 - 0.09 * groove.call(a) * sin(t * PI),
		LAYER_PUMPKIN, Vector2(lobes * 0.5, 1.5))
	_stem(g, xf * Transform3D(Basis.IDENTITY, Vector3(0, height - dip - 0.01, 0)), rng,
			radius * rng.randf_range(0.25, 0.45), radius * 0.1)


## Footprint about 0.08..0.14 across, upright or lying on its side.
static func _gourd(g: Geo, xf: Transform3D, rng: RandomNumberGenerator, size: float) -> void:
	var kind := rng.randi() % 3
	var c1 := _jitter(rng, _GOURD_COLORS[rng.randi() % _GOURD_COLORS.size()])
	var c2 := _jitter(rng, _GOURD_COLORS[rng.randi() % _GOURD_COLORS.size()])
	var stripes := rng.randi_range(5, 9) if rng.randf() < 0.5 else 0
	var color := func(t: float, a: float) -> Color:
		var c: Color = c1.lerp(c2, smoothstep(0.35, 0.65, t))
		if stripes > 0 and sin(a * stripes) > 0.55:
			c = c.lerp(Color(0.95, 0.92, 0.75), 0.6)
		return c
	if kind == 0:  # round, a little squashed
		var h := size * rng.randf_range(0.75, 0.95)
		_lathe(g, xf, 8, 12, func(t: float) -> Vector2:
			return Vector2(sin(t * PI) * size * 0.5, (1.0 - cos(t * PI)) * h * 0.5),
			color, Callable(), LAYER_GOURD, Vector2(1, 0.5))
		_stem(g, xf * Transform3D(Basis.IDENTITY, Vector3(0, h - 0.005, 0)), rng, size * 0.25, size * 0.07)
		return
	# Bottle or pear: a bulb with a neck, laid down on its side as often as not.
	var length := size * (1.8 if kind == 1 else 1.4)
	var neck := 0.35 if kind == 1 else 0.55
	var r := size * 0.5
	var profile := func(t: float) -> Vector2:
		var w := lerpf(1.0, neck, smoothstep(0.45, 0.8, t)) * sin(minf(t / 0.3, 1.0) * PI * 0.5)
		w *= sqrt(maxf(1.0 - pow(maxf(t - 0.8, 0.0) / 0.2, 2.0), 0.0))
		return Vector2(w * r, t * length)
	var lie := Transform3D.IDENTITY
	if rng.randf() < 0.6:
		lie.basis = Basis(Vector3.FORWARD, deg_to_rad(rng.randf_range(80, 95)))
	_lathe(g, xf * lie, 12, 12, profile, color, Callable(), LAYER_GOURD, Vector2(1, 1))
	_stem(g, xf * lie * Transform3D(Basis.IDENTITY, Vector3(0, length - 0.003, 0)), rng, size * 0.2, size * 0.06)


## One ear with its husks, tip at the origin, base up +Y. length 0.17..0.24.
static func corn_ear(g: Geo, xf: Transform3D, rng: RandomNumberGenerator, length: float) -> void:
	var radius := length * rng.randf_range(0.13, 0.16)
	var bias := rng.randi() % _KERNELS.size()
	var body := func(t: float) -> float:  # t 0 tip .. 1 base
		return radius * (1.0 - 0.55 * pow(1.0 - t, 2.0)) * (1.0 - 0.15 * pow(t, 6.0))
	var rows := 22
	var around := 14
	_lathe(g, xf, 6, 8, func(t: float) -> Vector2:
		return Vector2(body.call(t) * 0.86 + 0.002, t * length), func(_t: float, _a: float) -> Color: return _COB)
	for i in rows:
		var t0 := (i + 0.08) / rows
		var t1 := (i + 0.92) / rows
		var r0: float = body.call(t0)
		var r1: float = body.call(t1)
		var twist := 0.5 * (i % 2)
		for j in around:
			var a0 := TAU * (j + twist + 0.06) / around
			var a1 := TAU * (j + twist + 0.94) / around
			var col := _KERNELS[bias] if rng.randf() < 0.35 else _KERNELS[rng.randi() % _KERNELS.size()]
			g.quad(xf, Vector3(r0 * cos(a0), t0 * length, r0 * sin(a0)), Vector3(r0 * cos(a1), t0 * length, r0 * sin(a1)),
				Vector3(r1 * cos(a0), t1 * length, r1 * sin(a0)), Vector3(r1 * cos(a1), t1 * length, r1 * sin(a1)),
				_jitter(rng, col, 0.12), false, LAYER_KERNEL)
	# Husks peeled back past the base and flaring out, both sides drawn.
	var husk := _jitter(rng, _HUSK, 0.08)
	var leaves := rng.randi_range(3, 4)
	for k in leaves:
		var a := TAU * (k + rng.randf_range(-0.2, 0.2)) / leaves
		var out := Vector3(cos(a), 0, sin(a))
		var side := Vector3.UP.cross(out)
		var hl := length * rng.randf_range(0.7, 0.95)
		var flare := rng.randf_range(0.5, 0.9)
		var point := func(i: int, j: int) -> Vector3:
			var t := i / 5.0
			var w := length * 0.12 * sin((t * 0.85 + 0.15) * PI) * (j * 2 - 1)
			var along := out * (radius * 0.8 + hl * flare * t * t) + Vector3.UP * (length * 0.97 + hl * t)
			return along + side * w
		var shade := func(i: int, _j: int) -> Color: return husk.darkened(0.15 * i / 5.0)
		g.grid(xf, 5, 1, false, point, shade, false, LAYER_HUSK, Vector2(0.3, 1))
		g.grid(xf, 5, 1, false, point, shade, true, LAYER_HUSK, Vector2(0.3, 1))


## A woven horn lying on its side, the tail curling up over it, its mouth spilling fruit. The
## origin is the middle of what it covers, about 1.1 x 0.6 at scale 1.
static func _cornucopia(g: Geo, xf: Transform3D, rng: RandomNumberGenerator, scale: float) -> void:
	var mouth := 0.26 * scale
	var length := 0.95 * scale
	var steps := 44
	var radius := func(s: float) -> float: return mouth * pow(1.0 - s, 1.25) + 0.006 * scale
	# The spine: start by running down the shrinking radius, then curl up and back.
	var spine: Array[Vector3] = []
	var tangent: Array[Vector3] = []
	var p := Vector3.ZERO
	var theta0 := -atan2(mouth, length * 0.55)
	for i in steps + 1:
		var s := float(i) / steps
		var theta := theta0 + smoothstep(0.4, 1.0, s) * PI * 1.25
		var d := Vector3(cos(theta), sin(theta), 0)
		spine.append(p)
		tangent.append(d)
		p += d * length / steps
	var lowest := INF
	for i in steps + 1:
		lowest = minf(lowest, spine[i].y - radius.call(float(i) / steps))
	var shift := Vector3(-0.2 * scale, -lowest, 0)
	var light := _jitter(rng, _WICKER_LIGHT)
	var dark := _jitter(rng, _WICKER_DARK)
	var horn_xf := xf * Transform3D(Basis.IDENTITY, shift)
	var ring := func(i: int, inset: float) -> float:
		return (radius.call(float(i) / steps) as float) * inset * (1.08 if i == 0 else 1.0)  # a lip
	# Coiled wicker, the coils in the detail layer; the colour drifts a little down the horn.
	_tube(g, horn_xf, spine, tangent, func(i: int) -> float: return ring.call(i, 1.0), 16,
		func(i: int, _j: int) -> Color: return light.lerp(dark, 0.35 * (0.5 + 0.5 * sin(i * 0.7))),
		false, LAYER_WICKER, Vector2(2, 4))
	# The lining, all the way down (or the outside shows through from behind), darkening as it goes in.
	_tube(g, horn_xf, spine, tangent, func(i: int) -> float: return ring.call(i, 0.93), 16,
		func(i: int, _j: int) -> Color: return dark.darkened(0.3 + 0.4 * i / steps),
		true, LAYER_WICKER, Vector2(2, 4))

	# The spill, out of the mouth (which faces -X).
	var floor_xf := func(x: float, z: float, yaw: float) -> Transform3D:
		return xf * Transform3D(Basis(Vector3.UP, yaw), Vector3(shift.x + x, 0, z))
	for k in rng.randi_range(2, 3):
		_place(g, floor_xf.call(-rng.randf_range(0.08, 0.3) * scale, rng.randf_range(-0.2, 0.2) * scale,
				rng.randf() * TAU), _gourd, rng, rng.randf_range(0.08, 0.12) * scale)
	for k in rng.randi_range(1, 3):
		var ar := rng.randf_range(0.038, 0.048) * scale
		var apple_xf: Transform3D = floor_xf.call(-rng.randf_range(0.0, 0.25) * scale,
				rng.randf_range(-0.22, 0.22) * scale, 0.0)
		var red := _jitter(rng, Color(0.72, 0.09, 0.06) if rng.randf() < 0.75 else Color(0.85, 0.7, 0.2))
		_sphere(g, apple_xf, ar, red, 6, 8, LAYER_APPLE)
		_stem(g, apple_xf * Transform3D(Basis.IDENTITY, Vector3(0, ar * 1.9, 0)), rng, ar * 0.5, ar * 0.08)
	# Grapes, a loose cone of them on their side.
	var grape_at: Transform3D = floor_xf.call(-0.05 * scale, rng.randf_range(-0.12, 0.12) * scale, rng.randf() * TAU)
	var grape := _jitter(rng, Color(0.30, 0.10, 0.36) if rng.randf() < 0.7 else Color(0.55, 0.65, 0.25))
	var gr := 0.016 * scale
	for k in 14:
		var u := k / 14.0
		var at := Vector3(-u * 0.12 * scale, gr + (1.0 - u) * gr * 1.5,
				0) + Vector3(0, rng.randf_range(-0.5, 0.5), rng.randf_range(-1, 1)).normalized() * (1.0 - u) * 0.03 * scale
		at.y = maxf(at.y, gr)
		_sphere(g, grape_at * Transform3D(Basis.IDENTITY, at - Vector3(0, gr, 0)), gr, _jitter(rng, grape, 0.1), 4, 6)
	# And an ear of corn lying out in front.
	if rng.randf() < 0.7:
		var lay := Basis(Vector3.UP, rng.randf_range(-0.6, 0.6)) * Basis(Vector3.BACK, PI * 0.5)
		corn_ear(g, floor_xf.call(-0.12 * scale, rng.randf_range(-0.18, 0.18) * scale, 0.0)
				* Transform3D(lay, Vector3(0.0, 0.03 * scale, 0)), rng, 0.18 * scale)


# --- Christmas -----------------------------------------------------------------------------------

## A fir of stacked, branchy tiers on a stub of trunk, hung with baubles and a string of lights,
## a star on top facing +Z. height 1.5..2.2.
static func _tree(g: Geo, xf: Transform3D, rng: RandomNumberGenerator, height: float) -> void:
	var bark := _jitter(rng, Color(0.36, 0.25, 0.16))
	_lathe(g, xf, 2, 8, func(t: float) -> Vector2: return Vector2(height * 0.045, t * height * 0.2),
		func(_t: float, _a: float) -> Color: return bark,
		Callable(), LAYER_BARK, Vector2(1, 0.5))
	var fir := _jitter(rng, _FIR, 0.12)
	var tiers := 5
	var cones := []  # [base y, tier height, rim radius]
	for k in tiers:
		var f := float(k) / tiers
		var base := height * (0.13 + 0.16 * k)
		var th := height * lerpf(0.34, 0.24, f)
		if k == tiers - 1:
			th = height * 0.97 - base
		var rim := height * 0.36 * (1.0 - 0.78 * f)
		cones.append([base, th, rim])
		var branches := rng.randi_range(9, 13) - k
		var twist := rng.randf() * TAU
		# Up the underside from the trunk to the rim (t < 0.2), then the rim up to the tip.
		_lathe(g, xf, 10, branches * 4, func(t: float) -> Vector2:
			if t < 0.2:
				var u := t / 0.2
				return Vector2(lerpf(height * 0.05, rim, u), base + th * 0.12 * (1.0 - u))
			var v := (t - 0.2) / 0.8
			return Vector2(rim * (1.0 - v), base + th * v),
			func(t: float, _a: float) -> Color:
				return fir.darkened(0.45 if t < 0.2 else 0.2 * (1.0 - t)),
			func(t: float, a: float) -> float:
				var tip := pow(absf(sin((a + twist) * branches * 0.5)), 3.0)
				return 1.0 + 0.2 * (tip - 0.4) * (1.0 - absf(t - 0.2)),
			LAYER_NEEDLES, Vector2(branches * 0.5, 1.5))
	var envelope := func(y: float) -> float:
		var r := 0.0
		for c: Array in cones:
			var v: float = (y - (c[0] as float)) / (c[1] as float)
			if v >= 0.0 and v <= 1.0:
				r = maxf(r, (c[2] as float) * (1.0 - v))
		return r
	for k in rng.randi_range(14, 22):
		var y := height * rng.randf_range(0.18, 0.85)
		var a := rng.randf() * TAU
		var br := height * rng.randf_range(0.02, 0.03)
		var at := Vector3(cos(a), 0, sin(a)) * (envelope.call(y) as float) * 0.92 + Vector3(0, y - br * 2.0, 0)
		_sphere(g, xf * Transform3D(Basis.IDENTITY, at), br, _jitter(rng, _BAUBLES[rng.randi() % _BAUBLES.size()]))
	var turns := rng.randf_range(4.0, 5.5)
	var phase := rng.randf() * TAU
	var multi := rng.randf() < 0.6
	var bulbs := 64
	for k in bulbs:
		var u := (k + 0.5) / bulbs
		var y := height * lerpf(0.16, 0.9, u)
		var a := u * TAU * turns + phase
		var at := Vector3(cos(a), 0, sin(a)) * (envelope.call(y) as float) * 0.97 + Vector3(0, y - 0.012, 0)
		_sphere(g, xf * Transform3D(Basis.IDENTITY, at), 0.011, _BULBS[k % _BULBS.size()] if multi else _BULBS[0], 3, 4)
	_star(g, xf * Transform3D(Basis.IDENTITY, Vector3(0, height * 1.02, 0)), height * 0.065)


## Five points in the XY plane, a little thick, gold and half lit.
static func _star(g: Geo, xf: Transform3D, r: float) -> void:
	var gold := Color(1.0, 0.82, 0.3, 0.4)
	var depth := r * 0.18
	var point := func(j: int) -> Vector3:
		var a := PI * 0.5 + TAU * j / 10.0
		return Vector3(cos(a), sin(a), 0) * (r if j % 2 == 0 else r * 0.42)
	for side in [1.0, -1.0]:
		g.grid(xf, 1, 10, true, func(i: int, j: int) -> Vector3:
			return (Vector3.ZERO if i == 0 else point.call(j)) + Vector3(0, 0, depth * side * (1.6 if i == 0 else 1.0)),
			func(_i: int, _j: int) -> Color: return gold, side < 0.0)
	g.grid(xf, 1, 10, true, func(i: int, j: int) -> Vector3:
		return (point.call(j) as Vector3) + Vector3(0, 0, depth * (1.0 if i == 0 else -1.0)),
		func(_i: int, _j: int) -> Color: return gold.darkened(0.2), true)


## A wrapped box tied both ways with ribbon and a bow on top. size 0.18..0.42.
static func _present(g: Geo, xf: Transform3D, rng: RandomNumberGenerator, size: float) -> void:
	var hx := size * rng.randf_range(0.4, 0.65)
	var hz := size * rng.randf_range(0.4, 0.6)
	var h := size * rng.randf_range(0.55, 1.05)
	var paper := _jitter(rng, _PAPERS[rng.randi() % _PAPERS.size()])
	var layer: int = [LAYER_PAPER_DOTS, LAYER_PAPER_STRIPES, LAYER_PLAIN][rng.randi() % 3]
	var ribbon := _RIBBONS[rng.randi() % _RIBBONS.size()]
	if ribbon.is_equal_approx(paper):
		ribbon = _RIBBONS[0]
	var tile := 0.12
	var faces := [  # centre, out, hu, hv
		[Vector3(0, h, 0), Vector3.UP, Vector3(hx, 0, 0), Vector3(0, 0, hz)],
		[Vector3(hx, h * 0.5, 0), Vector3.RIGHT, Vector3(0, 0, hz), Vector3(0, h * 0.5, 0)],
		[Vector3(-hx, h * 0.5, 0), Vector3.LEFT, Vector3(0, 0, hz), Vector3(0, h * 0.5, 0)],
		[Vector3(0, h * 0.5, hz), Vector3.BACK, Vector3(hx, 0, 0), Vector3(0, h * 0.5, 0)],
		[Vector3(0, h * 0.5, -hz), Vector3.FORWARD, Vector3(hx, 0, 0), Vector3(0, h * 0.5, 0)],
	]
	for f: Array in faces:
		var hu: Vector3 = f[2]
		var hv: Vector3 = f[3]
		_quad(g, xf, f[0], f[1], hu, hv, paper, layer, Vector2(hu.length(), hv.length()) * 2.0 / tile)
	var rw := minf(hx, hz) * 0.16
	var e := 0.003
	# One band round the box over +-X, one over +-Z, the second a hair further out where they cross.
	_quad(g, xf, Vector3(0, h + e, 0), Vector3.UP, Vector3(hx + e, 0, 0), Vector3(0, 0, rw), ribbon)
	_quad(g, xf, Vector3(0, h + e * 2.0, 0), Vector3.UP, Vector3(0, 0, hz + e), Vector3(rw, 0, 0), ribbon)
	for sx in [1.0, -1.0]:
		_quad(g, xf, Vector3(sx * (hx + e), h * 0.5, 0), Vector3(sx, 0, 0), Vector3(0, 0, rw), Vector3(0, h * 0.5, 0), ribbon)
		_quad(g, xf, Vector3(0, h * 0.5, sx * (hz + e)), Vector3(0, 0, sx), Vector3(rw, 0, 0), Vector3(0, h * 0.5, 0), ribbon)
	# The bow: two pairs of loops standing on the knot, leaning apart, the pairs crossed so it reads
	# from any side.
	var loop := rw * rng.randf_range(1.6, 2.2)
	var first := rng.randf_range(-0.6, 0.6)
	for k in 4:
		var turn := first + (0.0 if k < 2 else PI * 0.5)
		var side := 1.0 if k % 2 == 0 else -1.0
		var b := Basis(Vector3.UP, turn) * Basis(Vector3.BACK, side * 0.5) * Basis(Vector3.RIGHT, PI * 0.5)
		b = b.scaled(Vector3(1.0, 1.0, 0.85))
		var centre := Basis(Vector3.UP, turn) * Vector3(side * loop * 0.85, h + loop * 0.75, 0)
		_torus(g, xf * Transform3D(b, centre), loop, rw * 0.5, ribbon.darkened(0.05))
	_sphere(g, xf * Transform3D(Basis.IDENTITY, Vector3(0, h - rw * 0.2, 0)), rw * 0.7, ribbon.darkened(0.1))


## Red-and-white, a hook at the top bending toward +X. length 0.45..0.75.
static func candy_cane(g: Geo, xf: Transform3D, rng: RandomNumberGenerator, length: float) -> void:
	var r := length * 0.035
	var hook := length * 0.13
	var shaft := length - hook
	var spine: Array[Vector3] = []
	var tangent: Array[Vector3] = []
	for i in 9:
		var t := i / 8.0
		spine.append(Vector3(0, t * shaft, 0))
		tangent.append(Vector3.UP)
	var sweep := PI * rng.randf_range(1.05, 1.25)
	for i in range(1, 13):
		var a := PI - sweep * i / 12.0
		spine.append(Vector3(hook + hook * cos(a), shaft + hook * sin(a), 0))
		tangent.append(Vector3(sin(a), -cos(a), 0))
	var white := Color(0.97, 0.96, 0.94)
	var along := 0.0
	for i in range(1, spine.size()):
		along += spine[i].distance_to(spine[i - 1])
	_tube(g, xf, spine, tangent, func(_i: int) -> float: return r, 10,
		func(_i: int, _j: int) -> Color: return white, false, LAYER_CANDY, Vector2(1, along / (r * 9.0)))
	_sphere(g, xf * Transform3D(Basis.IDENTITY, Vector3(0, -r, 0)), r, white, 4, 10)
	var tip_at := spine[spine.size() - 1] - tangent[tangent.size() - 1] * r * 0.2
	_sphere(g, xf * Transform3D(Basis.IDENTITY, tip_at - Vector3(0, r, 0)), r, white, 4, 10)


## Three balls of snow, coal eyes and buttons, a carrot nose and stick arms, a scarf, sometimes a
## hat; facing +Z. size (the bottom ball's radius) 0.22..0.32.
static func _snowman(g: Geo, xf: Transform3D, rng: RandomNumberGenerator, size: float) -> void:
	var radii := [size, size * rng.randf_range(0.68, 0.76), size * rng.randf_range(0.48, 0.55)]
	var centres: Array[float] = []
	var y := 0.0
	for k in 3:
		var r: float = radii[k]
		var lean := Vector3(rng.randf_range(-0.03, 0.03), 0, rng.randf_range(-0.03, 0.03)) * r
		var snow := _jitter(rng, _SNOW, 0.02)
		_lathe(g, xf * Transform3D(Basis.IDENTITY, Vector3(lean.x, y, lean.z)), 10, 14,
			func(t: float) -> Vector2: return Vector2(sin(t * PI), 1.0 - cos(t * PI)) * r,
			func(_t: float, _a: float) -> Color: return snow, Callable(), LAYER_SNOW, Vector2(2, 1))
		centres.append(y + r)
		y += r * 2.0 * 0.82
	var head: float = radii[2]
	var hy := centres[2]
	var face := func(up: float, side: float, r: float) -> Vector3:  # on the ball's surface
		var d := Vector3(side, up, 1.0).normalized()
		return Vector3(0, hy, 0) + d * r
	for side in [-0.35, 0.35]:
		var eye: Vector3 = face.call(0.25, side, head)
		_sphere(g, xf * Transform3D(Basis.IDENTITY, eye - Vector3(0, head * 0.08, 0)), head * 0.08, _COAL, 4, 6)
	var nose_at: Vector3 = face.call(-0.05, 0.0, head * 0.92)
	_lathe(g, xf * Transform3D(Basis(Vector3.RIGHT, PI * 0.5).rotated(Vector3.UP, rng.randf_range(-0.2, 0.2)), nose_at), 3, 8,
		func(t: float) -> Vector2: return Vector2(head * 0.12 * (1.0 - t), t * head * 0.65),
		func(_t: float, _a: float) -> Color: return Color(0.95, 0.45, 0.08))
	var body: float = radii[1]
	for k in 3:
		var up := 0.45 - 0.35 * k
		var at := Vector3(0, centres[1], 0) + Vector3(0, up, 1.0).normalized() * body
		_sphere(g, xf * Transform3D(Basis.IDENTITY, at - Vector3(0, body * 0.06, 0)), body * 0.06, _COAL, 4, 6)
	for side in [1.0, -1.0]:
		var root := Vector3(side * body * 0.85, centres[1] + body * 0.25, 0)
		var b := Basis(Vector3.BACK, -side * rng.randf_range(0.7, 1.1)) * Basis(Vector3.UP, rng.randf())
		_stem(g, xf * Transform3D(b, root), rng, size * rng.randf_range(1.0, 1.3), size * 0.04)
	var scarf := _jitter(rng, _PAPERS[rng.randi() % 3])
	var neck := centres[1] + body * 0.82
	_torus(g, xf * Transform3D(Basis.IDENTITY, Vector3(0, neck, 0)), head * 0.82, head * 0.2, scarf,
		LAYER_PAPER_STRIPES, Vector2(6, 1))
	_quad(g, xf, Vector3(head * 0.45, neck - head * 0.45, head * 0.9), Vector3(0.3, 0, 1).normalized(),
		Vector3(head * 0.16, 0, -head * 0.05), Vector3(0, head * 0.45, 0), scarf, LAYER_PAPER_STRIPES)
	if rng.randf() < 0.5:
		var top := hy + head * 0.85
		var brim := head * 1.05
		var crown := head * 0.7
		var hat := Color(0.1, 0.09, 0.1)
		_lathe(g, xf * Transform3D(Basis.IDENTITY, Vector3(0, top, 0)), 6, 14, func(t: float) -> Vector2:
			if t < 0.2:
				return Vector2(brim, t / 0.2 * head * 0.06)
			if t < 0.4:
				return Vector2(lerpf(brim, crown, (t - 0.2) / 0.2), head * 0.06)
			if t < 0.95:
				return Vector2(crown, head * 0.06 + (t - 0.4) / 0.55 * head * 0.9)
			return Vector2(crown * (1.0 - (t - 0.95) / 0.05), head * 0.96),
			func(t: float, _a: float) -> Color: return Color(0.6, 0.08, 0.08) if t > 0.42 and t < 0.5 else hat)
