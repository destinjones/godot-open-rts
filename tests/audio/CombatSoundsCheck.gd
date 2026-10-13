extends Node

# Checks the combat sound table (data/sounds/combat.json, played by
# source/match/environment/WarSounds.gd): every kind has its files, every unit that can shoot
# has a report, every unit dies a death whose layers exist, and rounds sound different on
# infantry, armour and buildings. Usage:
#   godot --headless --path . res://tests/audio/CombatSoundsCheck.tscn
# Exits with 1 on a failure.

const GameData = preload("res://source/data-model/GameData.gd")
const WarSounds = preload("res://source/match/environment/WarSounds.gd")

var _failures = []


func _ready():
	GameData.register_generated_scenes()  # units built on another unit (scout buggy, ...)
	var war_sounds = WarSounds.new()
	add_child(war_sounds)
	var config = GameData.sounds("combat")
	for kind in config.get("kinds", {}):
		_expect(not war_sounds._streams.get(kind, []).is_empty(), kind + " has its files")
	var kinds = war_sounds._kinds
	for weapon in config.get("weapons", {}).values() + config.get("default_weapons", {}).values():
		_expect(weapon in kinds, "weapon sound " + weapon + " exists")
	for size in config.get("deaths", {}):
		for layer in config["deaths"][size]:
			_expect(layer[1] in kinds, "death " + size + " plays an existing " + str(layer[1]))

	var reports = {}
	var deaths = {}
	var surfaces = {}
	for entry in GameData.units():
		var scene = load(entry["scene"]) if ResourceLoader.exists(entry["scene"]) else null
		if scene == null:
			continue
		var unit = scene.instantiate()
		var id = entry["id"]
		var size = war_sounds.size_of(unit)
		deaths[id] = size
		_expect(size in config.get("deaths", {}), id + " dies a known death (" + size + ")")
		surfaces[id] = war_sounds.surface_of(unit)
		var attack = entry.get("properties", {}).get("attack_damage", 0)
		if attack > 0:
			var projectile = entry.get("projectile", "cannon_shell")
			reports[id] = war_sounds.weapon_of(unit, projectile)
		unit.free()
	_expect(reports.get("militia") == "rifle", "militia fire rifles")
	_expect(reports.get("raider") == "mg", "raiders fire machine guns")
	_expect(reports.get("heavy_tank") == "heavy_cannon", "heavy tanks fire heavy cannon")
	_expect(reports.get("artillery") == "artillery", "artillery fires salvos")
	_expect(reports.get("flak_tower") == "autocannon", "flak towers fire autocannon")
	_expect(deaths.get("militia") == "infantry", "infantry dies as infantry, not a blast")
	_expect(deaths.get("helicopter") == "aircraft", "a helicopter goes down as an aircraft")
	_expect(deaths.get("heavy_tank") == "heavy", "a heavy tank dies big")
	_expect(deaths.get("command_center") == "structure", "a building collapses")
	_expect(surfaces.get("militia") == "impact_soft", "rounds thud into infantry")
	_expect(surfaces.get("tank") == "impact_armor", "and clang off armour")
	_expect(surfaces.get("command_center") == "impact_building", "and crunch into buildings")
	var distinct = {}
	for id in reports:
		distinct[reports[id]] = true
	print("reports: ", reports)
	print("deaths: ", deaths)
	_expect(distinct.size() >= 7, "at least seven distinct weapon reports")

	for failure in _failures:
		print("FAIL: ", failure)
	print("CombatSoundsCheck: {0}".format(["ok" if _failures.is_empty() else "FAILED"]))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _expect(condition, what):
	if not condition:
		_failures.append(what)
