extends Camera3D

# The match (and map editor) camera: orthographic, looking down at 30 degrees.
#
# Screen shake: MatchSignals.camera_shake(strength, world_position) adds "trauma" (0..1)
# that decays over time; the view's offset is trauma to the power 1.5 times smooth noise, so
# a vehicle dying on screen is felt (a few pixels) and a building collapse kicks. A source
# further from the centre of the view shakes less, off-screen ones not at all. The offset goes
# through h_offset/v_offset only, so the camera transform the rest of the game reads
# (picking, minimap) never moves.
# A big hit close to the view also freezes the game for a few frames (hit-stop), only at
# normal speed so the play harness and the debug speed controls are left alone.
# Both are off with the "Screen shake" option.
#
# The mouse wheel zooms smoothly towards the point under the cursor (StarCraft II style), and
# scrolling, by the screen edge or the keys, eases in and out instead of starting and
# stopping dead.

const EXPECTED_X_ROTATION_DEGREES = -30.0
const EXPECTED_PROJECTION = PROJECTION_ORTHOGONAL
const VirtualPointer = preload("res://source/utils/VirtualPointer.gd")
const SHAKE_DECAY = 1.6  # trauma lost per second
const SHAKE_MAX_PER_HIT = 0.6  # one hit never maxes the trauma out on its own
const SHAKE_MAX_OFFSET = 0.045  # at full trauma, as a fraction of the visible height
const SHAKE_FREQUENCY = 14.0  # roughly Hz: a rattle, not a sway
const SHAKE_REACH = 1.0  # sources this many view heights from the centre do not shake
const HIT_STOP_MIN_STRENGTH = 0.45  # after distance attenuation
const HIT_STOP_TIME_SCALE = 0.05
const HIT_STOP_S = 0.06  # real seconds
const HIT_STOP_COOLDOWN_S = 0.6  # a big battle must not turn into a slideshow

@export_group("Size")
@export var size_min = 1
@export var size_max = 20
@export_group("Movement")
@export var screen_margin_for_movement = 2  # px
@export var movement_speed = 1.1
@export var bounding_planes: Array[Plane] = []
@export var scroll_ease_in_s = 0.12  # from standing to full speed
@export var scroll_ease_out_s = 0.08  # from full speed to standing
@export var zoom_smoothing = 14.0  # 1/s: how fast the size follows the wheel
@export var zoom_to_cursor = true
@export_group("Rotation")
@export var mouse_rotation_speed = 0.005  # [rad/px]
@export var arrowkey_rotation_speed = 2  # [rad/s]
@export var default_y_rotation_degrees = 0.0
@export var reference_plane_for_rotation = Plane(Vector3.UP, 0.0)
@export_group("View")
@export var visible_height_min = -10
@export var visible_height_max = 10

var _mouse_pos_when_rotation_started = null
var _camera_global_pos_when_rotation_started = null
var _trauma = 0.0
var _shake_time = 0.0
var _shake_noise = FastNoiseLite.new()
var _last_hit_stop_ms = -100000
var _scroll_velocity = Vector2.ZERO  # -1..1 per axis, eased towards the wanted direction
var _target_size = null  # where a wheel zoom is heading
var _zoom_anchor = null  # the screen point that stays put while zooming


func _ready():
	assert(projection == EXPECTED_PROJECTION, "unexpected projection")
	assert(
		is_equal_approx(rotation_degrees.x, EXPECTED_X_ROTATION_DEGREES), "unexptected X rotation"
	)
	_align_camera_properties_to_current_size()
	_shake_noise.seed = randi()
	_shake_time = randf() * 100.0
	_shake_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_shake_noise.fractal_type = FastNoiseLite.FRACTAL_NONE  # the full -1..1 range
	_shake_noise.frequency = SHAKE_FREQUENCY
	MatchSignals.camera_shake.connect(add_shake)


func _process(delta: float):
	# real time, capped so that one long frame (a hitch) does not swallow the whole shake
	_update_shake(min(delta / max(Engine.time_scale, 0.001), 1.0 / 30.0))
	_update_zoom(delta / max(Engine.time_scale, 0.001))


