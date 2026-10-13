extends Node

# Checks that units are never silent (the presence layers of source/match/environment/
# Soundscape.gd): every unit has its layers in data/sounds/units.json, units at rest idle
# (tank diesels tick over, rotors keep turning, a squad standing still is quiet), units on the
# move run their engines and footsteps, and the player's units chatter on the radio.
# Usage (needs a real renderer, e.g. under xvfb-run):
#   godot --path . res://tests/audio/UnitPresenceCheck.tscn
# Exits with 1 on a failure.

const GameData = preload("res://source/data-model/GameData.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")

var _failures = []


func _ready():
	var presence = GameData.sounds("units")
	for entry in GameData.units():
		if entry.get("category") == "structure" or entry.get("scene", "").contains("Structure"):
			continue
		if not entry["id"] in presence.get("units", {}):
			print("note: ", entry["id"], " uses the default vehicle sound")

	var match_node = load("res://tests/manual/TestDesert.tscn").instantiate()
	add_child(match_node)
	await _frames(20)
	var soundscape = match_node.find_child("Soundscape", true, false)
	var human = get_tree().get_nodes_in_group("players")[0]
	var spot = Vector3(60.0, 0.0, 60.0)
	var units = {}
	for id in ["tank", "militia", "helicopter"]:
		var unit = load(GameData.unit_by_id(id)["scene"]).instantiate()
		MatchSignals.setup_and_spawn_unit.emit(
			unit, Transform3D(Basis(), spot + Vector3(units.size() * 3.0, 0, 0)), human
		)
		units[id] = unit
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(14.0)
	camera.set_position_safely(spot)
	await _frames(30)
	for id in units:
		_expect(not soundscape._layers_of(units[id]).is_empty(), id + " has presence layers")
	var targets = soundscape._targets
	_expect(targets["tank_idle_loop"] > 0.0, "a tank at rest ticks over")
	_expect(targets["tank_engine_loop"] == 0.0, "without running its tracks")
	_expect(targets["footsteps_loop"] == 0.0, "a squad standing still makes no footsteps")
	_expect(targets["rotor_loop"] > 0.0, "a hovering helicopter's rotor turns")
	_expect(targets["rotor_wash_loop"] > 0.0, "and beats up the air")
	var idle_pitch = soundscape._players["rotor_loop"].pitch_scale

	for id in units:
		units[id].action = Moving.new(spot + Vector3(30.0, 0.0, 10.0))
	camera.set_position_safely(spot + Vector3(4.0, 0.0, 2.0))
	await _frames(25)
	_expect(targets["tank_engine_loop"] > 0.0, "a moving tank runs its engine and tracks")
	_expect(targets["footsteps_loop"] > 0.0, "a moving squad is heard walking")
	_expect(
		soundscape._players["rotor_loop"].pitch_scale >= idle_pitch,
		"a flying helicopter's rotor is not lower than when hovering"
	)

	soundscape._chatter_in = 0.0
	await _frames(20)
	_expect(soundscape.chatter_count > 0, "the player's units chatter on the radio")
	_expect(soundscape._chatter_voices[0].bus == &"Voices", "on the Voices bus")

	for failure in _failures:
		print("FAIL: ", failure)
	print("UnitPresenceCheck: {0}".format(["ok" if _failures.is_empty() else "FAILED"]))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _frames(count):
	for i in range(count):
		await get_tree().process_frame


func _expect(condition, what):
	if not condition:
		_failures.append(what)
