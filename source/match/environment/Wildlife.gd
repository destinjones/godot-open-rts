extends Node3D

# Life that is not at war: small flocks of birds wander over the map, settle on open ground to
# feed and burst into the air when a unit comes close or something is hit nearby; vultures
# turn up over fresh wrecks and circle there for a while before they drift off.
#
# Purely a visual: its own random numbers, nothing saved, no effect on the simulation. Every
# bird of a kind is one instance of a MultiMesh (two draw calls in all, plus their shadows),
# flapping in the vertex shader (source/shaders/3d/bird.gdshader); the script only moves
# them. The numbers are in data/wildlife.json.

enum { FLY, LAND, FEED, TAKE_OFF }

const BirdShader = preload("res://source/shaders/3d/bird.gdshader")
const Wreck = preload("res://source/match/effects/Wreck.gd")
const GameData = preload("res://source/data-model/GameData.gd")

const MAP_MARGIN_M = 4.0
const THREAT_CHECK_S = 0.3
const LANDING_TRIES = 12
const LANDING_CLEARANCE_M = 7.0  # no unit this close to where a flock settles
const TURN_RATE = 0.9  # rad/s of a flock's heading
const FOLLOW_RATE = 2.8  # 1/s: how tightly a bird keeps its place in the flock
const DESCENT_MPS = 2.2
const CLIMB_MPS = 3.5
const HOP_S = 0.35
const BIRD_COLORS = [Color(0.26, 0.23, 0.21), Color(0.12, 0.11, 0.1)]
const VULTURE_COLORS = [Color(0.2, 0.17, 0.15), Color(0.07, 0.06, 0.06)]
const FLOATS_PER_INSTANCE = 16  # a 3x4 transform and the custom data
const VIEW_MARGIN_M = 8.0  # a flock this far outside the view is still moved and drawn
const HIDE_ABOVE_CAMERA_SIZE = 45.0  # zoomed out further, birds are specks: none are drawn

var _config = {}
var _rng = RandomNumberGenerator.new()
var _map_size = Vector2(50, 50)
var _flocks = []
var _vultures = []  # Flier
var _bird_mesh = null
var _vulture_mesh = null
var _since_threat_check = 0.0
var _time := 0.0
var _delta := 0.0
var _blend := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0])  # [0] the follow rate, else 1/s
var _bird_span = 1.0
var _bird_beats = 1.0
var _vulture_span = 1.0
var _vulture_beats = 1.0

@onready var _match = find_parent("Match")


class Flier:
	"""one bird or vulture"""

	var pos := Vector3.ZERO
	var velocity := Vector3.ZERO  # a bolt on being startled, fading
	var phase := 0.0  # of the wing beat and the glides
	var yaw := 0.0
	var pitch := 0.0
	var roll := 0.0
	var flap := 0.0  # 0 glide .. 1 full beat
	var fold := 0.0  # 0 wings spread .. 1 folded on the ground
	# a bird in a flock: its place, height and drift
	var offset := Vector3.ZERO
	var lift := 0.0
	var orbit := 0.0
	var hop_at := 0.0
	var hop_from := Vector3.ZERO
	var hop_to := Vector3.ZERO
	var hop_t := 1.0
	# a vulture circling a wreck
	var center := Vector3.ZERO
	var radius := 1.0
	var angle := 0.0
	var direction := 1.0
	var height := 10.0
	var arrive_at := 0.0
	var leave_at := 0.0


func _ready():
	_config = GameData.wildlife()
	_rng.randomize()
	_bird_span = float(_config["birds"]["wingspan_m"])
	_bird_beats = float(_config["birds"]["wing_beats_per_s"])
	_vulture_span = float(_config["vultures"]["wingspan_m"])
	_vulture_beats = float(_config["vultures"]["wing_beats_per_s"])
	if _match != null and _match.map != null:
		_map_size = _match.map.size
	_bird_mesh = _make_layer(_bird_shape(false), BIRD_COLORS, _flock_count() * _flock_size_max())
	_vulture_mesh = _make_layer(_bird_shape(true), VULTURE_COLORS, _config["vultures"]["max"])
	for _i in range(_flock_count()):
		_flocks.append(_new_flock())
	MatchSignals.unit_damaged.connect(_on_unit_damaged)
	MatchSignals.camera_shake.connect(_on_blast)
	get_tree().node_added.connect(_on_node_added)


