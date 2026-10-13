extends "res://tests/commands/CommandChecks.gd"

# Bot checks for the selection controls, given through simulated mouse and keyboard events:
# - a box over units and buildings takes only the units; a box over buildings alone
#   takes the buildings (handlers/ArealUnitSelectionHandler.gd),
# - Ctrl + click selects every unit of that type on screen, not other types
#   (traits/Selection.gd + handlers/DoubleClickUnitSelectionHandler.gd),
# - Ctrl + 1 sets group 1, 1 recalls it, Shift + 1 adds to it, 1 twice centres the camera
#   on it (handlers/UnitGroupSelectionHandler.gd),
# - the control group bar shows the group with its count and lights up on recall
#   (hud/ControlGroupBar.gd).
# Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 \
#     res://tests/controls/SelectionChecks.tscn -- --out=/tmp/selection
# Prints PASS/FAIL lines, saves screenshots to --out and exits with code 1 on failures.

const VirtualPointer = preload("res://source/utils/VirtualPointer.gd")
const UnitGroupSelectionHandler = preload(
	"res://source/match/handlers/UnitGroupSelectionHandler.gd"
)

var _groups = null


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
	_groups = UnitGroupSelectionHandler.of(get_tree())
	# a frame here can take longer than a player's double tap under a software renderer
	_groups.double_tap_ms = 5000
	# the box selection reads the pointer, which xvfb leaves in the corner
	VirtualPointer.active = true
	VirtualPointer.position = get_viewport().get_visible_rect().size / 2.0
	_cc = _own(func(unit): return unit is CommandCenter)
	_make_rival_inert()
	_match.fog_of_war.reveal()
	var atmosphere = _match.find_child("Atmosphere", true, false)
	if atmosphere != null:
		atmosphere.set_weather_immediately(&"clear")
		atmosphere.set("_time_to_next_weather", 1.0e9)
	await _check_box_prefers_units()
	await _check_ctrl_click_selects_type()
	await _check_control_groups()
	print("selection checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_box_prefers_units():
	# towards the middle of the map, so the camera can centre on the base and the box
	# stays clear of the HUD panels
	var center = _ground(_cc.global_position + Vector3(7, 0, 7))
	var tanks = _spawn_squad(_human, center, 3)
	await _frames(20)
	camera_on(_cc.global_position.lerp(center, 0.5), 16)
	await _frames(5)
	MatchSignals.deselect_all_units.emit()
	# from the command center's middle to just past the tanks
	var from = _cc.global_position + Vector3(-1, 0, -1)
	var to = center + Vector3(4, 0, 3)
	await _drag(MOUSE_BUTTON_LEFT, from, to, false)
	await _frames(12)  # the box preview updates on a timer
	var highlighted_cc = _cc.find_child("Highlight").get("_forced")
	await _shot("1-box-over-tanks-and-base")
	await _release(MOUSE_BUTTON_LEFT, to)
	await _frames(3)
	await _mouse_motion(_screen(center + Vector3(6, 0, -6)))  # off every unit: no hover rings
	await _shot("1b-box-result")
	var selected = get_tree().get_nodes_in_group("selected_units")
	_expect(
		tanks.all(func(tank): return tank in selected),
		"a box over tanks and the base selects the tanks"
	)
	_expect(not _cc in selected, "... but not the command center (units win over buildings)")
	if highlighted_cc != null:
		_expect(not highlighted_cc, "... and the preview does not light the command center")
	# a box around the command center alone still takes it
	MatchSignals.deselect_all_units.emit()
	await _drag(
		MOUSE_BUTTON_LEFT,
		_cc.global_position + Vector3(-2.5, 0, -2.5),
		_cc.global_position + Vector3(2.5, 0, 2.5)
	)
	await _frames(3)
	_expect(_cc.is_in_group("selected_units"), "a box over the base alone selects the base")
	await _cleanup(tanks)


func _check_ctrl_click_selects_type():
	var center = _clear_line_center(_ground(_cc.global_position + Vector3(9, 0, 0)))
	var tanks = _spawn_squad(_human, center, 3)
	var hauler = HaulerScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		hauler, Transform3D(Basis(), _ground(center + Vector3(0, 0, -4))), _human
	)
	await _frames(20)
	camera_on(center, 12)
	await _frames(5)
	MatchSignals.deselect_all_units.emit()
	await _frames(2)
	await _click_with(MOUSE_BUTTON_LEFT, tanks[0].global_position + Vector3.UP * 0.3, true)
	await _frames(3)
	var selected = get_tree().get_nodes_in_group("selected_units")
	_expect(
		tanks.all(func(tank): return tank in selected),
		"Ctrl + click on a tank selects all the tanks on screen (%d selected)" % selected.size()
	)
	_expect(not hauler in selected, "... and not the truck next to them")
	await _shot("2-ctrl-click-all-tanks")
	await _cleanup(tanks + [hauler])


