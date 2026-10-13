extends RefCounted

# A turret, gun or launcher that aims on its own, the way Company of Heroes tanks do: it
# traverses toward the unit's attack target at its own slew rate (easing in and out),
# independently of the hull, leads a moving target by the shot's flight time, elevates
# launchers, kicks back along its own barrel on every shot and springs home, then holds a
# moment and swings back to the front when the fight is over. The kick is mostly the
# barrel sliding into the mantlet (the part is squashed along its barrel, so the muzzle
# travels "recoil_m" while the turret body barely moves) plus a small jolt of the whole part.
# A defensive structure's turret (its base stays put, see AntiGroundTurret.tscn) tracks the
# same way and, when idle, follows the structure's own scanning rotation.
#
# The part is found by name in the unit's model ("parts" in data/movement.json "turrets"),
# so only models with a separate turret node get one; single-mesh models keep the plain
# recoil of ShotEffects. The unit's ProjectileOrigin is moved onto the part so muzzle
# flashes, tracers and rockets leave from the barrel wherever it points; projectiles take
# their start only for their visuals, damage and timing do not depend on it.
# Purely visual: it reads the unit's attack target, it never changes what, when or whether
# the unit fires. Driven for on-screen units only: by UnitMotion for vehicles and boats, by
# MotionManager for structures.

const GameData = preload("res://source/data-model/GameData.gd")
const ShotEffects = preload("res://source/match/units/projectiles/ShotEffects.gd")
const AttackingWhileInRange = preload("res://source/match/units/actions/AttackingWhileInRange.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")

const RECOIL_DAMPING_RATIO = 0.75
const TARGET_SCAN_S = 0.1  # how often the unit's action is searched for its target
const CLASS_DEFAULTS = {
	"slew_deg_s": 90.0,
	"slew_accel_deg_s2": 360.0,
	"traverse_limit_deg": 180.0,
	"lead": "shell",  # "shell": flight time of a cannon shell, or a number of seconds
	"loft_deg_per_m": 0.0,
	"min_elevation_deg": -5.0,
	"max_elevation_deg": 15.0,
	"elevation_deg_s": 30.0,
	"recoil_m": 0.06,  # how far the muzzle travels back, metres
	"recoil_slide": 0.3,  # the share of it that moves the whole part
	"recoil_pitch_deg": 2.0,
	"recoil_return_s": 0.35,
	"hull_rock": 0.6,
}

var unit = null
var part = null  # the Node3D that turns
var config = {}
var target = null

var _rest = Transform3D()
var _rest_elevation = 0.0
var _parent_scale = 1.0
var _part_scale = 1.0
var _muzzle_reach = 1.0  # from the pivot to the muzzle along the barrel, part units
var _structure = false
var _yaw = 0.0
var _yaw_velocity = 0.0
var _wanted_previous = null  # last frame's wanted bearing, for its rate of change
var _wanted_rate = 0.0  # how fast the wanted bearing swings (target crossing, hull turning)
var _elevation = 0.0  # added to the rest elevation, radians
var _recoil = 0.0  # 1 right after a shot, back to 0 at rest
var _since_shot = INF
var _scan_s = 0.0
var _idle_s = 0.0
var _target_previous = null
var _target_velocity = Vector3.ZERO


static func create(a_unit, model):
	"""a TurretAim for the unit's turret, gun or launcher; null when its model has none"""
	if model == null:
		return null
	var settings = turret_settings()
	var found = null
	for part_name in settings.get("parts", []):
		found = model.find_child(part_name, true, false)
		if found is Node3D and _shown_in(found, model):
			break
		found = null
	if found == null:
		return null
	var aim = new()
	aim._setup(a_unit, found, settings)
	return aim


static func _shown_in(node, model):
	"""not hidden inside the model (the fog of war may hide the whole unit for now)"""
	while node != null and node != model:
		if node is Node3D and not node.visible:
			return false
		node = node.get_parent()
	return true


static func turret_settings():
	var movement = GameData.movement()
	return movement.get("turrets", {})


