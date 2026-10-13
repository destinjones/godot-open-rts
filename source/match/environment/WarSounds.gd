extends Node3D

# Sounds of battle: a report for every weapon type, spent casings, impacts that sound like what
# was hit, explosions with their echo rolling back, and a death that matches the unit's size.
#
# Nothing in the combat code has to call this. It watches the scene tree: a projectile node
# being added to a unit means that unit just fired, a rocket leaving the tree means it hit,
# and a unit leaving the tree with no hp left means it was destroyed.
#
# Which unit fires which weapon, what a round sounds like on infantry, armour or a building,
# and the layers of each kind of death are in data/sounds/combat.json.
#
# Sounds are heard from where the camera looks, like the ambient Soundscape: loudness falls
# with the distance from the middle of the screen, the hearing range grows as the camera zooms
# out, and everything gets quieter the further out the camera is. A listener placed above the
# middle of the screen pans each sound to the side of the screen it comes from. Far sounds and
# fights in the fog of war are heard muffled, through the EffectsFar bus. Casings are only
# heard zoomed in. The sounds come from tools/audio/make_war_sounds.py and
# make_combat_sounds.py.
#
# In a crowd, sounds compete (data/sounds/mix.json): once a handful have played in the same
# instant, a quiet, low-priority one is dropped instead of adding to the mush, and when every
# voice is busy the lowest-priority, quietest one is the one cut off.

