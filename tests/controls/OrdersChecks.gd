extends "res://tests/commands/CommandChecks.gd"

# Bot checks for the order controls, through simulated mouse events:
# - right-click on the ground with a factory selected sets its rally point; the marker
#   shows and a dashed line runs from the factory to it (handlers/UnitCommandHandler.gd),
# - right-click on one of the player's units makes the rally point follow it, and the
#   marker stays visible on that unit (units/traits/RallyPoint.gd).
# Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 \
#     res://tests/controls/OrdersChecks.tscn -- --out=/tmp/orders
# Prints PASS/FAIL lines, saves screenshots to --out and exits with code 1 on failures.

const VehicleFactoryScene = preload("res://source/match/units/VehicleFactory.tscn")


func _ready():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	_match = load("res://tests/playthrough/HelperMatch.tscn").instantiate()
	add_child(_match)
	await _frames(30)
	_human = get_tree().get_nodes_in_group("players").filter(func(p): return p is Human)[0]
	_rival = get_tree().get_nodes_in_group("players").filter(func(p): return p != _human)[0]
	_handler = UnitCommandHandler.of(get_tree())
	_cc = _own(func(unit): return unit is CommandCenter)
	_make_rival_inert()
	_match.fog_of_war.reveal()
	var atmosphere = _match.find_child("Atmosphere", true, false)
	if atmosphere != null:
		atmosphere.set_weather_immediately(&"clear")
		atmosphere.set("_time_to_next_weather", 1.0e9)
	await _check_rally_line()
	print("orders checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_rally_line():
	var spot = _ground(_cc.global_position + Vector3(9, 0, 9))
	var factory = VehicleFactoryScene.instantiate()
	factory.set_meta("spawn_constructed", true)
	MatchSignals.setup_and_spawn_unit.emit(factory, Transform3D(Basis(), spot), _human)
	await _frames(20)
	camera_on(spot + Vector3(3, 0, 3), 14)
	await _frames(5)
	await _select([factory])
	await _frames(3)
	var rally_point = factory.find_child("RallyPoint")
	var target = _ground(spot + Vector3(7, 0, 4))
	await _click(MOUSE_BUTTON_RIGHT, target)
	await _frames(3)
	# where the click lands on the ground plane, which the game uses for orders
	target = get_viewport().get_camera_3d().get_ray_intersection(_screen(target))
	_expect(
		(
			(rally_point.global_position * Vector3(1, 0, 1)).distance_to(target * Vector3(1, 0, 1))
			< 1.0
		),
		"right-click on the ground sets the factory's rally point there"
	)
	_expect(rally_point.visible, "... the marker shows")
	_expect(await _rally_line_drawn(), "... and a line runs from the factory to it")
	await _shot("1-rally-on-ground")
	var tank = _spawn_squad(_human, _ground(spot + Vector3(7, 0, -2)), 1)[0]
	await _frames(20)
	await _click(MOUSE_BUTTON_RIGHT, tank.global_position + Vector3.UP * 0.3)
	await _frames(5)
	_expect(rally_point.target_unit == tank, "right-click on own tank: the rally point follows it")
	_expect(rally_point.visible, "... and its marker stays visible on the tank")
	_expect(await _rally_line_drawn(), "... with the line to the tank")
	await _shot("2-rally-on-unit")
	MatchSignals.deselect_all_units.emit()
	await _frames(3)
	_expect(not rally_point.visible, "deselecting the factory hides the marker")
	await _cleanup([factory, tank])


func _rally_line_drawn():
	"""the order handler's line mesh has something on it with only the factory selected"""
	await _frames(2)
	var mesh = _handler.get("_mesh")
	return mesh != null and mesh.get_surface_count() > 0