func _process(delta):
	if delta <= 0.0:
		return
	_time += delta
	_delta = delta
	for rate in range(_blend.size()):  # 1 - exp(-rate * delta): an exponential approach
		_blend[rate] = 1.0 - exp(-float(rate) * delta)
	_blend[0] = 1.0 - exp(-FOLLOW_RATE * delta)
	_since_threat_check += delta
	if _since_threat_check >= THREAT_CHECK_S:
		_since_threat_check = 0.0
		_check_threats()
	var buffer = PackedFloat32Array()
	buffer.resize(_bird_mesh.multimesh.instance_count * FLOATS_PER_INSTANCE)
	var index = 0
	var view = _view_planes()
	for flock in _flocks:
		_move_flock(flock, delta)
		if not _in_view(view, flock):  # only the flock moves on, its birds wait
			flock["hidden"] = true
			continue
		if flock["hidden"]:
			_regroup(flock)
		var state: int = flock["state"]
		var center: Vector3 = flock["center"]
		var target: Vector3 = flock["target"]
		var spread: float = flock["spread"]
		for bird in flock["birds"]:
			_move_bird(bird, state, center, target, spread)
			_write_instance(buffer, index, bird, _bird_span, _bird_beats)
			index += 1
	_bird_mesh.multimesh.buffer = buffer
	_bird_mesh.multimesh.visible_instance_count = index
	_update_vultures(delta, view != null and view.is_empty())


func sightings(kind = "birds"):
	"""where to look for "birds" (settled flocks first), "feeding" birds or "vultures";
	for the play harness and screenshots"""
	if kind == "vultures":
		return _vultures.map(func(vulture): return vulture.center + Vector3(0, vulture.height, 0))
	var flocks = _flocks.duplicate()
	flocks.sort_custom(func(a, b): return a["state"] == FEED and b["state"] != FEED)
	if kind == "feeding":
		flocks = flocks.filter(func(flock): return flock["state"] == FEED)
	return flocks.map(func(flock): return flock["birds"][0].pos)


# flocks


func _view_planes():
	"""the camera's frustum; null to treat everything as in view (no camera), empty when
	zoomed out too far to make out a bird"""
	var camera = get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return null
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL and camera.size > HIDE_ABOVE_CAMERA_SIZE:
		return []
	return camera.get_frustum()


func _in_view(planes, flock):
	if planes == null:
		return true
	if planes.is_empty():
		return false
	var reach: float = VIEW_MARGIN_M * flock["spread"]
	if _inside(planes, flock["center"], reach):
		return true
	return (
		(flock["state"] == LAND or flock["state"] == FEED)
		and _inside(planes, flock["target"], reach)
	)


static func _inside(planes, point, reach):
	for plane in planes:
		if plane.distance_to(point) > reach:
			return false
	return true


func _regroup(flock):
	"""a flock coming into view: its birds take their places at once"""
	flock["hidden"] = false
	for bird in flock["birds"]:
		bird.velocity = Vector3.ZERO
		bird.hop_t = 1.0
		if flock["state"] == FEED:
			bird.pos = (
				Vector3(flock["target"].x, 0, flock["target"].z) + bird.offset * Vector3(1, 0, 1)
			)
		elif flock["state"] == LAND:
			bird.pos = Vector3(
				flock["target"].x + bird.offset.x,
				flock["center"].y,
				flock["target"].z + bird.offset.z
			)
		else:
			bird.pos = flock["center"] + bird.offset * flock["spread"]


