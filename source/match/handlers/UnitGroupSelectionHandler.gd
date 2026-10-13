extends Node3D

# Control groups 1-9, StarCraft II style:
# - Ctrl + N: the selection becomes group N,
# - Shift + N: the selection is added to group N,
# - N: selects group N; pressing N again quickly centres the camera on it.
# A unit can be in several groups. The on-screen bar (hud/ControlGroupBar.gd) listens to
# the signals below.

signal group_changed(group_id)
signal group_recalled(group_id)
var double_tap_ms = 400

var _set_action_names = [null]
var _add_action_names = [null]
var _get_action_names = [null]
var _unit_group_names = [null]
var _last_recalled_group = 0
var _last_recalled_ms = -100000


func _ready():
	add_to_group("unit_group_selection_handler")
	for group_id in range(1, 10):
		_set_action_names.append("unit_groups_set_{0}".format([group_id]))
		_add_action_names.append("unit_groups_add_{0}".format([group_id]))
		_get_action_names.append("unit_groups_access_{0}".format([group_id]))
		_unit_group_names.append("unit_group_{0}".format([group_id]))


static func of(tree):
	return tree.get_first_node_in_group("unit_group_selection_handler")


func _input(event):
	# the number keys also match "access" while Ctrl or Shift is held, so those go first
	for group_id in range(1, 10):
		if event.is_action_pressed(_set_action_names[group_id]):
			set_group(group_id)
			return
		if event.is_action_pressed(_add_action_names[group_id]):
			add_to_group_of_selection(group_id)
			return
		if event.is_action_pressed(_get_action_names[group_id]):
			access_group(group_id)
			return


func units_in_group(group_id: int):
	return get_tree().get_nodes_in_group(_unit_group_names[group_id])


func access_group(group_id: int):
	var units = units_in_group(group_id)
	if units.is_empty():
		return
	var now_ms = Time.get_ticks_msec()
	var double_tap = (
		group_id == _last_recalled_group and now_ms - _last_recalled_ms <= double_tap_ms
	)
	_last_recalled_group = 0 if double_tap else group_id
	_last_recalled_ms = now_ms
	Utils.Match.select_units(Utils.Set.from_array(units))
	if double_tap:
		centre_camera_on_group(group_id)
	group_recalled.emit(group_id)


func centre_camera_on_group(group_id: int):
	var units = units_in_group(group_id)
	var camera = get_viewport().get_camera_3d()
	if units.is_empty() or camera == null or not camera.has_method("set_position_safely"):
		return
	var centre = Vector3.ZERO
	for unit in units:
		centre += unit.global_position * Vector3(1, 0, 1)
	camera.set_position_safely(centre / units.size())


func set_group(group_id: int):
	for unit in units_in_group(group_id):
		unit.remove_from_group(_unit_group_names[group_id])
	add_to_group_of_selection(group_id)


func add_to_group_of_selection(group_id: int):
	for unit in get_tree().get_nodes_in_group("selected_units"):
		if unit.is_in_group("controlled_units"):
			unit.add_to_group(_unit_group_names[group_id])
	group_changed.emit(group_id)
