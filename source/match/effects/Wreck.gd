extends Node3D

# What is left of a destroyed unit for a little while: a pure visual made of copies of the
# unit's visible meshes, so it works for every model without per-model work. The real unit
# is freed as before and takes its groups, selection, navigation and targeting with it.
#
# - vehicles hop, settle at a slight angle, blackened; often the top part (a turret) is
#   blown off and lands next to the hull; they burn, cook off once or twice and sink away,
# - boats tilt and go under,
# - infantry go down one figure at a time, each its own way (toppling, crumpling at the
#   knees or thrown back), lie still for a moment and fade,
# - aircraft keep their momentum, fall with a smoke trail and burst on the ground, then burn
#   like a vehicle,
# - structures collapse: they shudder, lean and slump into a low, smoking heap of rubble
#   that stays a while before it sinks away.
#
# Explosions, dust and the crash sound come from CombatEffects (the `effects` node).

enum Kind { VEHICLE, BOAT, INFANTRY, AIRCRAFT, STRUCTURE }
enum Fall { TOPPLE, CRUMPLE, THROWN }  # how one infantry figure goes down

const EffectParticles = preload("res://source/match/effects/EffectParticles.gd")

const MAX_MESHES = 32
const HOP_S = 0.45
const VEHICLE_BURN_S = 10.0  # smoking before it starts to sink
const VEHICLE_FLAMES_S = 4.0
const SINK_S = 3.0
const BOAT_SINK_S = 4.0
const INFANTRY_FALL_S = 0.55
const INFANTRY_THROW_HEIGHT = 0.45
const INFANTRY_THROW_DISTANCE = 0.9
const INFANTRY_STAY_S = 4.0
const INFANTRY_FADE_S = 2.0
const AIRCRAFT_GRAVITY = 9.0
const AIRCRAFT_MAX_FALL_S = 4.0
const TURRET_POP_CHANCE = 0.6
const TURRET_GRAVITY = 12.0
const COOK_OFFS = [2.0, 7.0]  # a pop of fire at random times in this range of a burn
const COLLAPSE_S = 2.6
const RUBBLE_HEIGHT = 0.16  # of the building's height, once it lies in a heap
const RUBBLE_S = 14.0  # how long the heap stays, smoking for most of it

var kind = Kind.VEHICLE
var effects = null  # CombatEffects
var size = 1.0  # about the unit's radius, in metres
var height = 1.0  # of the copied meshes above the unit's origin
var velocity = Vector3.ZERO  # aircraft: the momentum it falls with
var blown_towards = Vector3.ZERO  # away from whoever fired the last shot, when known

var _parts = []  # MeshInstance3D copies
var _part_rest = []  # their transforms when the unit died
var _part_axes = []  # infantry: the axis each figure falls around
var _part_falls = []  # infantry: Fall of each figure
var _rest = Transform3D()  # where the unit stood
var _tilt_axis = Vector3.RIGHT
var _tilt_deg = 6.0
var _age = 0.0
var _sink_at = INF  # age at which sinking starts
var _sink_s = SINK_S
var _smoke = null
var _flames = null
var _embers = null
var _popped = -1  # vehicles: the index of the part blown off, or -1
var _pop_velocity = Vector3.ZERO
var _pop_offset = Vector3.ZERO
var _pop_spin = Vector3.ZERO
var _pop_floor = 0.0  # how far the part may drop below where it was before it is on the ground
var _cook_offs = []  # ages at which fire bursts out of a burning wreck again


static func from_unit(unit, material_override):
	"""copies the unit's visible meshes (with their own materials, or all with
	material_override) into a new wreck placed where the unit is; null if it has none"""
	var geometry = unit.find_child("Geometry", true, false)
	if geometry == null:
		geometry = unit
	var meshes = geometry.find_children("*", "MeshInstance3D", true, false).filter(
		func(mesh): return mesh.mesh != null and mesh.is_visible_in_tree()
	)
	if geometry is MeshInstance3D and geometry.mesh != null:
		meshes.push_front(geometry)
	if meshes.is_empty():
		return null
	var wreck = load("res://source/match/effects/Wreck.gd").new()
	var origin = Transform3D(Basis(), unit.global_position)
	# keep the yaw only: units are upright, and a scaled unit root must not shear the copies
	var yaw_basis = Basis(Vector3.UP, unit.global_rotation.y)
	wreck._rest = Transform3D(yaw_basis, unit.global_position)
	wreck.transform = wreck._rest
	var to_local = wreck._rest.affine_inverse()
	var bounds = null
	for mesh in meshes.slice(0, MAX_MESHES):
		var copy = MeshInstance3D.new()
		copy.mesh = mesh.mesh
		copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if material_override != null:
			copy.material_override = material_override
		else:
			for surface in range(mesh.mesh.get_surface_count()):
				copy.set_surface_override_material(surface, mesh.get_active_material(surface))
		copy.transform = to_local * mesh.global_transform
		wreck.add_child(copy)
		wreck._parts.append(copy)
		wreck._part_rest.append(copy.transform)
		var box = copy.transform * mesh.mesh.get_aabb()
		bounds = box if bounds == null else bounds.merge(box)
	wreck.height = maxf(0.3, bounds.end.y)
	wreck.size = maxf(0.4, maxf(bounds.size.x, bounds.size.z) * 0.5)
	return wreck


