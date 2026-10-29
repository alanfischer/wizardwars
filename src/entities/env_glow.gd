class_name EnvGlow
extends EnvSprite
# env_glow — CGlow: tinted billboard for lamp halos, torch flares, rune light. Same
# render path as env_sprite, but always applies rendercolor since the source sprites
# are additive greyscale (untinted they'd all be white).


func _ready() -> void:
	super()
	var sprite := get_node_or_null(^"Sprite") as Sprite3D
	if sprite == null:
		return
	# All-zero rendercolor means unset; leave the sprite at its default white.
	var rc := parse_color(ent.get("rendercolor", "0 0 0"))
	if rc.r == 0.0 and rc.g == 0.0 and rc.b == 0.0:
		return
	sprite.modulate = Color(rc.r, rc.g, rc.b, sprite.modulate.a)  # keep env_sprite's renderamt alpha
