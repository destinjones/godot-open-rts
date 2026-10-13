extends Node

# The ambient bed under a match, so the world is never silent between voice lines:
# - a tier bed for the city of the player on screen: open air and crickets on the frontier,
#   far-off machinery and hammering once it is industrial, mains hum and traffic when electric.
#   It crossfades when the city reaches a new tier,
# - a tension layer (a low rumble, far booms) and a battle layer (distant gunfire, booms, a
#   siren) on top, following the music's calm/tension/battle state in MusicPlayer, the
#   battle layer swelling with how hot the fighting is. Low oil brings a quiet tension layer.
# The tier bed steps back while the threat layers play. Everything is on the Ambience bus,
# so the Options slider sets it. The levels are in data/sounds/ambience.json and the loops
# come from tools/audio/make_ambient_beds.py. A child of the Soundscape.

const GameData = preload("res://source/data-model/GameData.gd")

const AUDIO_DIR = "res://assets/audio/ambience/"
const REFRESH_S = 0.25
const SILENT_DB = -60.0
const CLOSE_CAMERA_SIZE = 12.0
const FAR_CAMERA_SIZE = 70.0

var tier = 1  # the tier whose bed plays (read by tests)
var music_state = "CALM"
var targets = {}  # layer -> linear gain it fades towards (read by tests)

var _config = {}
var _players = {}  # layer ("tier_1", "tension", "battle", ...) -> AudioStreamPlayer
var _full_gains = {}  # layer -> its gain from the config
var _gains = {}  # layer -> linear gain now
var _since_refresh = REFRESH_S
var _match = null


func _ready():
	_config = GameData.sounds("ambience")
	var tier_beds = _config.get("tier_beds", {})
	for tier_key in tier_beds:
		_add_layer("tier_" + str(tier_key), tier_beds[tier_key])
	var threat_layers = _config.get("threat_layers", {})
	for layer in threat_layers:
		_add_layer(layer, threat_layers[layer])


func _add_layer(layer, entry):
	var path = AUDIO_DIR + entry.get("sound", "") + ".ogg"
	var stream = load(path) if ResourceLoader.exists(path) else null
	if stream == null:
		push_warning("ambient bed: no sound " + path)
		return
	stream.loop = true
	var player = AudioStreamPlayer.new()
	player.name = layer.to_pascal_case()
	player.stream = stream
	player.bus = &"Ambience"
	player.volume_db = SILENT_DB
	add_child(player)
	_players[layer] = player
	_full_gains[layer] = float(entry.get("gain", 0.4))
	_gains[layer] = 0.0
	targets[layer] = 0.0


func _process(delta):
	_since_refresh += delta
	if _since_refresh >= REFRESH_S:
		_since_refresh = 0.0
		var player = _player_on_screen()
		update_targets(
			MusicPlayer.state_name(),
			MusicPlayer.intensity(),
			player.get_tier() if player != null else 1,
			player.oil if player != null else 1000,
			_zoom_out()
		)
	_fade(delta)


func update_targets(state_name, intensity, a_tier, oil, zoom_out = 0.0):
	"""sets the gain each layer fades towards; called on a timer and by tests"""
	var levels_by_state = _config.get("levels", {})
	var levels = levels_by_state.get(state_name, levels_by_state.get("CALM", {}))
	music_state = state_name if state_name in levels_by_state else "CALM"
	tier = a_tier
	var bed_key = ""  # the bed of the highest tier up to this one (a mod may add tiers)
	for layer in _players:
		var bed_tier = int(layer.substr(5)) if layer.begins_with("tier_") else 0
		if (
			bed_tier > 0
			and bed_tier <= a_tier
			and (bed_key == "" or bed_tier > int(bed_key.substr(5)))
		):
			bed_key = layer
	var zoom_gain = lerp(1.0, float(_config.get("zoomed_out_gain", 1.0)), zoom_out)
	var tension_level = float(levels.get("tension", 0.0))
	var low_oil = _config.get("low_oil", {})
	if a_tier >= int(low_oil.get("from_tier", 2)) and oil < float(low_oil.get("below", 0)):
		tension_level = max(tension_level, float(low_oil.get("tension", 0.0)))
	var battle_level = float(levels.get("battle", 0.0)) * lerp(0.7, 1.0, clamp(intensity, 0, 1))
	for layer in _players:
		var level = 0.0
		if layer == bed_key:
			level = float(levels.get("tier", 1.0))
		elif layer == "tension":
			level = tension_level
		elif layer == "battle":
			level = battle_level
		targets[layer] = _full_gains[layer] * level * zoom_gain


func _fade(delta):
	for layer in _players:
		var target = targets[layer]
		var gain = _gains[layer]
		if is_equal_approx(gain, target) and (target > 0.0 or not _players[layer].playing):
			continue
		var kind = "tier" if layer.begins_with("tier_") else layer
		var fades = _config.get("fade_in_s" if target > gain else "fade_out_s", {})
		var seconds = max(float(fades.get(kind, 3.0)), 0.05)
		gain = move_toward(gain, target, _full_gains[layer] / seconds * delta)
		_gains[layer] = gain
		var player = _players[layer]
		if gain > 0.0 and not player.playing:
			player.play(randf() * player.stream.get_length())
		elif gain <= 0.0 and player.playing:
			player.stop()
		player.volume_db = max(linear_to_db(gain), SILENT_DB) if gain > 0.0 else SILENT_DB


func _player_on_screen():
	if _match == null or not is_instance_valid(_match):
		_match = get_parent()
		while _match != null and not "visible_player" in _match:
			_match = _match.get_parent()
	if _match == null:
		return null
	var player = _match.visible_player
	return player if is_instance_valid(player) else null


func _zoom_out():
	var camera = get_viewport().get_camera_3d()
	if camera == null or not camera.has_method("get_ray_intersection"):
		return 0.0
	return clamp(inverse_lerp(CLOSE_CAMERA_SIZE, FAR_CAMERA_SIZE, camera.size), 0.0, 1.0)
