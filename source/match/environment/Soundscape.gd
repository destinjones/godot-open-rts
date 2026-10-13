extends Node

# Ambient sound of a match, mixed from where the camera looks:
# - wind, louder with the weather's wind and when zoomed out, howling in sandstorms,
# - rain while it rains,
# - the units near the middle of the screen, so none of them is ever silent: tank diesels and
#   tracks, wheeled engines, footsteps, helicopter rotors and downwash, drone propellers. Each
#   layer is mixed from how many units use it nearby; units on the move play the running loop,
#   units at rest an idle loop (or the same loop slower and quieter). The player's units key
#   their radios now and then, more often as the fighting heats up. Which unit makes which
#   sound is in data/sounds/units.json,
# - the noise of the nearest city, fading out with distance and as the camera zooms out,
# - a trade horn when a trade deal goes through or goods reach a depot near the camera.
# The sounds are synthesized by tools/audio/make_soundscape.py, make_war_sounds.py and
# make_unit_presence.py.
# Weapon fire and explosions are WarSounds, a child of this node. Under it all runs the
# AmbientBed, another child: a bed per city tier with threat layers that follow the music.

const WarSounds = preload("res://source/match/environment/WarSounds.gd")
const AmbientBed = preload("res://source/match/environment/AmbientBed.gd")
const GameData = preload("res://source/data-model/GameData.gd")

const AUDIO_DIR = "res://assets/audio/ambience/"
const SOUNDS_DIR = "res://assets/audio/"
const REFRESH_S = 0.25
const FADE_PER_S = 1.5  # how fast volumes follow their targets (linear gain per second)
const PITCH_PER_S = 0.4  # how fast a presence loop's pitch follows (engines rev up and down)
const CITY_HEARING_RANGE_M = 45.0
const ENGINE_HEARING_RANGE_M = 16.0  # when zoomed in; grows with the camera size
const CHATTER_VOICES = 2
const CLOSE_CAMERA_SIZE = 12.0
const FAR_CAMERA_SIZE = 70.0
const HORN_COOLDOWN_S = 9.0
const SILENT_DB = -60.0

var chatter_count = 0  # radio chatter played so far (read by tests)

var _players = {}  # name -> AudioStreamPlayer
var _targets = {}  # name -> linear gain the player fades towards
var _pitch_targets = {}  # presence loop name -> pitch scale it glides towards
var _since_refresh = 0.0
var _horn_cooldown = 0.0
var _pivot = Vector3.ZERO
var _zoom_out = 0.0  # 0 close to the ground, 1 fully zoomed out
var _camera_size = CLOSE_CAMERA_SIZE
var _presence = {}  # data/sounds/units.json
var _layer_players = {}  # presence layer -> {"moving": loop name, "idle": loop name or ""}
var _unit_layers = {}  # scene path -> presence layers of the unit
var _chatter_streams = []
var _chatter_voices = []
var _chatter_in = 5.0  # seconds to the next radio chatter


func _ready():
	for sound_name in ["wind_loop", "rain_loop", "city_loop"]:
		var stream = load(AUDIO_DIR + sound_name + ".ogg")
		stream.loop = true
		_add_player(sound_name, stream, true)
	_presence = GameData.sounds("units")
	var layers = _presence.get("layers", {})
	for layer in layers:
		_layer_players[layer] = {}
		for kind in ["moving", "idle"]:
			var path = layers[layer].get(kind, "")
			var sound_name = path.get_file()
			if path == "" or sound_name in _players:
				_layer_players[layer][kind] = sound_name
				continue
			var stream = load(SOUNDS_DIR + path + ".ogg")
			stream.loop = true
			_add_player(sound_name, stream, true)
			_layer_players[layer][kind] = sound_name
	for path in _presence.get("chatter", {}).get("sounds", []):
		_chatter_streams.append(load(SOUNDS_DIR + path + ".ogg"))
	for i in range(CHATTER_VOICES):
		var voice = AudioStreamPlayer3D.new()
		voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		voice.panning_strength = 0.6
		voice.bus = &"Voices"
		add_child(voice)
		_chatter_voices.append(voice)
	var war_sounds = WarSounds.new()
	war_sounds.name = "WarSounds"
	add_child(war_sounds)
	var bed = AmbientBed.new()
	bed.name = "AmbientBed"
	add_child(bed)
	_add_player("trade_horn", load(AUDIO_DIR + "trade_horn.ogg"), false)
	MatchSignals.trade_completed.connect(_on_trade_completed)
	MatchSignals.goods_delivered.connect(_on_goods_delivered)


