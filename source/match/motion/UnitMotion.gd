extends Node

# The procedural body motion of one unit; none of the models have animation clips.
#
# - infantry: a walk cycle feel (step bob, sway, a lean into the walk), breathing when idle
#   and a kick back on every shot,
# - ground vehicles and boats: pitch when speeding up or braking (squat and dive), body roll
#   out of turns (boats bank into them), a light suspension bob, a shot rocks the hull, and
#   wheels ("Wheel*" meshes) roll with the speed,
# - helicopters and drones: a hover bob, a tilt forward with speed and a bank in turns;
#   fixed-wing aircraft only bank. Rotors spin where the unit does not spin them itself.
#
# Speed and acceleration come from the unit's Movement trait (its real speed ramps, see
# "handling" in data/movement.json), turn rates from the unit's facing.
# Everything moves a "MotionPivot" node inserted between the unit's Geometry and its model,
# never the unit itself: navigation, selection and the fog of war read the unit's transform,
# and other scripts that move Geometry (WaterMotion, FixedWingFlight, ShotEffects.recoil)
# keep working on top. Nothing here runs on its own: MotionManager calls animate() for units
# on screen only.

enum Kind { INFANTRY, VEHICLE, BOAT, HOVER, PLANE }

const RotorSpin = preload("res://source/match/units/RotorSpin.gd")
const INFANTRY_MODEL_WORDS = ["rifleman", "militia", "infantry", "soldier"]
const SPRING_STIFFNESS = 90.0
const SPRING_DAMPING = 9.0

var unit = null
var kind = Kind.VEHICLE
var center_y = 0.5  # cull sphere centre above the unit's origin
var cull_radius = 1.5
var active = false  # on screen and animated this frame

var _pivot = null
var _model = null
var _movement = null
var _seed = 0.0
var _time = 0.0
var _fresh = true  # first frame on screen: the jump since the last one is not a speed
var _previous_position = Vector3.ZERO
var _previous_yaw = 0.0
var _previous_speed = 0.0
var _speed = 0.0
var _acceleration = 0.0
var _yaw_rate = 0.0
var _moving = 0.0
var _phase = 0.0
var _pitch = 0.0
var _pitch_velocity = 0.0
var _roll = 0.0
var _roll_velocity = 0.0
var _kick = 0.0
var _rotors = []
var _wheels = []  # [node, radius in metres]


func setup(a_unit):
	"""inserts the pivot; false when the unit has nothing to move"""
	unit = a_unit
	var geometry = unit.find_child("Geometry", false, false)
	if geometry == null or geometry.get_node_or_null("MotionPivot") != null:
		return false
	_pivot = Node3D.new()
	_pivot.name = "MotionPivot"
	var children = geometry.get_children()
	geometry.add_child(_pivot)
	for child in children:
		child.reparent(_pivot, false)
	_model = _pivot.get_node_or_null("Model")
	if _model != null and not unit.has_meta("_recoil_model"):
		# ShotEffects.recoil looks for the model right under Geometry; show it the moved one
		unit.set_meta("_recoil_model", _model)
		unit.set_meta("_recoil_rest", _model.position)
	_movement = unit.get_movement_trait()
	var aabb = _model_aabb(geometry)
	center_y = aabb.get_center().y
	cull_radius = aabb.size.length() * 0.5 + 0.6
	_seed = randf() * TAU
	_phase = _seed
	kind = _detect_kind()
	if (kind == Kind.HOVER or kind == Kind.PLANE) and not "_rotors" in unit:
		_rotors = RotorSpin.collect(unit)  # Helicopter.gd and Drone.gd spin their own
	if kind == Kind.VEHICLE:
		_wheels = _collect_wheels()
	unit.child_entered_tree.connect(_on_unit_child_entered)
	return true


