extends Node

# Interface sounds, so the menus and the HUD answer the hand:
# - every button clicks when pressed; check boxes, switches and other toggles latch up or
#   down; buttons that close or cancel (by name or text, see back_words) tick lower,
# - the pointer moving onto a button ticks softly, in the menus only (in a match the HUD is
#   under the pointer all the time),
# - an order nobody can carry out knocks (MatchSignals.units_ordered with "cannot"), ahead of
#   the unit's "cannot" voice line,
# - minimap pings blip: two urgent blips when one of the player's units is hit somewhere
#   (hud/MinimapPings.gd), one soft blip when the player marks a spot (hud/Minimap.gd).
# Buttons are found as they enter the tree, so no scene has to wire them; a button with the
# meta "silent" set to true stays quiet. A button only sounds when the player just clicked or
# pressed a key, so menus setting their check boxes from saved settings, a loaded game
# flipping a switch, or a HUD refreshing its chips stay quiet. Levels are in
# data/sounds/interface.json, the sounds come from tools/audio/make_interface_sounds.py.
# Flat, not positional, on the Effects bus.
# Keeps playing while the game is paused, so the pause menu clicks too.

const GameData = preload("res://source/data-model/GameData.gd")

const AUDIO_DIR = "res://assets/audio/interface/"
const VOICES = 4
const INPUT_WINDOW_MS = 250  # a button sounds this long after a click or a key at most
const PRESS_GAP_MS = 30  # a radio group unpressing one button and pressing another: one sound

var played_counts = {}  # sound -> times played (read by tests)

var _config = {}
var _streams = {}  # sound -> [AudioStream]
var _voices = []
var _next_voice = 0
var _last_ms = {}
var _back_words = []
var _last_input_ms = -1e9
var _last_press_ms = -1e9


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	_config = GameData.sounds("interface")
	var sounds = _config.get("sounds", {})
	for sound in sounds:
		_streams[sound] = []
		var variants = int(sounds[sound].get("variants", 1))
		for i in range(1, variants + 1):
			var file = sound + ("_" + str(i) if variants > 1 else "") + ".ogg"
			_streams[sound].append(load(AUDIO_DIR + file))
	for word in _config.get("back_words", []):
		_back_words.append(str(word).to_lower())
	for i in range(VOICES):
		var voice = AudioStreamPlayer.new()
		voice.bus = &"Effects"
		add_child(voice)
		_voices.append(voice)
	get_tree().node_added.connect(_on_node_added)
	MatchSignals.units_ordered.connect(_on_units_ordered)


func play(sound):
	"""plays one of the sounds in data/sounds/interface.json, unless it played too recently"""
	if not _streams.has(sound) or _streams[sound].is_empty():
		return
	var settings = _config["sounds"][sound]
	var now = Time.get_ticks_msec()
	if now - _last_ms.get(sound, -1e9) < float(settings.get("gap_s", 0.0)) * 1000.0:
		return
	_last_ms[sound] = now
	var voice = _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	voice.stream = _streams[sound].pick_random()
	voice.volume_db = linear_to_db(float(settings.get("gain", 0.5)))
	voice.pitch_scale = randf_range(0.97, 1.03)
	voice.play()
	played_counts[sound] = played_counts.get(sound, 0) + 1


func _input(event):
	if (
		event is InputEventMouseButton
		or event is InputEventScreenTouch
		or (event is InputEventKey and event.pressed)
		or (event is InputEventJoypadButton and event.pressed)
	):
		_last_input_ms = Time.get_ticks_msec()


func sound_for(button):
	"""the sound a button makes when pressed (also for tests)"""
	if button.toggle_mode:
		return "toggle_on" if button.button_pressed else "toggle_off"
	var label = str(button.name).to_lower()
	if "text" in button and button.text is String:
		label += " " + button.text.to_lower()
	for word in _back_words:
		if word in label:
			return "back"
	return "click"


func _on_node_added(node):
	if not node is BaseButton:
		return
	if node.toggle_mode:
		node.toggled.connect(_on_button_toggled.bind(node))
	else:
		node.pressed.connect(_on_button_pressed.bind(node))
	node.mouse_entered.connect(_on_button_hovered.bind(node))


func _is_silent(button):
	return not is_instance_valid(button) or button.get_meta("silent", false)


func _on_button_pressed(button):
	_press(button)


func _on_button_toggled(_pressed, button):
	_press(button)


func _press(button):
	var now = Time.get_ticks_msec()
	if _is_silent(button) or now - _last_input_ms > INPUT_WINDOW_MS:
		return  # set from code, not by the player
	if now - _last_press_ms < PRESS_GAP_MS:
		return
	_last_press_ms = now
	play(sound_for(button))


func _on_button_hovered(button):
	if _is_silent(button) or button.disabled:
		return
	if not _config.get("hover_in_match", false) and _in_match():
		return
	play("hover")


func _in_match():
	return get_tree().get_first_node_in_group("match") != null


func _on_units_ordered(_units, order):
	if order == "cannot":
		play("cannot")