func _flock_count():
	var birds = _config["birds"]
	var count = roundi(_map_size.x * _map_size.y / float(birds["m2_per_flock"]))
	return clampi(count, int(birds["min_flocks"]), int(birds["max_flocks"]))


func _flock_size_max():
	return int(_config["birds"]["flock_size"][1])


func _new_flock():
	var birds = _config["birds"]
	var center = _random_map_point()
	center.y = _range(birds["cruise_height_m"])
	var flock = {
		"state": FLY,
		"center": center,
		"heading": _rng.randf() * TAU,
		"target": _random_map_point(),
		"cruise": center.y,
		"timer": _range(birds["fly_s"]) * _rng.randf(),  # not all landing at once
		"spread": 1.0,
		"hidden": false,
		"birds": [],
	}
	for _i in range(_rng.randi_range(int(birds["flock_size"][0]), int(birds["flock_size"][1]))):
		var offset = Vector3(_rng.randf_range(-1.6, 1.6), 0, _rng.randf_range(-1.6, 1.6))
		var bird = Flier.new()
		bird.pos = center + offset
		bird.offset = offset
		bird.lift = _rng.randf_range(-0.6, 0.6)
		bird.orbit = _rng.randf_range(-0.35, 0.35)  # rad/s, so the flock churns
		bird.phase = _rng.randf() * TAU
		bird.yaw = flock["heading"]
		bird.flap = 0.6
		flock["birds"].append(bird)
	return flock


func _move_flock(flock, delta):
	var birds = _config["birds"]
	flock["spread"] = lerpf(flock["spread"], 1.0, 1.0 - exp(-0.6 * delta))
	flock["timer"] -= delta
	match flock["state"]:
		FLY, TAKE_OFF:
			_steer(flock, float(birds["speed_mps"]), delta)
			var climb = CLIMB_MPS if flock["state"] == TAKE_OFF else 1.0
			flock["center"].y = move_toward(flock["center"].y, flock["cruise"], climb * delta)
			if flock["state"] == TAKE_OFF and flock["center"].y > flock["cruise"] * 0.7:
				flock["state"] = FLY
			var to_target = _flat(flock["target"] - flock["center"])
			if to_target.length() < 4.0:
				flock["target"] = _random_map_point()
			if flock["state"] == FLY and flock["timer"] <= 0.0:
				var spot = _landing_spot(flock["center"])
				if spot != null:
					flock["target"] = spot
					flock["state"] = LAND
				else:
					flock["timer"] = _range(birds["fly_s"])
		LAND:
			var to_spot = _flat(flock["target"] - flock["center"])
			var distance = to_spot.length()
			if distance > 6.0:
				_steer(flock, float(birds["speed_mps"]), delta)
			else:
				var step = min(distance, float(birds["speed_mps"]) * 0.6 * delta)
				if distance > 0.01:
					flock["center"] += to_spot / distance * step
				flock["center"].y = move_toward(flock["center"].y, 0.0, DESCENT_MPS * delta)
				if flock["center"].y <= 0.0 and distance < 0.3:
					flock["state"] = FEED
					flock["timer"] = _range(birds["feed_s"])
		FEED:
			if flock["timer"] <= 0.0:
				_take_off(
					flock, _flat(Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-1, 1)))
				)


func _steer(flock, speed, delta):
	var to_target = _flat(flock["target"] - flock["center"])
	var wanted = atan2(to_target.x, to_target.z)
	var turn = clampf(
		angle_difference(flock["heading"], wanted), -TURN_RATE * delta, TURN_RATE * delta
	)
	flock["heading"] = wrapf(flock["heading"] + turn, -PI, PI)
	var forward = Vector3(sin(flock["heading"]), 0, cos(flock["heading"]))
	flock["center"] += forward * speed * delta
	flock["center"].x = clampf(flock["center"].x, 0.0, _map_size.x)
	flock["center"].z = clampf(flock["center"].z, 0.0, _map_size.y)