func add_shake(strength: float, world_position = null):
	"""MatchSignals.camera_shake: strength 0..1, weaker the further from the view's centre"""
	if not Globals.options.screen_shake or not current or not is_inside_tree():
		return
	var attenuation = 1.0
	if world_position is Vector3:
		var focus = get_ray_intersection(get_viewport().size / 2.0)
		if focus != null:
			var distance = ((world_position - focus) * Vector3(1, 0, 1)).length()
			attenuation = 1.0 - clamp(distance / (size * SHAKE_REACH), 0.0, 1.0)
	var felt = clamp(strength, 0.0, SHAKE_MAX_PER_HIT) * attenuation
	if felt <= 0.0:
		return
	_trauma = min(1.0, _trauma + felt)
	if felt >= HIT_STOP_MIN_STRENGTH:
		_hit_stop()


func _hit_stop():
	var now_ms = Time.get_ticks_msec()
	if (
		Engine.time_scale != 1.0
		or get_tree().paused
		or now_ms - _last_hit_stop_ms < HIT_STOP_COOLDOWN_S * 1000.0
	):
		return
	_last_hit_stop_ms = now_ms
	Engine.time_scale = HIT_STOP_TIME_SCALE
	# a real-time timer that also runs while paused, so the speed always comes back
	get_tree().create_timer(HIT_STOP_S, true, false, true).timeout.connect(
		func():
			if Engine.time_scale == HIT_STOP_TIME_SCALE:
				Engine.time_scale = 1.0
	)


func _update_shake(delta: float):
	if _trauma <= 0.0:
		if h_offset != 0.0 or v_offset != 0.0:
			h_offset = 0.0
			v_offset = 0.0
		return
	_trauma = max(0.0, _trauma - SHAKE_DECAY * delta)
	_shake_time += delta
	var amount = pow(_trauma, 1.5) * SHAKE_MAX_OFFSET * size
	# two far-apart rows of the same noise, so the axes move independently
	h_offset = amount * _shake_noise.get_noise_2d(_shake_time, 0.0)
	v_offset = amount * _shake_noise.get_noise_2d(_shake_time, 50.0)


func _physics_process(delta: float):
	var realtime_delta = delta / Engine.time_scale
	if _try_handling_movement(realtime_delta):
		return
	_try_handling_arrowkey_rotation(realtime_delta)


func _unhandled_input(event: InputEvent):
	_try_handling_zoom(event)
	_try_handling_mouse_rotation(event)


func set_size_safely(a_size: float):
	_target_size = null  # a size set from code wins over a wheel zoom on its way
	_set_size(a_size)


func _set_size(a_size: float):
	if a_size == size:
		return
	size = clamp(a_size, size_min, size_max)
	_align_camera_properties_to_current_size()


func set_position_safely(target_position: Vector3):
	global_transform.origin = _target_position_to_camera_position(target_position)


func get_ray_intersection(mouse_pos: Vector2) -> Variant:
	return get_ray_intersection_with_plane(mouse_pos, reference_plane_for_rotation)


func get_ray_intersection_with_plane(mouse_pos: Vector2, plane: Plane) -> Variant:
	return plane.intersects_ray(project_ray_origin(mouse_pos), project_ray_normal(mouse_pos))


func _try_handling_movement(delta: float) -> bool:
	if _is_rotating():
		return false

	var wanted = _calculate_screen_move_vector()
	wanted = wanted.normalized() if not wanted.is_zero_approx() else Vector2.ZERO
	var ease_s = (
		scroll_ease_in_s if wanted.length() >= _scroll_velocity.length() else scroll_ease_out_s
	)
	_scroll_velocity = _scroll_velocity.move_toward(wanted, delta / max(ease_s, 0.001))
	if _scroll_velocity.is_zero_approx():
		_scroll_velocity = Vector2.ZERO
		return false

	var scaled_screen_move_vector = (
		_scroll_velocity
		* delta
		* Vector2(movement_speed, movement_speed * 2.0)
		* _scroll_speed_factor()
		* size
	)
	var camera_move_vector = (
		Vector3(scaled_screen_move_vector.x, 0, scaled_screen_move_vector.y)
		. rotated(Vector3(0, 1, 0), rotation.y)
	)
	global_translate(camera_move_vector)
	_align_position_to_bounding_planes()
	return true