func _add_player(sound_name, stream, looping):
	var player = AudioStreamPlayer.new()
	player.name = sound_name.to_pascal_case()
	player.stream = stream
	player.volume_db = SILENT_DB
	player.bus = &"Ambience" if looping else &"Effects"  # see default_bus_layout.tres
	add_child(player)
	if looping:
		player.play(randf() * stream.get_length())
	_players[sound_name] = player
	_targets[sound_name] = 0.0


func _process(delta):
	_horn_cooldown = max(_horn_cooldown - delta, 0.0)
	_since_refresh += delta
	if _since_refresh >= REFRESH_S:
		_since_refresh = 0.0
		_update_listener()
		_update_targets()
		_chatter_in -= REFRESH_S
		if _chatter_in <= 0.0:
			_chatter()
	for sound_name in _targets:
		if sound_name == "trade_horn":
			continue
		var player = _players[sound_name]
		var gain = db_to_linear(player.volume_db)
		gain = move_toward(gain, _targets[sound_name], FADE_PER_S * delta)
		player.volume_db = max(linear_to_db(gain), SILENT_DB)
		if _pitch_targets.has(sound_name):
			player.pitch_scale = move_toward(
				player.pitch_scale, _pitch_targets[sound_name], PITCH_PER_S * delta
			)


func _update_listener():
	var camera = get_viewport().get_camera_3d()
	if camera == null or not camera.has_method("get_ray_intersection"):
		return
	var pivot = camera.get_ray_intersection(get_viewport().get_visible_rect().size / 2.0)
	if pivot != null:
		_pivot = pivot
	_zoom_out = clamp(inverse_lerp(CLOSE_CAMERA_SIZE, FAR_CAMERA_SIZE, camera.size), 0.0, 1.0)
	_camera_size = camera.size


func _update_targets():
	var atmosphere = get_tree().get_first_node_in_group("atmosphere")
	var wind_speed = 1.0
	var rain = 0.0
	var dust = 0.0
	if atmosphere != null:
		wind_speed = atmosphere.get_wind().length()
		rain = atmosphere.get_rain_intensity()
		dust = atmosphere.get_dust_intensity()
	_targets["wind_loop"] = clamp(
		0.12 + wind_speed * 0.05 + _zoom_out * 0.18 + dust * 0.45, 0.0, 0.85
	)
	_targets["rain_loop"] = rain * lerp(0.7, 0.4, _zoom_out)
	var close = 1.0 - _zoom_out
	_targets["city_loop"] = _city_closeness() * close * 0.6
	update_presence(_presence_weights())


func _city_closeness():
	var closest = INF
	for depot in _depots():
		closest = min(closest, _flat_distance(depot.global_position, _pivot))
	return clamp(1.0 - closest / CITY_HEARING_RANGE_M, 0.0, 1.0)


func update_presence(weights):
	"""sets the presence loops from {layer: [moving weight, resting weight]} (also for tests)"""
	var layers = _presence.get("layers", {})
	for sound_name in _pitch_targets:
		_targets[sound_name] = 0.0
	for layer in _layer_players:
		var config = layers[layer]
		var moving = weights.get(layer, [0.0, 0.0])[0]
		var resting = weights.get(layer, [0.0, 0.0])[1]
		var gain = float(config.get("gain", 0.5))
		gain *= lerp(1.0, float(config.get("zoomed_out", 0.0)), _zoom_out)
		var idle_share = float(config.get("idle_share", 0.0))
		var moving_loop = _layer_players[layer]["moving"]
		var idle_loop = _layer_players[layer].get("idle", "")
		if idle_loop != "":
			_targets[moving_loop] += _loudness(moving) * gain
			_targets[idle_loop] += _loudness(resting * idle_share) * gain
			_pitch_targets[idle_loop] = 1.0
			_pitch_targets[moving_loop] = 1.0
		else:
			_targets[moving_loop] += _loudness(moving + resting * idle_share) * gain
			var share = moving / (moving + resting) if moving + resting > 0.0 else 1.0
			_pitch_targets[moving_loop] = lerp(float(config.get("idle_pitch", 1.0)), 1.0, share)
	for sound_name in _pitch_targets:
		_targets[sound_name] = min(_targets[sound_name], 1.0)