func _take_off(flock, away):
	"""into the air, heading away (a flat direction, may be zero) and climbing hard"""
	var birds = _config["birds"]
	if away.length_squared() < 0.0001:
		away = Vector3(cos(_rng.randf() * TAU), 0, sin(_rng.randf() * TAU))
	away = away.normalized()
	flock["state"] = TAKE_OFF
	flock["heading"] = atan2(away.x, away.z)
	flock["target"] = _clamp_to_map(flock["center"] + away * _rng.randf_range(20.0, 35.0))
	flock["cruise"] = _range(birds["cruise_height_m"])
	flock["timer"] = _range(birds["fly_s"])


func _scatter(flock, from):
	var away = _flat(flock["center"] - from)
	flock["spread"] = 2.6
	if flock["state"] == FEED or flock["state"] == LAND:
		_take_off(flock, away)
		for bird in flock["birds"]:  # each bird bolts its own way first
			bird.velocity = (
				Vector3(
					_rng.randf_range(-1, 1), _rng.randf_range(1.5, 2.5), _rng.randf_range(-1, 1)
				)
				* 2.0
			)
	elif away.length_squared() > 0.0001:
		flock["target"] = _clamp_to_map(flock["center"] + away.normalized() * 25.0)
		flock["timer"] = _range(_config["birds"]["fly_s"])


func _landing_spot(near):
	for _i in range(LANDING_TRIES):
		var spot = _clamp_to_map(
			(
				Vector3(near.x, 0, near.z)
				+ Vector3(_rng.randf_range(-25, 25), 0, _rng.randf_range(-25, 25))
			)
		)
		if _is_dry(spot) and not _unit_near(spot, LANDING_CLEARANCE_M):
			return spot
	return null


func _is_dry(spot):
	if _match == null or _match.map == null:
		return true
	for offset in [
		Vector3.ZERO, Vector3(2, 0, 0), Vector3(-2, 0, 0), Vector3(0, 0, 2), Vector3(0, 0, -2)
	]:
		if _match.map.water_depth_at(spot + offset) != 0:
			return false
	return true


func _unit_near(spot, radius):
	var radius_squared = radius * radius
	for unit in get_tree().get_nodes_in_group("units"):
		if _flat(unit.global_position - spot).length_squared() < radius_squared:
			return true
	return false


# birds


func _move_bird(bird: Flier, state: int, center: Vector3, target: Vector3, spread: float):
	var delta := _delta
	var before := bird.pos
	var on_ground := state == FEED
	if on_ground:
		_hop(bird, delta)
	else:
		bird.offset = bird.offset.rotated(Vector3.UP, bird.orbit * delta)
		var wanted := center + bird.offset * spread
		if state == LAND:  # each to its own patch of ground
			wanted = Vector3(target.x + bird.offset.x, center.y, target.z + bird.offset.z)
		else:
			wanted.y += bird.lift + sin(_time * 0.9 + bird.phase) * 0.3
		bird.velocity -= bird.velocity * _blend[2]
		bird.pos += (wanted - bird.pos) * _blend[0] + bird.velocity * delta
		bird.pos.y = maxf(bird.pos.y, 0.0)
	var moved := (bird.pos - before) / delta
	var flat_speed := Vector2(moved.x, moved.z).length()
	if not on_ground and flat_speed > 0.3:
		var yaw := atan2(moved.x, moved.z)
		var yaw_rate: float = angle_difference(bird.yaw, yaw) / delta
		bird.yaw = yaw
		bird.roll += (clampf(yaw_rate * 0.4, -0.5, 0.5) - bird.roll) * _blend[4]
		bird.pitch += (clampf(atan2(moved.y, flat_speed), -0.6, 0.6) - bird.pitch) * _blend[4]
	else:
		bird.roll -= bird.roll * _blend[6]
		bird.pitch -= bird.pitch * _blend[6]
	# full beats climbing, taking off or landing, otherwise bursts of flapping between glides
	var flap := 0.0
	if not on_ground:
		var gliding := sin(_time * 0.45 + bird.phase) > 0.35
		flap = 1.0 if state != FLY or moved.y > 0.4 or not gliding else 0.12
	elif bird.hop_t < 1.0:
		flap = 0.5  # a flick of the wings on a hop
	bird.flap += (flap - bird.flap) * _blend[5]
	var fold := 1.0 if on_ground and bird.hop_t >= 1.0 else 0.0
	if state == LAND and bird.pos.y < 0.4:
		fold = 0.6
	bird.fold += (fold - bird.fold) * _blend[8]