func _calculate_screen_move_vector() -> Vector2:
	var viewport_size = get_viewport().size
	var mouse_pos = VirtualPointer.get_position(get_viewport())

	var x_axis = Input.get_axis("move_map_left", "move_map_right")
	var y_axis = Input.get_axis("move_map_up", "move_map_down")
	var move_vector = Vector2(x_axis, y_axis)

	if not _edge_scrolling_enabled():
		return move_vector

	if mouse_pos.x <= screen_margin_for_movement:
		move_vector.x = -1

	if mouse_pos.x >= viewport_size.x - screen_margin_for_movement:
		move_vector.x = 1

	if mouse_pos.y <= screen_margin_for_movement:
		move_vector.y = -1

	if mouse_pos.y >= viewport_size.y - screen_margin_for_movement:
		move_vector.y = 1

	return move_vector


func _try_handling_zoom(event: InputEvent):
	if not event is InputEventMouseButton or not event.is_pressed():
		return
	var zoom_in_button = MOUSE_BUTTON_WHEEL_DOWN if _zoom_inverted() else MOUSE_BUTTON_WHEEL_UP
	var zoom_out_button = MOUSE_BUTTON_WHEEL_UP if _zoom_inverted() else MOUSE_BUTTON_WHEEL_DOWN
	if event.button_index == zoom_in_button:
		_zoom_in()
	elif event.button_index == zoom_out_button:
		_zoom_out()


# the player's camera options (Options.gd); the map editor shares this camera
func _scroll_speed_factor() -> float:
	return Globals.options.camera_scroll_speed


func _edge_scrolling_enabled() -> bool:
	return Globals.options.edge_scrolling


func _zoom_inverted() -> bool:
	return Globals.options.invert_zoom


func _zoom_in():
	_zoom_by(-1)


func _zoom_out():
	_zoom_by(1)


func _zoom_by(steps):
	var from = _target_size if _target_size != null else size
	_target_size = clamp(from + steps, size_min, size_max)
	_zoom_anchor = VirtualPointer.get_position(get_viewport()) if zoom_to_cursor else null


func _update_zoom(delta: float):
	if _target_size == null:
		return
	var new_size = lerp(size, float(_target_size), 1.0 - exp(-zoom_smoothing * delta))
	if abs(new_size - _target_size) < 0.01:
		new_size = _target_size
		_target_size = null
	var anchor = _zoom_anchor
	var before = get_ray_intersection(anchor) if anchor != null else null
	_set_size(new_size)
	if before != null:
		# keep the ground under the cursor where it was: zoom towards the cursor
		var after = get_ray_intersection(anchor)
		if after != null:
			global_translate((before - after) * Vector3(1, 0, 1))
			_align_position_to_bounding_planes()


func _try_handling_arrowkey_rotation(delta: float):
	if _is_rotating():
		return
	var angle_radians = (
		delta
		* Input.get_axis("rotate_map_counterclockwise", "rotate_map_clockwise")
		* arrowkey_rotation_speed
	)
	if not is_zero_approx(angle_radians):
		_rotate_from_reference_position_by(global_position, angle_radians)


func _try_handling_mouse_rotation(event: InputEvent):
	if event is InputEventMouseButton:
		if event.is_pressed() and event.button_index == MOUSE_BUTTON_MIDDLE and event.double_click:
			_reset_rotation()
		elif event.is_pressed() and event.button_index == MOUSE_BUTTON_MIDDLE:
			_start_rotation(event)
		elif not event.is_pressed() and event.button_index == MOUSE_BUTTON_MIDDLE:
			_stop_rotation()
	elif event is InputEventMouseMotion and _is_rotating():
		var mouse_pos = event.position
		var angle_radians = (
			(mouse_pos.x - _mouse_pos_when_rotation_started.x) * mouse_rotation_speed
		)
		_rotate_from_reference_position_by(_camera_global_pos_when_rotation_started, angle_radians)