func _ready():
	var angle = randf() * TAU
	_tilt_axis = Vector3(cos(angle), 0.0, sin(angle))
	if blown_towards != Vector3.ZERO:  # pushed over away from the shot that killed it
		_tilt_axis = _axis_tipping_towards(blown_towards, 0.4)
	match kind:
		Kind.VEHICLE:
			_start_burning(VEHICLE_BURN_S)
			if randf() < TURRET_POP_CHANCE:
				_blow_off_top()
		Kind.BOAT:
			_tilt_deg = randf_range(14.0, 24.0)
			_sink_at = 0.3
			_sink_s = BOAT_SINK_S
			_smoke = _emitter("smoke_column", 0.7, Vector3(0, height * 0.6, 0))
		Kind.INFANTRY:
			for _part in _parts:
				var a = randf() * TAU
				var axis = Vector3(cos(a), 0.0, sin(a))
				if blown_towards != Vector3.ZERO:  # most go down away from the shooter
					axis = _axis_tipping_towards(blown_towards, 0.7)
				_part_axes.append(axis)
				_part_falls.append(randi() % Fall.size())
		Kind.AIRCRAFT:
			_tilt_axis = (_rest.basis * Vector3.FORWARD).normalized()
			_smoke = _emitter("smoke_column", 0.75, Vector3.ZERO)
			_flames = _emitter("flames", 0.75, Vector3.ZERO)
			if global_position.y < 0.4:
				_land.call_deferred()  # a landed aircraft bursts where it stands
		Kind.STRUCTURE:
			_tilt_deg = randf_range(5.0, 11.0)


func sink_soon():
	"""asked when too many wrecks are around: the oldest go away early"""
	if kind == Kind.STRUCTURE or kind == Kind.AIRCRAFT:
		return
	_sink_at = minf(_sink_at, _age)
	_sink_s = 1.2
	_stop_emitting()


func is_sinking():
	return _age >= _sink_at


func _process(delta):
	_age += delta
	match kind:
		Kind.VEHICLE, Kind.BOAT:
			_animate_vehicle()
		Kind.INFANTRY:
			_animate_infantry()
		Kind.AIRCRAFT:
			_animate_aircraft(delta)
		Kind.STRUCTURE:
			_animate_structure()


func _animate_vehicle():
	var hop = 0.0
	var tilt = _tilt_deg
	if kind == Kind.VEHICLE and _age < HOP_S:
		var p = _age / HOP_S
		hop = sin(p * PI) * clampf(0.25 * size, 0.15, 0.5)
		tilt = _tilt_deg * p
	if _flames != null and _age > VEHICLE_FLAMES_S:
		_flames.emitting = false
	var sink = 0.0
	if _age >= _sink_at:
		var p = clampf((_age - _sink_at) / _sink_s, 0.0, 1.0)
		sink = (height + 0.15) * p * p
		if kind == Kind.BOAT:
			tilt = _tilt_deg * minf(1.0, p * 2.0)
		if p >= 1.0:
			queue_free()
			return
		if _smoke != null and _smoke.emitting and p > 0.3:
			_stop_emitting()
	if not _cook_offs.is_empty() and _age >= _cook_offs[0]:
		_cook_offs.pop_front()
		if visible and effects != null and is_instance_valid(effects):
			effects.explode(to_global(Vector3(0, height * 0.7, 0)), clampf(size * 0.6, 0.5, 0.9))
	if _popped >= 0:
		_animate_popped()
	transform = Transform3D(
		_rest.basis.rotated(_tilt_axis, deg_to_rad(tilt)), _rest.origin + Vector3(0, hop - sink, 0)
	)