func _hop(bird: Flier, delta: float):
	"""feeding: stand, peck about and every now and then hop a little way"""
	if bird.hop_t < 1.0:
		bird.hop_t = min(1.0, bird.hop_t + delta / HOP_S)
		var t = bird.hop_t
		bird.pos = bird.hop_from.lerp(bird.hop_to, t) + Vector3(0, sin(t * PI) * 0.18, 0)
		return
	bird.pos.y = move_toward(bird.pos.y, 0.0, delta)
	if _time < bird.hop_at:
		return
	bird.hop_at = _time + _rng.randf_range(0.8, 3.5)
	var step = Vector3(_rng.randf_range(-0.6, 0.6), 0, _rng.randf_range(-0.6, 0.6))
	if (bird.pos + step - (bird.pos - bird.offset)).length() > 2.5:
		step = -step  # stay with the others
	bird.hop_from = Vector3(bird.pos.x, 0, bird.pos.z)
	bird.hop_to = bird.hop_from + step
	bird.hop_t = 0.0
	bird.yaw = atan2(step.x, step.z)
	bird.offset += step


# vultures


func _on_node_added(node):
	if node.get_script() == Wreck:
		_on_wreck.call_deferred(node)


func _on_wreck(wreck):
	var vultures = _config["vultures"]
	if not is_instance_valid(wreck) or not wreck.is_inside_tree():
		return
	if _rng.randf() > float(vultures["chance_per_wreck"]):
		return
	var spot = wreck.global_position * Vector3(1, 0, 1)
	for vulture in _vultures:  # one wake per battlefield is enough
		if _flat(vulture.center - spot).length() < 8.0:
			vulture.leave_at = _time + float(vultures["stay_s"])
			return
	var count = _rng.randi_range(int(vultures["count"][0]), int(vultures["count"][1]))
	count = min(count, int(vultures["max"]) - _vultures.size())
	var arrive_s = float(vultures["arrive_after_s"])
	var from = Vector3(cos(_rng.randf() * TAU), 0, sin(_rng.randf() * TAU)) * 30.0
	for _i in range(count):
		var height = _range(vultures["height_m"])
		var vulture = Flier.new()
		vulture.center = spot
		vulture.radius = _range(vultures["circle_radius_m"])
		vulture.angle = _rng.randf() * TAU
		vulture.direction = 1.0 if _rng.randf() < 0.5 else -1.0
		vulture.height = height
		vulture.pos = (
			spot + from + Vector3(_rng.randf_range(-4, 4), height + 4.0, _rng.randf_range(-4, 4))
		)
		vulture.arrive_at = _time + arrive_s * _rng.randf_range(0.5, 1.5)
		vulture.leave_at = _time + float(vultures["stay_s"]) * _rng.randf_range(0.8, 1.2)
		vulture.phase = _rng.randf() * TAU
		vulture.flap = 0.3
		_vultures.append(vulture)