func _presence_weights():
	"""layer -> [moving, resting]: the units near the middle of the screen that make it,
	nearer ones counting more"""
	var hearing_range = ENGINE_HEARING_RANGE_M + _camera_size * 0.5
	var weights = {}
	for unit in get_tree().get_nodes_in_group("units"):
		if not unit.visible:
			continue
		var distance = _flat_distance(unit.global_position, _pivot)
		if distance > hearing_range:
			continue
		var layers = _layers_of(unit)
		if layers.is_empty():
			continue
		var movement = unit.find_child("Movement", false, false)
		var moving = movement != null and movement.velocity.length_squared() > 0.01
		var closeness = 1.0 - distance / hearing_range
		for layer in layers:
			if not layer in _layer_players:
				continue
			var weight = weights.get(layer, [0.0, 0.0])
			weight[0 if moving else 1] += closeness
			weights[layer] = weight
	return weights


func _layers_of(unit):
	"""presence layers of a unit from data/sounds/units.json; structures make none"""
	var scene_path = unit.scene_file_path
	if not _unit_layers.has(scene_path):
		var layers = []
		var entry = GameData.unit_by_scene(scene_path)
		var is_structure = entry != null and entry.get("category") == "structure"
		if not is_structure and not unit.is_in_group("structures"):
			var by_unit = _presence.get("units", {})
			var id = entry["id"] if entry != null else ""
			layers = by_unit.get(id, _presence.get("default_vehicle", []))
		_unit_layers[scene_path] = layers
	return _unit_layers[scene_path]


func _loudness(weight):
	"""many units are louder than one, but not many times louder"""
	return clamp(log(1.0 + weight * 1.5) / log(10.0), 0.0, 1.0)


func _chatter():
	var config = _presence.get("chatter", {})
	var every = config.get("every_s", {})
	var range_s = every.get(MusicPlayer.state_name(), every.get("CALM", [9.0, 18.0]))
	_chatter_in = randf_range(range_s[0], range_s[1])
	if _chatter_streams.is_empty() or _zoom_out > 0.6:
		return
	var hearing_range = float(config.get("range_m", 30.0))
	var talkers = []
	for unit in get_tree().get_nodes_in_group("controlled_units"):
		if (
			"chatter" in _layers_of(unit)
			and _flat_distance(unit.global_position, _pivot) < hearing_range
		):
			talkers.append(unit)
	if talkers.is_empty():
		return
	var unit = talkers[randi() % talkers.size()]
	var voice = null
	for candidate in _chatter_voices:
		if not candidate.playing:
			voice = candidate
	if voice == null:
		return
	var closeness = 1.0 - _flat_distance(unit.global_position, _pivot) / hearing_range
	voice.stream = _chatter_streams[randi() % _chatter_streams.size()]
	voice.global_position = unit.global_position
	voice.volume_db = linear_to_db(float(config.get("gain", 0.3)) * (0.5 + 0.5 * closeness))
	voice.pitch_scale = randf_range(0.94, 1.06)
	voice.play()
	chatter_count += 1


func _depots():
	var depots = []
	for player in get_tree().get_nodes_in_group("players"):
		var logistics = player.get_node_or_null("Logistics")
		if logistics != null:
			depots.append_array(logistics.get_depots())
	return depots


func _flat_distance(a: Vector3, b: Vector3):
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


func _sound_horn(at_position, loudness):
	if _horn_cooldown > 0.0:
		return
	var distance = _flat_distance(at_position, _pivot)
	var gain = loudness * clamp(1.0 - distance / CITY_HEARING_RANGE_M, 0.0, 1.0)
	gain *= lerp(1.0, 0.35, _zoom_out)
	if gain < 0.05:
		return
	_horn_cooldown = HORN_COOLDOWN_S
	var horn = _players["trade_horn"]
	horn.volume_db = linear_to_db(gain)
	horn.pitch_scale = randf_range(0.94, 1.06)
	horn.play()


func _on_trade_completed(proposer, partner, _offered, _requested):
	# heard at whichever of the two trading cities is closer to the camera
	var closest = null
	for player in [proposer, partner]:
		var logistics = player.get_node_or_null("Logistics") if player != null else null
		if logistics == null:
			continue
		for depot in logistics.get_depots():
			var distance = _flat_distance(depot.global_position, _pivot)
			if closest == null or distance < _flat_distance(closest, _pivot):
				closest = depot.global_position
	if closest != null:
		_sound_horn(closest, 0.8)


func _on_goods_delivered(player, _goods):
	var logistics = player.get_node_or_null("Logistics") if player != null else null
	if logistics == null or randf() > 0.3:
		return
	var depots = logistics.get_depots()
	if not depots.is_empty():
		_sound_horn(depots[0].global_position, 0.35)
