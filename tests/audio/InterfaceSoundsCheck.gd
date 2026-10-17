extends Node

# Checks the interface sounds (source/audio/InterfaceSounds.gd): buttons click, close and
# cancel buttons tick lower, toggles latch, a silent button stays quiet, a toggle set by code
# (not the player) stays quiet, a radio group sounds once, hover ticks in the
# menus but not in a match, an order nobody can carry out knocks (once, not per click in a
# burst), and minimap pings blip for a hit and a mark.
# Usage (needs a real renderer for the match, e.g. under xvfb-run):
#   godot --path . res://tests/audio/InterfaceSoundsCheck.tscn
# Exits with 1 on a failure.

var _failures = []


func _ready():
	var sounds = InterfaceSounds
	var menu = load("res://source/main-menu/Main.tscn").instantiate()
	add_child(menu)
	await _frames(2)
	var quit = menu.find_child("Button4", true, false)
	_expect(quit != null and sounds.sound_for(quit) == "back", "the menu's quit ticks as a back")
	var play = menu.find_child("Button", true, false)
	_expect(play != null and sounds.sound_for(play) == "click", "the menu's play clicks")
	_expect(
		play != null and play.mouse_entered.get_connections().size() > 0,
		"menu buttons are wired as they enter the tree"
	)
	menu.queue_free()

	var check = CheckBox.new()
	add_child(check)
	check.button_pressed = true  # as a menu restoring a saved setting
	_expect(_count("toggle_on") == 0, "a toggle set by code stays quiet")
	check.button_pressed = false

	var button = Button.new()
	button.text = "OK"
	add_child(button)
	_click()
	button.pressed.emit()
	_expect(_count("click") == 1, "a button clicks")
	var cancel = Button.new()
	cancel.text = "CANCEL"
	add_child(cancel)
	await _frames(3)  # past the gap between two presses
	_click()
	cancel.pressed.emit()
	_expect(_count("back") == 1, "a cancel button ticks lower")
	await _frames(3)
	_click()
	check.button_pressed = true
	_expect(_count("toggle_on") == 1, "a check box latches on")
	await _frames(3)
	_click()
	check.button_pressed = false
	_expect(_count("toggle_off") == 1, "and off")
	var group = ButtonGroup.new()
	var radios = []
	for i in range(2):
		var radio = CheckBox.new()
		radio.button_group = group
		add_child(radio)
		radios.append(radio)
	radios[0].button_pressed = true
	await _frames(3)
	var before = _count("toggle_on") + _count("toggle_off")
	_click()
	radios[1].button_pressed = true  # unpresses the first one too
	_expect(_count("toggle_on") + _count("toggle_off") == before + 1, "a radio group sounds once")
	var quiet = Button.new()
	quiet.set_meta("silent", true)
	add_child(quiet)
	sounds._last_ms.clear()
	await _frames(3)
	_click()
	quiet.pressed.emit()
	_expect(_count("click") == 1, "a silent button stays quiet")
	button.mouse_entered.emit()
	_expect(_count("hover") == 1, "hover ticks in the menus")

	var match_node = load("res://tests/manual/TestDesert.tscn").instantiate()
	add_child(match_node)
	await _frames(20)
	sounds._last_ms.clear()
	button.mouse_entered.emit()
	_expect(_count("hover") == 1, "hover stays quiet in a match")

	var own = get_tree().get_nodes_in_group("controlled_units")
	for i in range(3):
		MatchSignals.units_ordered.emit(own, "cannot")
	_expect(_count("cannot") == 1, "an order nobody can carry out knocks, once for a burst")
	MatchSignals.units_ordered.emit(own, "move")
	_expect(_count("cannot") == 1, "an order carried out does not")

	var pings = match_node.find_child("MinimapPings", true, false)
	var minimap = match_node.find_child("Minimap", true, false)
	_expect(pings != null and minimap != null, "the match has a minimap with pings")
	if pings != null and not own.is_empty():
		var enemy = get_tree().get_nodes_in_group("players").filter(
			func(player): return player != own[0].player
		)
		own[0].last_attacker_player = enemy[0]
		pings._on_unit_damaged(own[0])
		_expect(_count("ping_attack") == 1, "a hit on one of the player's units blips")
	if minimap != null:
		minimap._mark_spot(Vector2(10, 10))
		_expect(_count("ping_mark") == 1, "marking a spot blips")
	_finish()


func _click():
	var event = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	InterfaceSounds._input(event)


func _count(sound):
	return InterfaceSounds.played_counts.get(sound, 0)


func _finish():
	for failure in _failures:
		print("FAIL: ", failure)
	print("InterfaceSoundsCheck: {0}".format(["ok" if _failures.is_empty() else "FAILED"]))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _frames(count):
	for i in range(count):
		await get_tree().process_frame


func _expect(condition, what):
	if not condition:
		_failures.append(what)