func _update_vultures(delta, hidden):
	var vultures = _config["vultures"]
	var speed = float(vultures["speed_mps"])
	var buffer = PackedFloat32Array()
	buffer.resize(_vulture_mesh.multimesh.instance_count * FLOATS_PER_INSTANCE)
	var index = 0
	for vulture in _vultures.duplicate():
		var before = vulture.pos
		var wanted
		if _time >= vulture.leave_at:  # off over the horizon, climbing
			var away = _flat(vulture.pos - vulture.center)
			away = away.normalized() if away.length_squared() > 0.01 else Vector3.RIGHT
			wanted = vulture.pos + away * speed + Vector3(0, 0.8, 0)
			if _flat(vulture.pos - vulture.center).length() > 45.0:
				_vultures.erase(vulture)
				continue
		elif _time < vulture.arrive_at:
			wanted = vulture.pos  # still too far off to see
		else:
			vulture.angle += vulture.direction * speed / vulture.radius * delta
			wanted = (
				vulture.center
				+ Vector3(cos(vulture.angle), 0, sin(vulture.angle)) * vulture.radius
				+ Vector3(0, vulture.height + sin(_time * 0.3 + vulture.phase) * 0.6, 0)
			)
		var step = wanted - vulture.pos
		var reach = speed * 1.6 * delta
		vulture.pos += step.limit_length(reach) if step.length() > reach else step
		if _time < vulture.arrive_at:
			continue
		var moved = (vulture.pos - before) / delta
		var flat_speed = Vector2(moved.x, moved.z).length()
		if flat_speed > 0.2:
			var yaw = atan2(moved.x, moved.z)
			var yaw_rate = angle_difference(vulture.yaw, yaw) / delta
			vulture.yaw = yaw
			vulture.roll = lerpf(
				vulture.roll, clampf(yaw_rate * 0.5, -0.3, 0.3), 1.0 - exp(-2.0 * delta)
			)
		# soaring: an occasional few lazy beats
		var flap = 1.0 if sin(_time * 0.25 + vulture.phase) > 0.85 or moved.y > 0.5 else 0.0
		vulture.flap = lerpf(vulture.flap, flap, 1.0 - exp(-3.0 * delta))
		if hidden:
			continue
		_write_instance(buffer, index, vulture, _vulture_span, _vulture_beats)
		index += 1
	_vulture_mesh.multimesh.buffer = buffer
	_vulture_mesh.multimesh.visible_instance_count = index


# threats


func _check_threats():
	var settled = _flocks.filter(
		func(flock): return flock["state"] == FEED or flock["state"] == LAND
	)
	if settled.is_empty():
		return
	var spots := PackedVector2Array()
	for flock in settled:
		var spot: Vector3 = flock["target"] if flock["state"] == LAND else flock["center"]
		spots.append(Vector2(spot.x, spot.z))
	var radius := float(_config["birds"]["startle_radius_m"])
	var radius_squared := radius * radius
	for unit in get_tree().get_nodes_in_group("units"):
		var at: Vector3 = unit.global_position
		var flat := Vector2(at.x, at.z)
		for index in range(spots.size()):
			if flat.distance_squared_to(spots[index]) < radius_squared:
				spots[index] = Vector2.INF  # once is enough
				_scatter(settled[index], at)


func _on_unit_damaged(unit):
	if is_instance_valid(unit) and unit.is_inside_tree():
		_startle_around(unit.global_position, float(_config["birds"]["blast_radius_m"]) * 0.6)


func _on_blast(strength, at):
	if at is Vector3:
		_startle_around(at, float(_config["birds"]["blast_radius_m"]) * (0.6 + strength))


func _startle_around(at, radius):
	for flock in _flocks:
		if _flat(flock["center"] - at).length() < radius:
			_scatter(flock, at)


# drawing


func _make_layer(shape, colors, max_instances):
	var multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = shape
	multimesh.instance_count = max(1, max_instances)
	multimesh.visible_instance_count = 0
	var material = ShaderMaterial.new()
	material.shader = BirdShader
	material.set_shader_parameter("body_color", colors[0])
	material.set_shader_parameter("wing_tip_color", colors[1])
	multimesh.mesh.surface_set_material(0, material)
	var layer = MultiMeshInstance3D.new()
	layer.multimesh = multimesh
	layer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# the birds move every frame and are spread over the whole map
	layer.custom_aabb = AABB(
		Vector3(-50, -5, -50), Vector3(_map_size.x + 100, 70, _map_size.y + 100)
	)
	add_child(layer)
	return layer


