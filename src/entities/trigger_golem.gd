class_name TriggerGolem
extends EntityBase
# trigger_golem — point entity that fires its target when the golem claps nearby.
# Placed at destructible structures around golem maps.

var _target_key := ""


func _ready() -> void:
	super()
	_target_key = ent.get("target", "")
	add_to_group("trigger_golem")


## Called by func_golem_body during arm-clap attack.
## activator is the player who pressed the attack control — passed through so
## team-gated potatoc scripts (APTeam() checks on castle gates etc.) resolve correctly.
##
## Fires on EVERY clap rather than latching once. The map's stacked-rock puzzles
## depend on it: a rock on top only breaks `if(base==1)`, and its trigger must
## stay live across claps until the base below it has been broken. Re-firing is
## safe because the targets self-gate — TurnOff on an already-hidden breakable is
## a no-op, the dependency checks are idempotent, and win-goals remove their goal
## (Remove(N)) so they don't re-score until the map restores them on round reset.
func golem_activate(activator: Node = null) -> void:
	if not _target_key.is_empty():
		TriggerSystem.fire(_target_key, activator if activator else self, TriggerSystem.Type.OFF)
		Log.info("trigger_golem fired target '%s'" % _target_key)
