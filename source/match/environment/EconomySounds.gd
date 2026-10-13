extends Node3D

# Feedback of building and the economy, so every action is heard:
# - a clang of stakes and a crate when the player lays out a site, a muted buzz when a
#   building cannot go there, and hammer strikes with a bright chord when one is finished,
# - sites being built hammer, grind and weld; factories with a queue stamp and rattle; power
#   stations and pylons on a live grid hum, lower and rougher when the grid browns out. These
#   are loops mixed from the buildings near the middle of the screen, like the unit presence
#   layers of the Soundscape,
# - goods reaching one of the player's depots near the camera are set down with a small chime.
# The advisor's low-oil and storage-full calls get an alarm chime (VoiceNarratorController).
# Levels are in data/sounds/economy.json, the sounds come from
# tools/audio/make_economy_sounds.py. A child of the Soundscape; positional one-shots are
# heard through the WarSounds listener.

const GameData = preload("res://source/data-model/GameData.gd")
const Structure = preload("res://source/match/units/Structure.gd")

const AUDIO_DIR = "res://assets/audio/economy/"
const REFRESH_S = 0.25
const FADE_PER_S = 1.2
const PITCH_PER_S = 0.3
const SILENT_DB = -60.0
const VOICES = 4
const CLOSE_CAMERA_SIZE = 12.0
const FAR_CAMERA_SIZE = 70.0

var played_counts = {}  # one-shot -> times played (read by tests)
var targets = {}  # loop -> linear gain it fades towards (read by tests)

var _config = {}
var _loops = {}  # loop -> AudioStreamPlayer
var _pitch_targets = {}
var _streams = {}  # one-shot -> [AudioStream]
var _voices = []
var _ui_player = null
var _last_ms = {}
var _progress = {}  # site -> construction progress at the last refresh
var _unit_ids = {}  # scene path -> unit id
var _since_refresh = 0.0
var _pivot = Vector3.ZERO
var _zoom_out = 0.0
var _camera_size = CLOSE_CAMERA_SIZE


func _ready():
	_config = GameData.sounds("economy")
	var loops = _config.get("loops", {})
	for loop in loops:
		var stream = load(AUDIO_DIR + loops[loop]["sound"] + ".ogg")
		stream.loop = true
		var player = AudioStreamPlayer.new()
		player.name = loop.to_pascal_case()
		player.stream = stream
		player.bus = &"Ambience"
		player.volume_db = SILENT_DB
		add_child(player)
		_loops[loop] = player
		targets[loop] = 0.0
	var one_shots = _config.get("one_shots", {})
	for kind in one_shots:
		_streams[kind] = []
		var variants = int(one_shots[kind].get("variants", 1))
		for i in range(1, variants + 1):
			var file = kind + ("_" + str(i) if variants > 1 else "") + ".ogg"
			_streams[kind].append(load(AUDIO_DIR + file))
	for i in range(VOICES):
		var voice = AudioStreamPlayer3D.new()
		voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		voice.panning_strength = 0.6
		voice.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		voice.bus = &"Effects"
		add_child(voice)
		_voices.append(voice)
	_ui_player = AudioStreamPlayer.new()
	_ui_player.bus = &"Effects"
	add_child(_ui_player)
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	MatchSignals.structure_placement_refused.connect(_on_placement_refused)
	MatchSignals.unit_construction_finished.connect(_on_construction_finished)
	MatchSignals.goods_delivered.connect(_on_goods_delivered)


func _process(delta):
	_since_refresh += delta
	if _since_refresh >= REFRESH_S:
		_since_refresh = 0.0
		_update_listener()
		update_loops(_loop_weights())
	for loop in _loops:
		var player = _loops[loop]
		var gain = db_to_linear(player.volume_db) if player.playing else 0.0
		gain = move_toward(gain, targets[loop], FADE_PER_S * delta)
		if gain > 0.0 and not player.playing:
			player.play(randf() * player.stream.get_length())
		elif gain <= 0.0 and player.playing:
			player.stop()
		player.volume_db = max(linear_to_db(gain), SILENT_DB) if gain > 0.0 else SILENT_DB
		if _pitch_targets.has(loop):
			player.pitch_scale = move_toward(
				player.pitch_scale, _pitch_targets[loop], PITCH_PER_S * delta
			)


func update_loops(weights):
	"""sets the loops from {loop: weight} plus {"power_ratio": 0..1} (also for tests)"""
	var loops = _config.get("loops", {})
	var close = 1.0 - _zoom_out
	for loop in _loops:
		var weight = weights.get(loop, 0.0)
		targets[loop] = (
			clamp(log(1.0 + weight * 1.5) / log(10.0), 0.0, 1.0)
			* float(loops[loop].get("gain", 0.4))
			* close
		)
	if "power_hum" in _loops:
		var ratio = clamp(weights.get("power_ratio", 1.0), 0.0, 1.0)
		var brownout_pitch = float(loops["power_hum"].get("brownout_pitch", 1.0))
		_pitch_targets["power_hum"] = lerp(brownout_pitch, 1.0, ratio)