func _check_control_groups():
	var center = _clear_line_center(_ground(_cc.global_position + Vector3(9, 0, 0)))
	var tanks = _spawn_squad(_human, center, 3)
	var hauler = HaulerScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		hauler, Transform3D(Basis(), _ground(center + Vector3(0, 0, -4))), _human
	)
	await _frames(20)
	await _select(tanks)
	await _key_combo(KEY_1, true, false)
	_expect(_groups.units_in_group(1).size() == 3, "Ctrl + 1 puts the 3 tanks in group 1")
	await _select([hauler])
	await _key_combo(KEY_1, false, false)
	var selected = get_tree().get_nodes_in_group("selected_units")
	_expect(
		selected.size() == 3 and tanks.all(func(tank): return tank in selected),
		"1 selects group 1 again"
	)
	await _select([hauler])
	await _key_combo(KEY_1, false, true)
	_expect(_groups.units_in_group(1).size() == 4, "Shift + 1 adds the truck to group 1")
	_expect(hauler.is_in_group("selected_units"), "... and keeps the selection as it was")
	var bar = _match.find_child("ControlGroupBar", true, false)
	bar.flash_s = 5.0  # long enough to see between frames
	await _frames(20)
	var slot = bar.slot(1) if bar != null else null
	_expect(slot != null and slot.visible, "the control group bar shows group 1")
	if slot != null:
		_expect(slot.get_node("Count").text == "4", "... with its 4 units")
		_expect(bar.slot(2) != null and not bar.slot(2).visible, "... and hides empty groups")
	# double tap: the camera goes to the group
	camera_on(_cc.global_position + Vector3(-25, 0, -25), 12)
	await _frames(5)
	var camera = get_viewport().get_camera_3d()
	var group_centre = Vector3.ZERO
	for unit in _groups.units_in_group(1):
		group_centre += unit.global_position * Vector3(1, 0, 1)
	group_centre /= 4.0
	var before = _view_centre(camera).distance_to(group_centre)
	_groups.set("_last_recalled_group", 0)  # the earlier recall does not count as a first tap
	await _key_combo(KEY_1, false, false)
	await _frames(1)
	if slot != null:
		_expect(slot.modulate.r > 1.05, "the slot lights up when the group is recalled")
	await _key_combo(KEY_1, false, false)
	await _frames(3)
	var after = _view_centre(camera).distance_to(group_centre)
	_expect(
		before > 15.0 and after < 2.0,
		"1 pressed twice centres the camera on group 1 (%.1f m -> %.1f m)" % [before, after]
	)
	# a second group, for the screenshot
	await _select(tanks.slice(0, 1))
	await _key_combo(KEY_3, true, false)
	await _frames(10)
	await _shot("3-control-group-bar")
	await _cleanup(tanks + [hauler])


func _view_centre(camera):
	var point = camera.get_ray_intersection(get_viewport().get_visible_rect().size / 2.0)
	return point * Vector3(1, 0, 1) if point != null else Vector3.INF


func _mouse_motion(screen_position):
	VirtualPointer.position = screen_position
	await super(screen_position)


func _key_combo(keycode, ctrl, shift):
	for pressed in [true, false]:
		var event = InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = pressed
		event.ctrl_pressed = ctrl
		event.shift_pressed = shift
		Input.parse_input_event(event)
		await _frames(2)


func _click_with(button, world, ctrl):
	var at = _screen(world)
	await _mouse_motion(at)
	for pressed in [true, false]:
		var event = InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = at
		event.global_position = at
		event.ctrl_pressed = ctrl
		Input.parse_input_event(event)
		await _frames(2)