func _collect_wheels():
	var wheels = []
	for node in _pivot.find_children("Wheel*", "MeshInstance3D", true, false):
		if not _shown_under_pivot(node):
			continue
		var radius = node.get_aabb().size.y * 0.5 * node.global_basis.get_scale().y
		if radius > 0.01:
			wheels.append([node, radius])
	return wheels


func animate(delta):
	active = true
	_time += delta
	_sample_motion(delta)
	match kind:
		Kind.INFANTRY:
			_animate_infantry(delta)
		Kind.VEHICLE, Kind.BOAT:
			_animate_vehicle(delta)
		Kind.HOVER, Kind.PLANE:
			_animate_aircraft(delta)
	_fresh = false


func deactivate():
	"""off screen or hidden by the fog of war: keep the pose, forget the speeds"""
	active = false
	_fresh = true


func _detect_kind():
	if unit.movement_domain == Constants.Match.Navigation.Domain.AIR:
		if unit.get_node_or_null("FixedWingFlight") != null:
			return Kind.PLANE
		return Kind.HOVER
	if unit.navigation_domain == Constants.Match.Navigation.Domain.WATER:
		return Kind.BOAT
	var model_path = _model.scene_file_path.to_lower() if _model != null else ""
	for word in INFANTRY_MODEL_WORDS:
		if word in model_path:
			return Kind.INFANTRY
	return Kind.VEHICLE


func _model_aabb(geometry):
	var to_local = geometry.global_transform.affine_inverse()
	var result = null
	for mesh in _pivot.find_children("*", "MeshInstance3D", true, false):
		if not _shown_under_pivot(mesh):
			continue  # the stock geometry that a model from data replaced
		var box = (to_local * mesh.global_transform) * mesh.get_aabb()
		result = box if result == null else result.merge(box)
	if result == null:
		return AABB(Vector3(-0.5, 0, -0.5), Vector3.ONE)
	return result


func _shown_under_pivot(node):
	while node != null and node != _pivot:
		if node is Node3D and not node.visible:
			return false
		node = node.get_parent()
	return true


func _sample_motion(delta):
	var position = unit.global_position
	var forward = -unit.global_basis.z
	var yaw = atan2(forward.x, forward.z)
	var step = max(delta, 0.001)
	if _fresh:
		_previous_position = position
		_previous_yaw = yaw
		_yaw_rate = 0.0
		_acceleration = 0.0
	var speed = 0.0
	if _movement != null and _movement.has_method("get_current_speed"):
		speed = _movement.get_current_speed()  # the driven speed: smooth, no push jitter
	else:
		speed = ((position - _previous_position) * Vector3(1, 0, 1)).length() / step
	if _fresh:
		_previous_speed = speed
	# units move on physics ticks, so frames see uneven steps: low-pass what is derived
	_speed = lerpf(_speed, speed, 1.0 - exp(-12.0 * delta))
	var acceleration = clampf((speed - _previous_speed) / step, -30.0, 30.0)
	_acceleration = lerpf(_acceleration, acceleration, 1.0 - exp(-8.0 * delta))
	var yaw_rate = clampf(wrapf(yaw - _previous_yaw, -PI, PI) / step, -8.0, 8.0)
	_yaw_rate = lerpf(_yaw_rate, yaw_rate, 1.0 - exp(-10.0 * delta))
	_previous_position = position
	_previous_yaw = yaw
	_previous_speed = speed


func _spring(target_pitch, target_roll, delta, softness = 1.0):
	"""pitch and roll follow their targets on damped springs, so a stop rocks the body"""
	var stiffness = SPRING_STIFFNESS / softness
	var damping = SPRING_DAMPING / sqrt(softness)
	delta = min(delta, 0.05)  # a hitch must not throw the spring
	_pitch_velocity += ((target_pitch - _pitch) * stiffness - _pitch_velocity * damping) * delta
	_roll_velocity += ((target_roll - _roll) * stiffness - _roll_velocity * damping) * delta
	_pitch += _pitch_velocity * delta
	_roll += _roll_velocity * delta