func _reset_rotation():
	var pivot_point = _calculate_pivot_point()
	if pivot_point == null:
		return
	var camera_position = global_position
	var camera_position_yless = camera_position * Vector3(1, 0, 1)
	var pivot_point_yless = pivot_point * Vector3(1, 0, 1)
	var pivot_to_camera_distance_yless = camera_position_yless.distance_to(pivot_point_yless)
	var new_camera_position_yless = (
		pivot_point_yless
		- (
			Vector3(0, 0, -1).normalized().rotated(
				-Vector3.UP, deg_to_rad(-default_y_rotation_degrees)
			)
			* pivot_to_camera_distance_yless
		)
	)
	global_position = Vector3(
		new_camera_position_yless.x, camera_position.y, new_camera_position_yless.z
	)
	global_transform = global_transform.looking_at(pivot_point, Vector3(0, 1, 0))


func _start_rotation(event: InputEvent):
	_mouse_pos_when_rotation_started = event.position
	_camera_global_pos_when_rotation_started = global_transform.origin


func _stop_rotation():
	_mouse_pos_when_rotation_started = null


func _rotate_from_reference_position_by(reference_position: Vector3, angle_radians: float):
	var pivot_point = _calculate_pivot_point()
	if pivot_point == null:
		return
	var diff_vec = reference_position - pivot_point
	var rotated_diff_vec = diff_vec.rotated(-Vector3.UP, angle_radians)
	var rotated_reference_position = pivot_point + rotated_diff_vec
	global_position = rotated_reference_position
	global_transform = global_transform.looking_at(pivot_point, Vector3.UP)


func _is_rotating() -> bool:
	return _mouse_pos_when_rotation_started != null


func _calculate_pivot_point() -> Vector3:
	var screen_center_pos_2d = get_viewport().size / 2.0
	return get_ray_intersection_with_plane(screen_center_pos_2d, reference_plane_for_rotation)


func _align_camera_properties_to_current_size():
	_align_camera_properties_to_size(size)


func _align_camera_properties_to_size(a_size: float):
	_align_camera_position_to_size(a_size)
	_align_camera_far_to_size(a_size)


func _align_camera_position_to_size(a_size: float):
	var alpha_degrees = 60
	var beta_degrees = 90 - alpha_degrees
	var target_height = (
		a_size * sin(deg_to_rad(alpha_degrees)) / 2.0
		+ sin(deg_to_rad(beta_degrees))
		+ visible_height_max
	)
	var target_camera_plane = Plane(Vector3.UP, target_height)
	var camera_ray_normal = project_ray_normal(Vector2(0, 0))
	var target_camera_pos = target_camera_plane.intersects_ray(
		global_transform.origin, camera_ray_normal
	)
	if target_camera_pos == null:
		target_camera_pos = target_camera_plane.intersects_ray(
			global_transform.origin, -camera_ray_normal
		)
	global_transform.origin = target_camera_pos


func _align_camera_far_to_size(a_size: float):
	var up = (project_position(Vector2(0, 0), 0) - project_position(Vector2(0, 1), 0)).normalized()
	var camera_ray_begin = project_position(Vector2(0, 0), 0) + up * (a_size - size) / 2.0
	var camera_ray_normal = project_ray_normal(Vector2(0, 0))
	var min_visible_plane = Plane(Vector3.UP, visible_height_min)
	var ray_intersection = min_visible_plane.intersects_ray(camera_ray_begin, camera_ray_normal)
	far = ceil(ray_intersection.distance_to(camera_ray_begin))


func _align_position_to_bounding_planes():
	var pivot_point = _calculate_pivot_point()
	var aligned_pivot_point = _clamp_position_to_bounding_planes(pivot_point)
	var diff = aligned_pivot_point - pivot_point
	global_transform.origin += diff


func _clamp_position_to_bounding_planes(a_position: Vector3) -> Vector3:
	for bounding_plane in bounding_planes:
		if not bounding_plane.is_point_over(a_position):
			a_position = a_position - bounding_plane.normal * bounding_plane.distance_to(a_position)
	return a_position


func _target_position_to_camera_position(target_position: Vector3) -> Vector3:
	target_position = _clamp_position_to_bounding_planes(target_position)
	var screen_center_pos_2d = get_viewport().size / 2.0
	var camera_ray = project_ray_normal(screen_center_pos_2d)
	var target_plane = Plane(Vector3.UP, target_position.y)
	var intersection = target_plane.intersects_ray(global_transform.origin, camera_ray)
	var offset_yless = (target_position - intersection) * Vector3(1, 0, 1)
	return global_transform.origin + offset_yless
