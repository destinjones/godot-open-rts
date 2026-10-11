extends "res://tests/commands/CommandChecks.gd"

# Bot checks for the camera controls, through simulated mouse events:
# - the mouse wheel zooms smoothly (the size glides, it does not jump) and towards the
#   cursor: the ground under the cursor stays under it (IsometricCamera3D.gd),
# - edge scrolling eases in and out instead of starting and stopping dead,
# - keys held while a text field has focus (W, A, S, D typed into a search box) do not
#   pan or rotate the map,
# - Alt + click on the minimap pings that spot without moving the camera; a plain click
#   still jumps there; a hit on one of the player's units pings the minimap red, once per
#   spot (hud/MinimapPings.gd).
# Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 \
#     res://tests/controls/CameraChecks.tscn -- --out=/tmp/camera
# Prints PASS/FAIL lines, saves screenshots to --out and exits with code 1 on failures.

const VirtualPointer = preload("res://source/utils/VirtualPointer.gd")

var _camera = null


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
	_cc = _own(func(unit): return unit is CommandCenter)
	_camera = get_viewport().get_camera_3d()
	_make_rival_inert()
	_match.fog_of_war.reveal()
	VirtualPointer.active = true
	VirtualPointer.position = get_viewport().get_visible_rect().size / 2.0
	await _check_zoom_to_cursor()
	await _check_edge_scroll_eases()
	await _check_minimap_pings()
	await _check_typing_does_not_pan()
	print("camera checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_zoom_to_cursor():
	camera_on(_ground(_cc.global_position + Vector3(10, 0, 10)), 16)
	await _frames(5)
	var size_before = _camera.size
	var at = Vector2(300, 220)  # well off the centre of the 1280x720 view
	await _mouse_motion(at)
	var ground_before = _camera.get_ray_intersection(at)
	await _shot("0-zoom-start")
	for _i in range(3):
		await _wheel(MOUSE_BUTTON_WHEEL_UP, at)
	var right_after = _camera.size
	await get_tree().create_timer(1.0).timeout
	await _frames(3)
	await _shot("0-zoom-end")
	var drift = (_camera.get_ray_intersection(at) - ground_before) * Vector3(1, 0, 1)
	_expect(
		is_equal_approx(_camera.size, size_before - 3),
		"three wheel notches zoom in by 3 (%.1f -> %.1f)" % [size_before, _camera.size]
	)
	_expect(
		right_after > _camera.size + 0.1,
		"the zoom glides: just after the wheel the size was still %.2f" % right_after
	)
	_expect(
		drift.length() < 0.5,
		"the ground under the cursor stays under it (moved %.2f m)" % drift.length()
	)


func _check_edge_scroll_eases():
	camera_on(_ground(_cc.global_position + Vector3(10, 0, 10)), 16)
	await _frames(5)
	var steps = []
	var last = _camera.global_position
	# straight to the edge, without waiting frames, so the very first steps are measured
	VirtualPointer.position = Vector2(0, 360)  # the left edge
	for _i in range(20):
		await get_tree().physics_frame
		steps.append((_camera.global_position - last).length())
		last = _camera.global_position
	VirtualPointer.position = Vector2(640, 360)
	var coast = []
	for _i in range(20):
		await get_tree().physics_frame
		coast.append((_camera.global_position - last).length())
		last = _camera.global_position
	var first = steps.filter(func(step): return step > 0.0)
	_expect(
		not first.is_empty() and first[0] < steps.max() * 0.7,
		(
			"edge scrolling starts gently (first step %.3f m, full speed %.3f m)"
			% [first[0] if not first.is_empty() else 0.0, steps.max()]
		)
	)
	_expect(
		coast[0] > 0.0 and coast.back() == 0.0,
		"... and coasts to a stop when the mouse leaves the edge (%.3f m, then 0)" % coast[0]
	)


func _check_minimap_pings():
	var minimap = _match.find_child("Minimap", true, false)
	var rect = minimap.find_child("MinimapTextureRect")
	var pings = minimap.find_child("MinimapPings", true, false)
	_expect(pings != null, "the minimap has a ping layer")
	if pings == null:
		return
	camera_on(_ground(_cc.global_position + Vector3(10, 0, 10)), 16)
	await _frames(5)
	var camera_before = _camera.global_position
	var spot = rect.get_global_rect().get_center()
	await _mouse_motion(spot)
	await _alt_click(spot)
	_expect(not pings.pings.is_empty(), "Alt + click on the minimap pings that spot")
	_expect(_camera.global_position.distance_to(camera_before) < 0.01, "... and the camera stays")
	await _shot("1-minimap-mark")
	pings.pings.clear()
	# an enemy hit on one of the player's buildings
	if not Diplomacy.at_war(_human, _rival):
		Diplomacy.instance.declare_war(_rival, _human)
	var enemy = _spawn_squad(_rival, _ground(_cc.global_position + Vector3(30, 0, 30)), 1)[0]
	await _frames(5)
	_cc.take_damage(1, enemy)
	await _frames(2)
	_expect(
		pings.pings.size() == 1 and pings.pings[0]["color"] == pings.ATTACK_COLOR,
		"a hit on the command center pings the minimap red"
	)
	await _shot("2-minimap-attack")
	_cc.take_damage(1, enemy)
	await _frames(2)
	_expect(pings.pings.size() == 1, "... once: more hits there do not add pings")
	await _cleanup([enemy])


func _check_typing_does_not_pan():
	camera_on(_ground(_cc.global_position + Vector3(10, 0, 10)), 16)
	VirtualPointer.position = get_viewport().get_visible_rect().size / 2.0
	var field = LineEdit.new()
	_match.find_child("HUD").add_child(field)
	field.grab_focus()
	await _frames(5)
	var before = _camera.global_position
	Input.action_press("move_map_right")
	await _frames(10)
	var typing_moved = _camera.global_position.distance_to(before)
	field.release_focus()
	await _frames(10)
	Input.action_release("move_map_right")
	var free_moved = _camera.global_position.distance_to(before)
	field.queue_free()
	_expect(
		typing_moved < 0.01,
		"D held while typing in a text field leaves the map still (%.2f m)" % typing_moved
	)
	_expect(free_moved > 0.1, "... and pans it once the field lets go (%.2f m)" % free_moved)


func _mouse_motion(screen_position):
	VirtualPointer.position = screen_position
	await super(screen_position)


func _wheel(button, at):
	for pressed in [true, false]:
		var event = InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = at
		event.global_position = at
		Input.parse_input_event(event)
	await get_tree().process_frame


func _alt_click(at):
	for pressed in [true, false]:
		var event = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = at
		event.global_position = at
		event.alt_pressed = true
		Input.parse_input_event(event)
		await _frames(2)
