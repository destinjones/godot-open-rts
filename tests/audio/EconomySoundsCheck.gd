extends Node

# Checks the feedback of building and the economy (source/match/environment/EconomySounds.gd):
# laying out a site clangs, a refused spot buzzes, a site being built is heard working, a
# finished building rings, a power station on a live grid hums (lower in a brownout), goods
# at a depot tick, and the advisor's low-oil call gets its chime first.
# Usage (needs a real renderer, e.g. under xvfb-run):
#   godot --path . res://tests/audio/EconomySoundsCheck.tscn
# Exits with 1 on a failure.

const GameData = preload("res://source/data-model/GameData.gd")

var _failures = []


func _ready():
	var match_node = load("res://tests/manual/TestDesert.tscn").instantiate()
	add_child(match_node)
	await _frames(20)
	var economy = match_node.find_child("EconomySounds", true, false)
	_expect(economy != null, "the soundscape has its economy sounds")
	if economy == null:
		_finish()
		return
	var human = get_tree().get_nodes_in_group("players")[0]
	var command_center = get_tree().get_nodes_in_group("controlled_units").filter(
		func(unit): return unit.scene_file_path.ends_with("CommandCenter.tscn")
	)
	var spot = (
		command_center[0].global_position + Vector3(8, 0, 0)
		if not command_center.is_empty()
		else Vector3(60, 0, 60)
	)
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(14.0)
	camera.set_position_safely(spot)
	await _frames(10)

	var site = load(GameData.unit_by_id("power_plant")["scene"]).instantiate()
	site.set_meta("placed_by_hand", true)
	MatchSignals.setup_and_spawn_unit.emit(site, Transform3D(Basis(), spot), human)
	await _frames(2)
	_expect(economy.played_counts.get("build_place", 0) == 1, "laying out a site clangs")

	MatchSignals.structure_placement_refused.emit(human)
	_expect(economy.played_counts.get("build_refused", 0) == 1, "a refused spot buzzes")

	economy._since_refresh = 1.0
	await _frames(2)
	site._construction_progress += 0.2  # as if a constructor were at work
	economy._since_refresh = 1.0
	await _frames(2)
	_expect(economy.targets["construction"] > 0.0, "a site being built is heard working")
	await _frames(2)
	economy._since_refresh = 1.0
	await _frames(2)
	_expect(economy.targets["construction"] == 0.0, "and falls quiet when nobody builds it")

	site._construction_progress = 1.0
	site._finish_construction()
	_expect(economy.played_counts.get("build_complete", 0) == 1, "a finished building rings")
	await _frames(30)
	economy._since_refresh = 1.0
	await _frames(2)
	var on_grid = human.power_grid != null and human.power_grid.get_power_ratio_at(spot) > 0.0
	if on_grid:
		_expect(economy.targets["power_hum"] > 0.0, "a power station on a live grid hums")
	else:
		print("note: the power plant is not on a live grid yet, hum not checked live")
	economy.update_loops({"power_hum": 1.0, "power_ratio": 0.3})
	_expect(economy._pitch_targets["power_hum"] < 1.0, "a browned-out grid hums lower")

	for i in range(10):
		economy._last_ms.erase("deposit")
		MatchSignals.goods_delivered.emit(human, {"iron": 1})
	_expect(economy.played_counts.get("deposit", 0) > 0, "goods at a depot tick")

	var narrator = human.find_child("VoiceNarratorController", true, false)
	_expect(narrator != null, "the human player has an advisor")
	if narrator != null:
		narrator._last_ms.erase("low_oil")
		narrator.announce("low_oil")
		var voice = narrator.find_child("AudioStreamPlayer")
		_expect(voice.stream is AudioStreamPlaylist, "the low-oil call rings a chime first")
		_expect(
			voice.stream is AudioStreamPlaylist and voice.stream.get_list_stream(1) != null,
			"then the advisor speaks"
		)
		narrator.announce("match_started")
		_expect(narrator.last_event == "low_oil", "and the next line waits for both")
	_finish()


func _finish():
	for failure in _failures:
		print("FAIL: ", failure)
	print("EconomySoundsCheck: {0}".format(["ok" if _failures.is_empty() else "FAILED"]))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _frames(count):
	for i in range(count):
		await get_tree().process_frame


func _expect(condition, what):
	if not condition:
		_failures.append(what)
