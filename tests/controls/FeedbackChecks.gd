extends "res://tests/commands/CommandChecks.gd"

# Bot checks for the feedback layer, through simulated mouse and keyboard events:
# - the selection box draws while dragging, also under the play harness's virtual mouse
#   (generic-scenes-and-nodes/control/RectangularSelection2D.gd),
# - the cursor turns into a red crosshair over an enemy the selection can attack, a build
#   mark over the player's unfinished building with a constructor selected, and the order's
#   crosshair while fight waits for its click (handlers/CursorHandler.gd),
# - an order that cannot be carried out shows a red "no" cursor and a red cross on the spot.
# The OS cursor is not in screenshots, so the checks paint the cursor picture onto them.
# Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 \
#     res://tests/controls/FeedbackChecks.tscn -- --out=/tmp/feedback
# Prints PASS/FAIL lines, saves screenshots to --out and exits with code 1 on failures.

const VirtualPointer = preload("res://source/utils/VirtualPointer.gd")

var _cursor = null


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
	_cursor = get_tree().get_first_node_in_group("cursor_handler")
	_cc = _own(func(unit): return unit is CommandCenter)
	_make_rival_inert()
	_match.fog_of_war.reveal()
	var atmosphere = _match.find_child("Atmosphere", true, false)
	if atmosphere != null:
		atmosphere.set_weather_immediately(&"clear")
		atmosphere.set("_time_to_next_weather", 1.0e9)
	# the play harness's way of pointing: xvfb leaves the real pointer in a corner
	VirtualPointer.active = true
	VirtualPointer.position = get_viewport().get_visible_rect().size / 2.0
	await _check_box_draws()
	_expect(_cursor != null, "the match has a cursor handler")
	if _cursor != null:
		await _check_attack_and_fight_cursor()
		await _check_build_cursor()
		await _check_cannot()
	print("feedback checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_box_draws():
	var center = _ground(_cc.global_position + Vector3(7, 0, 7))
	var tanks = _spawn_squad(_human, center, 3)
	await _frames(20)
	camera_on(center, 14)
	await _frames(5)
	MatchSignals.deselect_all_units.emit()
	var from = center + Vector3(-3, 0, -3)
	var to = center + Vector3(4, 0, 3)
	await _drag(MOUSE_BUTTON_LEFT, from, to, false)
	await _frames(12)
	var box = _match.find_child("RectangularSelection2D", true, false)
	_expect(
		box != null and box.visible and box.size.x > 40 and box.size.y > 20,
		"the selection box draws while dragging (%s)" % [box.size if box != null else null]
	)
	await _shot("1-selection-box")
	await _release(MOUSE_BUTTON_LEFT, to)
	await _frames(3)
	_expect(box == null or not box.visible, "... and goes away on release")
	await _cleanup(tanks)


func _check_attack_and_fight_cursor():
	if not Diplomacy.at_war(_human, _rival):
		Diplomacy.instance.declare_war(_rival, _human)
	var center = _ground(_cc.global_position + Vector3(7, 0, 7))
	var tanks = _spawn_squad(_human, center, 3)
	await _frames(20)
	camera_on(center + Vector3(3, 0, 0), 14)
	await _frames(5)
	await _select(tanks)
	# out of the tanks' range, so it is still there for the screenshot
	var enemy = _spawn_squad(_rival, center + Vector3(10, 0, -2), 1)[0]
	await _frames(3)
	await _mouse_motion(_screen(center + Vector3(0, 0, -6)))
	await _frames(3)
	_expect(_cursor.current == "", "over open ground the cursor is the normal arrow")
	await _mouse_motion(_screen(enemy.global_position + Vector3.UP * 0.3))
	await _frames(3)
	await _wait_for(func(): return _cursor.current == "attack", 30)
	_expect(_cursor.current == "attack", "over an enemy tank it is the red attack crosshair")
	await _shot_with_cursor("2-attack-cursor")
	await _key(KEY_F)
	await _mouse_motion(_screen(center + Vector3(4, 0, 4)))
	await _frames(3)
	_expect(_cursor.current == "fight", "F: the fight crosshair until the click")
	await _shot_with_cursor("3-fight-cursor")
	await _key(KEY_ESCAPE)
	await _frames(3)
	_expect(_cursor.current == "", "Esc: back to the arrow")
	await _cleanup(tanks + [enemy])


func _check_build_cursor():
	var constructor = _own(func(unit): return unit is Worker)
	var spot = _ground(_cc.global_position + Vector3(6, 0, -6))
	var site = PylonScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(site, Transform3D(Basis(), spot), _human)
	await _frames(20)
	_expect(
		constructor != null and not site.is_constructed(), "test setup: a constructor and a site"
	)
	if constructor == null:
		return
	camera_on(spot, 12)
	await _frames(5)
	await _select([constructor])
	await _mouse_motion(_screen(site.global_position + Vector3.UP * 0.3))
	await _frames(3)
	_expect(_cursor.current == "build", "a constructor over an unfinished pylon: the build mark")
	await _shot_with_cursor("4-build-cursor")
	MatchSignals.deselect_all_units.emit()
	await _cleanup([site])


func _check_cannot():
	var center = _ground(_cc.global_position + Vector3(7, 0, 7))
	var tanks = _spawn_squad(_human, center, 2)
	await _frames(20)
	camera_on(center, 14)
	await _frames(5)
	await _select(tanks)
	_cursor.cannot_s = 5.0  # a frame can be slow under a software renderer
	var spot = center + Vector3(3, 0, -4)
	await _mouse_motion(_screen(spot))
	# what UnitActionsController sends when no selected unit can go where it was told
	MatchSignals.terrain_targeted.emit(spot)
	MatchSignals.units_ordered.emit(tanks, "cannot")
	await _frames(2)
	_expect(_cursor.current == "cannot", "an order that cannot be done: the red no sign")
	var marks = _match.get_children().filter(func(node): return node.name.begins_with("CannotMark"))
	_expect(not marks.is_empty(), "... and a red cross on the spot")
	await _shot_with_cursor("5-cannot")
	_cursor.cannot_s = 0.6
	await get_tree().create_timer(5.2).timeout
	await _frames(2)
	_expect(_cursor.current != "cannot", "... for a moment only")
	await _cleanup(tanks)


func _mouse_motion(screen_position):
	VirtualPointer.position = screen_position
	await super(screen_position)


func _shot_with_cursor(name):
	await _shot(name)
	var image = _cursor.image_of(_cursor.current)
	if image == null:
		return
	var path = "{0}/{1}.png".format([_out, name])
	var shot = Image.load_from_file(path)
	shot.convert(Image.FORMAT_RGBA8)
	var at = Vector2i(VirtualPointer.position) - image.get_size() / 2
	shot.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), at)
	shot.save_png(path)