func _setup(a_unit, a_part, settings):
	unit = a_unit
	part = a_part
	_rest = part.transform
	var forward = -(_rest.basis.z.normalized())
	_rest_elevation = asin(clampf(forward.y, -1.0, 1.0))
	var parent = part.get_parent() as Node3D
	_parent_scale = maxf(parent.global_basis.get_scale().x, 0.001)
	_part_scale = maxf(part.global_basis.get_scale().x, 0.001)
	if part is MeshInstance3D:
		_muzzle_reach = maxf(-part.get_aabb().position.z, 0.05)
	_structure = unit.get_movement_trait() == null
	var entry = GameData.unit_by_scene(unit._scene_path()) if "player" in unit else null
	var unit_id = entry.get("id", "") if entry != null else ""
	var turret_class = settings.get("by_unit", {}).get(unit_id, settings.get("default", ""))
	config = CLASS_DEFAULTS.duplicate()
	config.merge(settings.get("classes", {}).get(turret_class, {}), true)
	config["return_delay_s"] = float(settings.get("return_delay_s", 1.5))
	_move_projectile_origin()
	unit.set_meta("_turret_recoil", true)  # ShotEffects.recoil leaves the hull alone


func _move_projectile_origin():
	"""puts the unit's muzzle marker on the barrel tip so shots leave where it points"""
	var origin = unit.find_child("ProjectileOrigin", true, false)
	if origin == null or not part is MeshInstance3D:
		return
	var box = part.get_aabb()
	var muzzle = Vector3(box.get_center().x, box.get_center().y, box.position.z)
	origin.reparent(part, true)
	origin.position = muzzle


func animate(delta):
	_scan_s -= delta
	if _scan_s <= 0.0:
		_scan_s = TARGET_SCAN_S
		var found = _find_target(unit.action)
		if found != null:
			target = found
	if target != null and (not is_instance_valid(target) or not target.is_inside_tree()):
		target = null
	var wanted_yaw = 0.0
	var wanted_elevation = 0.0
	if target != null:
		_track_target(delta)
		var aim = _aim_point()
		var to_aim = _to_local(aim)
		var flat = Vector2(to_aim.x, to_aim.z).length()
		wanted_yaw = atan2(-to_aim.x, -to_aim.z)
		var limit = deg_to_rad(float(config["traverse_limit_deg"]))
		wanted_yaw = clampf(wanted_yaw, -limit, limit)
		var flat_m = flat * _parent_scale
		var elevation = (
			atan2(to_aim.y, maxf(flat, 0.001))
			+ deg_to_rad(float(config["loft_deg_per_m"]) * flat_m)
		)
		elevation = clampf(
			elevation,
			deg_to_rad(float(config["min_elevation_deg"])),
			deg_to_rad(float(config["max_elevation_deg"]))
		)
		wanted_elevation = elevation - _rest_elevation
		_idle_s = 0.0
	else:
		if _target_previous != null:
			_target_previous = null
			unit.set_meta("_aim_velocity", Vector3.ZERO)
		_idle_s += delta
		if _structure:
			wanted_yaw = _bearing_of(unit.global_position - unit.global_basis.z)
		elif _idle_s < config["return_delay_s"]:
			wanted_yaw = _yaw  # hold the last bearing a moment, then swing home
			wanted_elevation = _elevation
	_slew(wanted_yaw, wanted_elevation, target != null, delta)
	_spring_recoil(delta)
	_pose()


func _to_local(point):
	"""point relative to the part's pivot, in its parent's space (the hull's)"""
	return (part.get_parent() as Node3D).global_transform.affine_inverse() * point - _rest.origin


func _bearing_of(point):
	var to_point = _to_local(point)
	return atan2(-to_point.x, -to_point.z)


func fire(shot_target):
	"""a shot left this unit: kick the barrel back"""
	if shot_target != null and is_instance_valid(shot_target):
		target = shot_target
	_since_shot = 0.0


func hull_kick():
	"""(pitch, roll) impulse for the hull: it rocks away from the barrel"""
	var rock = float(config["hull_rock"])
	return Vector2(rock * cos(_yaw), -rock * sin(_yaw))


func _find_target(action):
	if action == null or not is_instance_valid(action):
		return null
	var script = action.get_script()
	if script == AttackingWhileInRange or script == AutoAttacking:
		var found = action.get("_target_unit")
		if found != null and is_instance_valid(found):
			return found
	for child in action.get_children():
		if not child is Timer:
			var found = _find_target(child)
			if found != null:
				return found
	return null