const Unit = preload("res://source/match/units/Unit.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const CannonShell = preload("res://source/match/units/projectiles/CannonShell.gd")
const Rocket = preload("res://source/match/units/projectiles/Rocket.gd")

const GameData = preload("res://source/data-model/GameData.gd")

const AUDIO_DIR = "res://assets/audio/war/"
const VOICES = 24
const CLOSE_CAMERA_SIZE = 12.0
const FAR_CAMERA_SIZE = 70.0
const SHELL_SPEED_M_PER_S = 160.0
const HIDDEN_GAIN = 0.4  # neither side of the fight is visible
const MIN_GAIN = 0.03
const CASING_DELAY_S = 0.22

var played_counts = {}  # kind -> sounds played so far (read by tests)
var masked_count = 0  # sounds dropped because a crowd of louder ones covered them (tests)

var _config = {}  # data/sounds/combat.json
var _kinds = {}  # kind -> {gain, max, gap_s}
var _unit_ids = {}  # scene path -> unit id ("" if not in data/units)
var _streams = {}  # kind -> [AudioStream]
var _voices = []
var _voice_kinds = {}  # player -> kind it is playing
var _voice_priorities = {}  # player -> priority of what it is playing
var _mix = {}  # data/sounds/mix.json
var _recent = []  # [[ticks ms, gain]] of the sounds played in the density window
var _far_bus = &"Effects"
var _last_played_ms = {}  # kind -> ticks
var _listener = AudioListener3D.new()
var _pivot = Vector3.ZERO
var _zoom_out = 0.0
var _camera_size = 20.0


func _ready():
	_config = GameData.sounds("combat")
	_mix = GameData.sounds("mix")
	var far_bus = _mix.get("far_bus", "")
	if far_bus != "" and AudioServer.get_bus_index(far_bus) != -1:
		_far_bus = StringName(far_bus)
	_kinds = _config.get("kinds", {})
	for kind in _kinds:
		_streams[kind] = []
		for i in range(1, int(_kinds[kind].get("variants", 1)) + 1):
			var path = "{0}{1}_{2}.ogg".format([AUDIO_DIR, kind, i])
			if ResourceLoader.exists(path):
				_streams[kind].append(load(path))
		if _streams[kind].is_empty():
			push_warning("war sounds: no file for " + kind)
			_kinds.erase(kind)
	for i in range(VOICES):
		var voice = AudioStreamPlayer3D.new()
		voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		voice.max_distance = 0.0
		voice.panning_strength = 0.7
		voice.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		voice.bus = &"Effects"
		add_child(voice)
		_voices.append(voice)
	add_child(_listener)
	_listener.make_current()
	get_tree().node_added.connect(_on_node_added)


func _process(_delta):
	var camera = get_viewport().get_camera_3d()
	if camera == null or not camera.has_method("get_ray_intersection"):
		return
	var pivot = camera.get_ray_intersection(get_viewport().get_visible_rect().size / 2.0)
	if pivot != null:
		_pivot = pivot
	_camera_size = camera.size
	_zoom_out = clamp(inverse_lerp(CLOSE_CAMERA_SIZE, FAR_CAMERA_SIZE, camera.size), 0.0, 1.0)
	# the listener hovers over the middle of the screen, facing the way the camera faces,
	# so a shot on the left of the screen is heard on the left
	var forward = -camera.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.0001:
		_listener.global_transform = Transform3D(
			Basis.looking_at(forward.normalized(), Vector3.UP), _pivot + Vector3(0.0, 6.0, 0.0)
		)


func play(kind, at_position, loudness = 1.0, audible = true, pitch = 1.0):
	"""plays one sound of a kind at a world position; returns false if it was not heard"""
	if not kind in _kinds:
		return false
	var now = Time.get_ticks_msec()
	var settings = _kinds[kind]
	if now - _last_played_ms.get(kind, -100000) < float(settings.get("gap_s", 0.05)) * 1000.0:
		return false
	var closeness = _closeness(at_position)
	var gain = float(settings.get("gain", 0.5)) * loudness * _gain_at(at_position)
	if not audible:
		gain *= HIDDEN_GAIN
	if gain < MIN_GAIN:
		return false
	var priority = int(settings.get("priority", 1))
	if _masked(now, gain, priority):
		masked_count += 1
		return false
	var voice = _pick_voice(kind, int(settings.get("max", 3)), gain, priority)
	if voice == null:
		return false
	_last_played_ms[kind] = now
	_recent.append([now, gain])
	_voice_kinds[voice] = kind
	_voice_priorities[voice] = priority
	var far = not audible or closeness < 1.0 - float(_mix.get("far_from", 0.45))
	voice.bus = _far_bus if far else &"Effects"
	var streams = _streams[kind]
	voice.stream = streams[randi() % streams.size()]
	voice.global_position = at_position
	voice.volume_db = linear_to_db(gain)
	voice.pitch_scale = pitch * randf_range(0.9, 1.08)
	voice.play()
	played_counts[kind] = played_counts.get(kind, 0) + 1
	return true


func _closeness(at_position):
	"""1 in the middle of the screen, 0 at the edge of hearing"""
	var hearing_range = 18.0 + _camera_size * 1.1
	var distance = Vector2(at_position.x, at_position.z).distance_to(Vector2(_pivot.x, _pivot.z))
	return clamp(1.0 - distance / hearing_range, 0.0, 1.0)


func _gain_at(at_position):
	var closeness = _closeness(at_position)
	return closeness * closeness * lerp(1.0, 0.3, _zoom_out)


func _masked(now, gain, priority):
	"""in a crowd of sounds, a quiet one of low priority would only add mush"""
	var window_ms = float(_mix.get("density_window_s", 0.15)) * 1000.0
	_recent = _recent.filter(func(entry): return now - entry[0] < window_ms)
	if _recent.size() < int(_mix.get("density_max", 6)):
		return false
	if priority >= int(_mix.get("keep_priority", 3)):
		return false
	var loudest = 0.0
	for entry in _recent:
		loudest = max(loudest, entry[1])
	return gain < loudest * float(_mix.get("mask_below", 0.5))


func _pick_voice(kind, max_of_kind, gain, priority = 1):
	"""a free voice; else the least important one (lowest priority, then quietest) if the new
	sound matters more; a kind at its cap replaces its own oldest"""
	var same_kind = []
	var free = null
	var quietest = null
	for voice in _voices:
		if not voice.playing:
			free = voice if free == null else free
			continue
		if _voice_kinds.get(voice) == kind:
			same_kind.append(voice)
		if quietest == null or _less_important(voice, quietest):
			quietest = voice
	if same_kind.size() >= max_of_kind:
		var oldest = same_kind[0]
		for voice in same_kind:
			if voice.get_playback_position() > oldest.get_playback_position():
				oldest = voice
		return oldest
	if free != null:
		return free
	if quietest == null:
		return null
	var quietest_priority = _voice_priorities.get(quietest, 1)
	if quietest_priority < priority:
		return quietest
	if quietest_priority == priority and quietest.volume_db < linear_to_db(gain):
		return quietest
	return null


func _less_important(a, b):
	var priority_a = _voice_priorities.get(a, 1)
	var priority_b = _voice_priorities.get(b, 1)
	if priority_a != priority_b:
		return priority_a < priority_b
	return a.volume_db < b.volume_db


func _on_node_added(node):
	# a projectile is added to its shooter before its _ready deals the damage
	if node is CannonShell:
		_on_cannon_fired(node)
	elif node is Rocket:
		_on_rocket_fired(node)
	elif node is Unit and not node.has_meta("_war_sounds"):
		node.set_meta("_war_sounds", true)
		node.tree_exiting.connect(_on_unit_leaving.bind(node))


func _on_cannon_fired(shell):
	if not is_instance_valid(shell) or not is_instance_valid(shell.target_unit):
		return
	var shooter = shell.get_parent()
	var target = shell.target_unit
	var audible = shooter.visible or target.visible
	var kind = weapon_of(shooter, "cannon_shell")
	play(kind, shooter.global_position, 1.0, audible)
	_casings(kind, shooter, audible)
	if randf() >= float(_config.get("impacts", {}).get(kind, 1.0)):
		return
	# the round lands a moment later where the target is
	var flight_s = shooter.global_position.distance_to(target.global_position) / SHELL_SPEED_M_PER_S
	var hit_position = target.global_position
	var surface = surface_of(target)
	if kind in _config.get("heavy_impacts", []):
		_play_later(flight_s + 0.04, ["impact", hit_position, 1.0, audible])
		_play_later(flight_s + 0.05, [surface, hit_position, 0.6, audible])
	else:
		_play_later(flight_s + 0.04, [surface, hit_position, 0.8, audible])


func _on_rocket_fired(rocket):
	if not is_instance_valid(rocket) or not is_instance_valid(rocket.target_unit):
		return
	var shooter = rocket.get_parent()
	var target = rocket.target_unit
	var kind = weapon_of(shooter, "rocket")
	play(kind, shooter.global_position, 1.0, shooter.visible or target.visible)
	rocket.tree_exiting.connect(_on_rocket_gone.bind(target))


func _on_rocket_gone(target):
	# a rocket leaves when it hits or when its target is already gone (then the target's own
	# explosion is heard instead)
	if is_instance_valid(target) and target.is_inside_tree() and target.hp > 0:
		play("explosion_small", target.global_position, 0.55, target.visible)
		play(surface_of(target), target.global_position, 0.5, target.visible)


func _on_unit_leaving(unit):
	if unit.hp == null or unit.hp > 0 or not unit.is_inside_tree():
		return
	var at = unit.global_position
	var audible = unit.visible
	for layer in _config.get("deaths", {}).get(size_of(unit), []):
		var arguments = [layer[1], at, float(layer[2]), audible, float(layer[3])]
		if float(layer[0]) <= 0.0:
			play.callv(arguments)
		else:
			_play_later(float(layer[0]), arguments)


func weapon_of(shooter, projectile):
	"""the report a unit's shot makes (data/sounds/combat.json weapons)"""
	var weapon = _config.get("weapons", {}).get(_unit_id(shooter))
	if weapon == null:
		weapon = _config.get("default_weapons", {}).get(projectile, "cannon")
	return weapon


func surface_of(target):
	"""what a round sounds like on its target: infantry, a building or armour"""
	if _unit_id(target) in _config.get("infantry", []):
		return "impact_soft"
	if target is Structure:
		return "impact_building"
	return "impact_armor"


func size_of(unit):
	"""the kind of death a unit dies (data/sounds/combat.json sizes)"""
	var size = _config.get("sizes", {}).get(_unit_id(unit))
	if size != null:
		return size
	if unit is Structure:
		return "structure"
	if unit.movement_domain == Constants.Match.Navigation.Domain.AIR:
		return "aircraft"
	return _config.get("default_size", "medium")


func _casings(kind, shooter, audible):
	var chance = float(_config.get("casings", {}).get(kind, 0.0))
	if chance <= 0.0 or randf() >= chance:
		return
	if _zoom_out >= float(_config.get("casing_zoom_out_below", 0.4)):
		return
	_play_later(CASING_DELAY_S + randf() * 0.1, ["casing", shooter.global_position, 1.0, audible])


func _play_later(delay_s, arguments):
	get_tree().create_timer(delay_s, false).timeout.connect(play.bindv(arguments))


func _unit_id(unit):
	var scene_path = unit.scene_file_path
	if not _unit_ids.has(scene_path):
		var entry = GameData.unit_by_scene(scene_path)
		_unit_ids[scene_path] = entry["id"] if entry != null else ""
	return _unit_ids[scene_path]