func _blow_off_top():
	"""flings the part that sits highest, a turret or a cabin, off the hull"""
	if _parts.size() < 2:
		return
	var best = -1
	var best_score = -INF
	for index in range(_parts.size()):
		var box = _parts[index].transform * _parts[index].mesh.get_aabb()
		var center = box.get_center()
		if center.y < height * 0.45 or box.size.y > height * 0.8:
			continue  # the hull, or something as tall as the whole vehicle
		var score = center.y + box.get_volume() * 0.5
		if score > best_score:
			best_score = score
			best = index
	if best < 0:
		return
	_popped = best
	var box = _parts[best].transform * _parts[best].mesh.get_aabb()
	_pop_floor = box.position.y  # its bottom comes to rest on the ground
	var a = randf() * TAU
	var flung = Vector3(cos(a), 0.0, sin(a))
	if blown_towards != Vector3.ZERO:
		flung = (_rest.basis.inverse() * blown_towards).rotated(Vector3.UP, randf_range(-0.6, 0.6))
	_pop_velocity = flung * 1.6 + Vector3(0, randf_range(4.0, 5.5), 0)
	_pop_spin = Vector3(randf_range(-6, 6), randf_range(-4, 4), randf_range(-6, 6))


func _animate_popped():
	if _pop_offset.y <= -_pop_floor and _pop_velocity.y <= 0.0:
		return  # landed
	var delta = get_process_delta_time()
	_pop_velocity.y -= TURRET_GRAVITY * delta
	_pop_offset += _pop_velocity * delta
	if _pop_offset.y <= -_pop_floor and _pop_velocity.y <= 0.0:
		_pop_offset.y = -_pop_floor  # lands askew and stays like that
	var rest = _part_rest[_popped]
	var turned = Basis.from_euler(_pop_spin * minf(_age, 1.2) * 0.4) * rest.basis
	_parts[_popped].transform = Transform3D(turned, rest.origin + _pop_offset)


func _axis_tipping_towards(world_direction, jitter):
	"""the wreck-local axis to rotate around for the top to fall towards world_direction"""
	var direction = (_rest.basis.inverse() * world_direction) * Vector3(1, 0, 1)
	direction = direction.normalized().rotated(Vector3.UP, randf_range(-jitter, jitter))
	return Vector3.UP.cross(direction).normalized()


func _animate_infantry():
	for index in range(_parts.size()):
		var delay = 0.09 * index  # a squad does not drop in one piece
		var t = maxf(0.0, _age - delay)
		_parts[index].transform = _fallen(index, t)
	var fade = (_age - INFANTRY_STAY_S) / INFANTRY_FADE_S
	if fade > 0.0:
		for part in _parts:
			part.transparency = clampf(fade, 0.0, 1.0)
		position.y = _rest.origin.y - 0.25 * clampf(fade, 0.0, 1.0)
		if fade >= 1.0:
			queue_free()


func _fallen(index, t):
	"""where figure index lies t seconds after it was hit"""
	var rest = _part_rest[index]
	var axis = _part_axes[index]
	var away = (Basis(axis, 1.0) * Vector3.UP) * Vector3(1, 0, 1)  # the way its head goes
	var angle = 0.0
	var offset = Vector3.ZERO
	var squash = 1.0
	match _part_falls[index]:
		Fall.TOPPLE:  # stiff, faster and faster, like a plank
			var p = clampf(t / INFANTRY_FALL_S, 0.0, 1.0)
			angle = deg_to_rad(86.0) * p * p
		Fall.CRUMPLE:  # the knees give first, then the body slumps over
			var knees = clampf(t / 0.3, 0.0, 1.0)
			var slump = clampf((t - 0.2) / 0.6, 0.0, 1.0)
			squash = 1.0 - 0.35 * knees
			angle = deg_to_rad(80.0) * slump * slump
			offset.y = -0.05 * knees
		Fall.THROWN:  # lifted off its feet by the blast and flung on its back
			var p = clampf(t / (INFANTRY_FALL_S * 1.1), 0.0, 1.0)
			angle = deg_to_rad(100.0) * minf(1.0, p * 1.3)
			offset = away * INFANTRY_THROW_DISTANCE * p
			offset.y = INFANTRY_THROW_HEIGHT * sin(p * PI)
	var turned = Basis(axis, angle) * Basis.from_scale(Vector3(1.0, squash, 1.0)) * rest.basis
	return Transform3D(turned, rest.origin + offset)


