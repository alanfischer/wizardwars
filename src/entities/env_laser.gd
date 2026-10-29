class_name EnvLaser
extends EnvBeam
# env_laser — beam from this entity's own origin to the point entity named by
# LaserTarget (GoldSrc CLaser). Everything else (rendering, noise, scroll, sync,
# damage) is env_beam's; only the endpoints and a key name or two differ.


func _ready() -> void:
	var e: Dictionary = get_meta("entity", {})
	if e.has("width") and not e.has("BoltWidth"):  # CLaser's name for env_beam's BoltWidth
		e["BoltWidth"] = e["width"]
		set_meta("entity", e)
	super()
	_start_node = self  # _resolve_endpoints only touches nodes whose lookup succeeds
	_end_name = ent.get("LaserTarget", "")
	# GoldSrc fires CLaser every 0.1s for dmg*elapsed ("damage" per second); env_beam
	# applies the figure whole on each DAMAGE_INTERVAL tick.
	_damage = parse_float(ent, "damage", 0.0) * DAMAGE_INTERVAL
