extends "res://src/tests/test_base.gd"
## Thornplant.upgrade() priority: level up when affordable, otherwise heal an
## injured plant with whatever mana is on hand (1 mana per HP).

const ThornplantScript = preload("res://src/monsters/thornplant.gd")


func _make_plant(level: int, health: float) -> Thornplant:
	var plant: Thornplant = ThornplantScript.new()
	plant.setup({"level": level})
	_root().add_child(plant)
	plant._growing = false
	plant._summon.health = health
	return plant


func test_heals_with_partial_mana_when_upgrade_unaffordable() -> void:
	var plant := _make_plant(1, 50.0)  # level index 1 ("level 2"), not maxed
	var spent := plant.upgrade(75.0, 30.0)  # only 30 mana on hand, can't afford 75
	assert_almost_eq(spent, 30.0, 0.001, "spends all available mana on the heal")
	assert_almost_eq(plant.health, 80.0, 0.001, "healed by the mana amount, 1:1")
	assert_eq(plant.level, 1, "did not level up")
	plant.queue_free()


func test_levels_up_instead_of_healing_when_affordable() -> void:
	var plant := _make_plant(1, 50.0)
	var spent := plant.upgrade(75.0, 100.0)  # plenty of mana
	assert_almost_eq(spent, 75.0, 0.001, "spends the full level-up cost")
	assert_eq(plant.level, 2, "leveled up")
	assert_almost_eq(plant.health, plant.max_health, 0.001, "new level starts at full health")
	plant.queue_free()


func test_heals_when_already_maxed() -> void:
	var plant := _make_plant(2, 100.0)  # max level index, damaged
	var spent := plant.upgrade(75.0, 50.0)
	assert_almost_eq(spent, 50.0, 0.001, "spends available mana healing")
	assert_almost_eq(plant.health, 150.0, 0.001, "healed by the mana amount")
	assert_eq(plant.level, 2, "still maxed")
	plant.queue_free()


func test_full_health_and_unaffordable_does_nothing() -> void:
	var plant := _make_plant(1, 200.0)  # already full health at this level, not maxed
	var spent := plant.upgrade(75.0, 30.0)  # can't afford upgrade, nothing to heal
	assert_almost_eq(spent, 0.0, 0.001, "spends nothing")
	assert_eq(plant.level, 1, "did not level up")
	assert_almost_eq(plant.health, 200.0, 0.001, "health unchanged")
	plant.queue_free()