func _loop_weights():
	var hearing_range = float(_config.get("hearing_range_m", 18.0)) + _camera_size * 0.5
	var weights = {}
	var power_ratios = []
	var power_ids = _config.get("power_hum", [])
	var progress = {}
	for structure in get_tree().get_nodes_in_group("units"):
		if not structure is Structure or not structure.visible:
			continue
		var distance = _flat_distance(structure.global_position, _pivot)
		if distance > hearing_range:
			continue
		var closeness = 1.0 - distance / hearing_range
		if structure.is_under_construction():
			var now = structure.get_construction_progress()
			progress[structure] = now
			if now > _progress.get(structure, now):  # someone is building it right now
				weights["construction"] = weights.get("construction", 0.0) + closeness
			continue
		var queue = structure.production_queue
		if queue != null and queue.size() > 0 and structure.power_ratio > 0.0:
			weights["factory"] = weights.get("factory", 0.0) + closeness
		if _unit_id(structure) in power_ids:
			var grid = structure.player.power_grid if structure.player != null else null
			var ratio = grid.get_power_ratio_at(structure.global_position) if grid else 1.0
			if ratio > 0.0:
				weights["power_hum"] = weights.get("power_hum", 0.0) + closeness
				power_ratios.append(ratio)
	_progress = progress
	if not power_ratios.is_empty():
		weights["power_ratio"] = power_ratios.min()
	return weights


func play(kind, at_position = null, loudness = 1.0):
	"""one feedback sound, where it happened (null: on screen, like a UI sound)"""
	var settings = _config.get("one_shots", {}).get(kind)
	if settings == null or _streams.get(kind, []).is_empty():
		return false
	var now = Time.get_ticks_msec()
	if now - _last_ms.get(kind, -100000) < float(settings.get("gap_s", 0.1)) * 1000.0:
		return false
	var gain = float(settings.get("gain", 0.5)) * loudness
	var player = _ui_player
	if at_position != null:
		gain *= _gain_at(at_position)
		player = null
		for voice in _voices:
			if not voice.playing:
				player = voice
				break
		if player == null:
			return false
		player.global_position = at_position
	if gain < 0.03:
		return false
	_last_ms[kind] = now
	var streams = _streams[kind]
	player.stream = streams[randi() % streams.size()]
	player.volume_db = linear_to_db(gain)
	player.pitch_scale = randf_range(0.95, 1.05)
	player.play()
	played_counts[kind] = played_counts.get(kind, 0) + 1
	return true


func _gain_at(at_position):
	var hearing_range = 18.0 + _camera_size * 1.1
	var closeness = clamp(1.0 - _flat_distance(at_position, _pivot) / hearing_range, 0.0, 1.0)
	return closeness * lerp(1.0, 0.4, _zoom_out)


func _update_listener():
	var camera = get_viewport().get_camera_3d()
	if camera == null or not camera.has_method("get_ray_intersection"):
		return
	var pivot = camera.get_ray_intersection(get_viewport().get_visible_rect().size / 2.0)
	if pivot != null:
		_pivot = pivot
	_camera_size = camera.size
	_zoom_out = clamp(inverse_lerp(CLOSE_CAMERA_SIZE, FAR_CAMERA_SIZE, camera.size), 0.0, 1.0)


func _is_human(player):
	var ours = get_tree().get_first_node_in_group("controlled_units")
	return ours != null and player != null and ours.player == player


func _on_unit_spawned(unit):
	if not unit is Structure or not unit.is_in_group("controlled_units"):
		return
	if unit.is_under_construction():  # a new site, not a building handed over
		play("build_place", unit.global_position, 1.0 if unit.has_meta("placed_by_hand") else 0.6)


func _on_placement_refused(player):
	if _is_human(player):
		play("build_refused")


func _on_construction_finished(unit):
	if unit.is_in_group("controlled_units"):
		play("build_complete", unit.global_position)


func _on_goods_delivered(player, _goods):
	if not _is_human(player) or randf() > float(_config.get("deposit_chance", 0.6)):
		return
	var logistics = player.get_node_or_null("Logistics")
	if logistics == null:
		return
	var nearest = null
	for depot in logistics.get_depots():
		var distance = _flat_distance(depot.global_position, _pivot)
		if nearest == null or distance < _flat_distance(nearest.global_position, _pivot):
			nearest = depot
	if nearest != null:
		play("deposit", nearest.global_position)


func _unit_id(unit):
	var scene_path = unit.scene_file_path
	if not _unit_ids.has(scene_path):
		var entry = GameData.unit_by_scene(scene_path)
		_unit_ids[scene_path] = entry["id"] if entry != null else ""
	return _unit_ids[scene_path]


func _flat_distance(a: Vector3, b: Vector3):
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