func _animate_aircraft(delta):
	velocity.y -= AIRCRAFT_GRAVITY * delta
	velocity.x *= 1.0 - 0.4 * delta
	velocity.z *= 1.0 - 0.4 * delta
	var spin = _age * 5.0  # spirals down around its nose
	var dive = minf(deg_to_rad(40.0), _age * 0.9)
	var side = _tilt_axis.cross(Vector3.UP).normalized()
	var turned = _rest.basis.rotated(_tilt_axis, spin).rotated(side, -dive)
	transform = Transform3D(turned, position + velocity * delta)
	if position.y <= 0.15 or _age > AIRCRAFT_MAX_FALL_S:
		_land()


func _land():
	"""hits the ground: bursts, then burns on as a vehicle wreck"""
	if kind != Kind.AIRCRAFT:
		return
	_rest = Transform3D(
		_rest.basis.rotated(_tilt_axis, randf_range(-0.5, 0.5)),
		Vector3(position.x, 0.0, position.z)
	)
	_tilt_axis = Vector3(randf() - 0.5, 0.0, randf() - 0.5).normalized()
	_tilt_deg = randf_range(8.0, 16.0)
	if _smoke != null:
		_smoke.queue_free()
		_smoke = null
	if _flames != null:
		_flames.queue_free()
		_flames = null
	kind = Kind.VEHICLE
	_age = HOP_S  # no hop, it has just smashed into the ground
	_start_burning(_age + VEHICLE_BURN_S * 0.6)
	if effects != null and is_instance_valid(effects):
		effects.aircraft_impact(self, _rest.origin, size)
	_animate_vehicle()


func _animate_structure():
	var p = clampf(_age / COLLAPSE_S, 0.0, 1.0)
	var ease_in = p * p * (1.5 - 0.5 * p)  # slow start, then it gives way
	var shudder = Vector3(sin(_age * 47.0), 0.0, cos(_age * 39.0)) * 0.07 * (1.0 - p) * size
	# it slumps into a heap: squashed down to a fraction of its height, leaning over
	var slump = lerpf(1.0, RUBBLE_HEIGHT, ease_in)
	var spread = 1.0 + 0.12 * ease_in
	var sink = 0.0
	var gone = (_age - RUBBLE_S) / SINK_S  # after a while the heap sinks away too
	if gone > 0.0:
		sink = (height * RUBBLE_HEIGHT + 0.2) * gone * gone
	var tilted = _rest.basis.rotated(_tilt_axis, deg_to_rad(_tilt_deg) * ease_in)
	transform = Transform3D(
		tilted * Basis.from_scale(Vector3(spread, slump, spread)),
		_rest.origin + shudder - Vector3(0, sink, 0)
	)
	if p >= 1.0 and _smoke == null and gone < 0.0:
		# top level, so the squashed heap does not squash the smoke too
		var top = _rest.origin + Vector3(0, height * RUBBLE_HEIGHT, 0)
		_smoke = _emitter("smoke_column", clampf(size * 0.6, 1.0, 2.0), top, true)
		_embers = _emitter("embers", clampf(size * 0.5, 0.75, 1.4), top, true)
	if _age >= RUBBLE_S - 3.0 and _smoke != null and _smoke.emitting:
		_stop_emitting()
	if gone >= 1.0:
		queue_free()


func _start_burning(burn_s):
	var top = Vector3(0, height * 0.75, 0)
	var smoke_size = clampf(size * 0.9, 0.75, 1.4)
	if _smoke == null:
		_smoke = _emitter("smoke_column", smoke_size, top)
	_flames = _emitter("flames", clampf(size * 0.8, 0.5, 1.0), top * 0.8)
	_sink_at = burn_s
	_cook_offs = [randf_range(COOK_OFFS[0], COOK_OFFS[1]) + _age]
	if randf() < 0.5:
		_cook_offs.append(_cook_offs[0] + randf_range(1.0, 3.0))


func _stop_emitting():
	for emitter in [_smoke, _flames, _embers]:
		if emitter != null and is_instance_valid(emitter):
			emitter.emitting = false


func _emitter(particle_kind, particle_size, at, world = false):
	var emitter = EffectParticles.make(particle_kind, particle_size)
	emitter.top_level = world
	add_child(emitter)
	if world:
		emitter.global_position = at
	else:
		emitter.position = at
	return emitter