func _track_target(delta):
	"""the target's velocity from its movement on screen, low-passed"""
	var position = target.global_position
	if _target_previous != null and delta > 0.0:
		var velocity = (position - _target_previous) / delta
		if velocity.length() > 30.0:
			velocity = Vector3.ZERO  # a teleport or a new target, not a speed
		_target_velocity = _target_velocity.lerp(velocity, 1.0 - exp(-6.0 * delta))
	else:
		_target_velocity = Vector3.ZERO
	_target_previous = position
	unit.set_meta("_aim_velocity", _target_velocity)


func _aim_point():
	var shape = target.find_child("CollisionShape3D", false, false)
	var point = shape.global_position if shape != null else target.global_position
	var lead_s = 0.0
	if str(config["lead"]) == "shell":
		lead_s = ShotEffects.shell_flight_s(part.global_position.distance_to(point))
	else:
		lead_s = float(config["lead"])
	return point + _target_velocity * lead_s


func _slew(wanted_yaw, wanted_elevation, tracking, delta):
	"""traverse with a top speed and an acceleration, so a turn starts and stops with weight;
	while tracking, the swing of the wanted bearing (a crossing target, the hull turning
	underneath) is fed forward so the barrel stays on a moving target instead of trailing"""
	var max_rate = deg_to_rad(float(config["slew_deg_s"]))
	var accel = deg_to_rad(float(config["slew_accel_deg_s2"]))
	var feed = 0.0
	if tracking and _wanted_previous != null and delta > 0.0:
		var swing = clampf(
			wrapf(wanted_yaw - _wanted_previous, -PI, PI) / delta, -max_rate, max_rate
		)
		_wanted_rate = lerpf(_wanted_rate, swing, 1.0 - exp(-12.0 * delta))
		feed = _wanted_rate
	else:
		_wanted_rate = 0.0
	_wanted_previous = wanted_yaw if tracking else null
	var error = wrapf(wanted_yaw - _yaw, -PI, PI)
	# the fastest speed that can still brake to a stop at the wanted bearing
	var brake_rate = sqrt(2.0 * accel * absf(error))
	var want_rate = clampf(feed + signf(error) * minf(max_rate, brake_rate), -max_rate, max_rate)
	_yaw_velocity = move_toward(_yaw_velocity, want_rate, accel * delta)
	if absf(error) < 0.002 and absf(_yaw_velocity - feed) < 0.05:
		_yaw_velocity = feed
		_yaw = wanted_yaw
	else:
		_yaw = wrapf(_yaw + _yaw_velocity * delta, -PI, PI)
	var elevation_rate = deg_to_rad(float(config["elevation_deg_s"])) * delta
	_elevation = move_toward(_elevation, wanted_elevation, elevation_rate)


func _spring_recoil(delta):
	"""snaps back on the shot, then eases home like a slightly underdamped spring; solved in
	closed form, so a long frame (or a short return time) can never make it blow up"""
	_since_shot += delta
	var omega = 4.0 / maxf(float(config["recoil_return_s"]), 0.05)
	if _since_shot * omega > 12.0:
		_recoil = 0.0
		return
	var damping = RECOIL_DAMPING_RATIO * omega
	var ringing = omega * sqrt(1.0 - RECOIL_DAMPING_RATIO * RECOIL_DAMPING_RATIO)
	var t = _since_shot
	_recoil = exp(-damping * t) * (cos(ringing * t) + damping / ringing * sin(ringing * t))


func _pose():
	var turn = Basis(Vector3.UP, _yaw)
	var lift = _elevation + deg_to_rad(float(config["recoil_pitch_deg"])) * maxf(_recoil, 0.0)
	var recoil_m = float(config["recoil_m"]) * _recoil
	var slide_share = float(config["recoil_slide"])
	# the barrel slides in: shorten the part along its barrel so the muzzle comes back
	var squash = 1.0 - recoil_m * (1.0 - slide_share) / (_part_scale * _muzzle_reach)
	var basis = (
		turn
		* Basis(Vector3.RIGHT, lift)
		* _rest.basis
		* Basis.from_scale(Vector3(1.0, 1.0, clampf(squash, 0.6, 1.2)))
	)
	var back = turn * Vector3(0, 0, 1) * (recoil_m * slide_share / _parent_scale)
	part.transform = Transform3D(basis, _rest.origin + back)