func _animate_infantry(delta):
	_moving = lerpf(_moving, clampf((_speed - 0.15) / 1.2, 0.0, 1.0), 1.0 - exp(-8.0 * delta))
	_phase += delta * _speed * 4.4  # about two steps per metre
	var step = sin(_phase)
	var offset = Vector3(0, abs(step) * 0.05 * _moving, 0)
	var roll = step * 0.05 * _moving + clampf(_yaw_rate * _speed * 0.02, -0.1, 0.1)
	var pitch = -0.1 * _moving  # leaning into the walk
	# idle: breathing and a slow weight shift, so a parked squad is never frozen
	var idle = 1.0 - _moving
	var breath = sin(_time * 2.1 + _seed) * idle
	offset.y += (0.5 + 0.5 * sin(_time * 2.1 + _seed)) * 0.012 * idle
	roll += sin(_time * 0.7 + _seed * 3.0) * 0.012 * idle
	var scale = Vector3(1.0, 1.0 + 0.014 * breath, 1.0)
	_kick *= exp(-11.0 * delta)
	pitch += 0.16 * _kick  # the rifle kicks the shoulders back
	offset.z += 0.05 * _kick
	_apply(pitch, roll, offset, scale)


func _animate_vehicle(delta):
	_moving = lerpf(_moving, clampf(_speed / 3.0, 0.0, 1.0), 1.0 - exp(-4.0 * delta))
	var pitch_target = clampf(_acceleration * 0.012, -0.06, 0.06)  # squat, then dive on brakes
	var roll_target = clampf(-_yaw_rate * _speed * 0.025, -0.08, 0.08)  # leans out of turns
	if kind == Kind.BOAT:
		roll_target = -roll_target * 1.5  # hulls bank into the turn
	_spring(pitch_target, roll_target, delta)
	_phase += delta * (5.0 + _speed * 3.0)
	var bump = sin(_phase) * 0.6 + sin(_phase * 2.3 + _seed) * 0.4
	_apply(_pitch, _roll, Vector3(0, bump * 0.01 * _moving, 0), Vector3.ONE)
	for wheel in _wheels:
		# rolling forward (-Z) turns the top of the wheel forward: negative about local X
		wheel[0].rotate_object_local(Vector3.RIGHT, -_speed * delta / wheel[1])


func _animate_aircraft(delta):
	RotorSpin.spin(_rotors, delta)
	if kind == Kind.PLANE:
		_spring(clampf(-_acceleration * 0.01, -0.08, 0.08), _bank(0.6), delta, 2.0)
		_apply(_pitch, _roll, Vector3.ZERO, Vector3.ONE)
		return
	# nose down to fly forward, up to brake, and into the turn
	var pitch_target = clampf(-_speed * 0.06 - _acceleration * 0.03, -0.32, 0.18)
	_spring(pitch_target, _bank(0.35), delta, 2.5)
	var hover = sin(_time * 1.7 + _seed) * 0.06 + sin(_time * 0.63 + _seed * 2.0) * 0.03
	_apply(_pitch, _roll, Vector3(0, hover, 0), Vector3.ONE)


func _bank(limit):
	return clampf(_yaw_rate * _speed * 0.06, -limit, limit)


func _apply(pitch, roll, offset, scale):
	"""rotates about the model's middle (not its base, which would sink the nose into the
	ground) and scales from the ground up"""
	var rotation_basis = Basis.from_euler(Vector3(pitch, 0.0, roll))
	var middle = Vector3(0, center_y, 0)
	_pivot.transform = Transform3D(
		rotation_basis * Basis.from_scale(scale), middle - rotation_basis * middle + offset
	)


func _on_unit_child_entered(node):
	var script = node.get_script()
	if script == null or not "/projectiles/" in script.resource_path:
		return  # shots are added to their shooter (AttackingWhileInRange)
	_kick = 1.0
	if kind == Kind.VEHICLE or kind == Kind.BOAT:
		_pitch_velocity += 0.6  # the gun rocks the hull back