func _write_instance(
	buffer: PackedFloat32Array, index: int, bird: Flier, span: float, beats: float
):
	span *= 1.0 + 0.35 * bird.fold  # plumper on the ground, or a feeding flock is specks
	var basis := Basis.from_euler(Vector3(bird.pitch, bird.yaw + PI, bird.roll)) * span
	var at := index * FLOATS_PER_INSTANCE
	var origin := bird.pos + Vector3(0, 0.05 * span, 0)
	buffer[at] = basis.x.x
	buffer[at + 1] = basis.y.x
	buffer[at + 2] = basis.z.x
	buffer[at + 3] = origin.x
	buffer[at + 4] = basis.x.y
	buffer[at + 5] = basis.y.y
	buffer[at + 6] = basis.z.y
	buffer[at + 7] = origin.y
	buffer[at + 8] = basis.x.z
	buffer[at + 9] = basis.y.z
	buffer[at + 10] = basis.z.z
	buffer[at + 11] = origin.z
	buffer[at + 12] = bird.phase
	buffer[at + 13] = bird.flap
	buffer[at + 14] = bird.fold
	buffer[at + 15] = beats


static func _bird_shape(broad):
	"""a bird 1 m across, facing -Z: a slim body and swept wings, or broad ones for a vulture
	(COLOR.r = 1 on the wings, COLOR.g rising to the tips) that the shader beats"""
	var tool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var body = Color(0, 0, 0)
	var nose = Vector3(0, 0.0, -0.3)
	var back = Vector3(0, 0.05, -0.02)
	var left = Vector3(-0.06, 0, -0.04)
	var right = Vector3(0.06, 0, -0.04)
	var tail = Vector3(0, 0.01, 0.18)
	var tail_left = Vector3(-0.09, 0.01, 0.34)
	var tail_right = Vector3(0.09, 0.01, 0.34)
	for triangle in [
		[nose, back, left],
		[nose, right, back],
		[left, back, tail],
		[back, right, tail],
		[tail, tail_left, tail_right],
		[nose, left, tail],
		[nose, tail, right],
	]:
		for vertex in triangle:
			tool.set_color(body)
			tool.add_vertex(vertex)
	for side in [-1.0, 1.0]:
		var wing = []  # [front, back] pairs from the root out
		if broad:  # a soaring bird: long, broad, square-ended wings with fingered tips
			wing = [[-0.12, 0.12], [-0.12, 0.13], [-0.09, 0.12], [-0.03, 0.08]]
		else:  # swept and pointed
			wing = [[-0.1, 0.08], [-0.08, 0.06], [0.06, 0.1], [0.1, 0.1]]
		var reaches = [0.05, 0.26, 0.42, 0.5]
		for index in range(3):
			var a_front = Vector3(reaches[index] * side, 0, wing[index][0])
			var a_back = Vector3(reaches[index] * side, 0, wing[index][1])
			var b_front = Vector3(reaches[index + 1] * side, 0, wing[index + 1][0])
			var b_back = Vector3(reaches[index + 1] * side, 0, wing[index + 1][1])
			for vertex in [a_front, b_front, a_back, b_front, b_back, a_back]:
				var reach = abs(vertex.x) / 0.5
				tool.set_color(Color(1, reach * reach, 0))
				tool.add_vertex(vertex)
	tool.generate_normals()
	return tool.commit()


# helpers


func _random_map_point():
	return Vector3(
		_rng.randf_range(MAP_MARGIN_M, _map_size.x - MAP_MARGIN_M),
		0,
		_rng.randf_range(MAP_MARGIN_M, _map_size.y - MAP_MARGIN_M)
	)


func _clamp_to_map(point):
	return Vector3(
		clampf(point.x, MAP_MARGIN_M, _map_size.x - MAP_MARGIN_M),
		point.y,
		clampf(point.z, MAP_MARGIN_M, _map_size.y - MAP_MARGIN_M)
	)


func _range(pair):
	return _rng.randf_range(float(pair[0]), float(pair[1]))


static func _flat(vector):
	return Vector3(vector.x, 0, vector.z)
