extends Node

# Brings the mobile units to life with procedural body motion (see UnitMotion.gd).
#
# Added to Match. Every spawned mobile unit gets a UnitMotion component; this node drives
# all of them from one _process so that a big match pays one loop, not one callback per
# unit. A unit hidden by the fog of war or outside the camera view is not animated; the
# camera frustum check runs every few frames per unit. With many units on screen, each one is
# posed every second or third frame (with the summed time), which still reads as smooth.
# Pausing the game pauses all of it.
# Purely visual: nothing here changes where a unit is or where it faces.

const UnitMotion = preload("res://source/match/motion/UnitMotion.gd")
const ATTACH_PER_FRAME = 24  # spreads the set-up of a big wave of spawns over frames
const CULL_EVERY_N_FRAMES = 3
const FULL_RATE_UP_TO = 60  # animated units posed every frame; more share the frames
const SKIPPED_TYPES = ["Train"]  # Train.gd animates its own carriages

var _components = []
var _pending = []
var _frame = 0
var _animated = 0  # units animated in the last frame


func _ready():
	MatchSignals.unit_spawned.connect(func(unit): _pending.append(unit))
	MatchSignals.match_started.connect(_on_match_started)


func _process(delta):
	_attach_pending()
	_frame += 1
	var camera = get_viewport().get_camera_3d()
	var planes = camera.get_frustum() if camera != null else []
	var stride = (
		1 if _animated <= FULL_RATE_UP_TO else (2 if _animated <= FULL_RATE_UP_TO * 2 else 3)
	)
	_animated = 0
	var index = 0
	while index < _components.size():
		var component = _components[index]
		if not is_instance_valid(component) or not is_instance_valid(component.unit):
			_components.remove_at(index)
			continue
		index += 1
		var seen = component.active and component.unit.visible  # the fog hides units any time
		if seen and (index + _frame) % CULL_EVERY_N_FRAMES == 0 or not component.active:
			seen = _is_seen(component, planes)
		if seen:
			_animated += 1
			component.pending_delta += delta
			if (index + _frame) % stride == 0 or not component.active:
				component.animate(component.pending_delta)
				component.pending_delta = 0.0
		elif component.active:
			component.deactivate()


func _is_seen(component, planes):
	var unit = component.unit
	if not unit.visible or not unit.is_inside_tree():
		return false
	var center = unit.global_position + Vector3(0, component.center_y, 0)
	for plane in planes:
		if plane.distance_to(center) > component.cull_radius:
			return false
	return true


func _attach_pending():
	var attached = 0
	while not _pending.is_empty() and attached < ATTACH_PER_FRAME:
		var unit = _pending.pop_front()
		if is_instance_valid(unit) and unit.is_inside_tree() and not unit.is_queued_for_deletion():
			_attach(unit)
			attached += 1


func _attach(unit):
	if (
		not unit.has_method("get_movement_trait")
		or unit.get_movement_trait() == null
		or unit.type in SKIPPED_TYPES
		or unit.get_node_or_null("Motion") != null
	):
		return  # buildings and the train
	var component = UnitMotion.new()
	component.name = "Motion"
	unit.add_child(component)
	if not component.setup(unit):
		component.queue_free()
		return
	_components.append(component)


func _on_match_started():
	# units placed in the scene (tests, the editor) are not announced by unit_spawned
	for unit in get_tree().get_nodes_in_group("units"):
		if not unit in _pending:
			_pending.append(unit)
