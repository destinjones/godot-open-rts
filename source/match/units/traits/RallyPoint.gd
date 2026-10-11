extends Node3D

# Where units made by this building go. The marker shows while the building is selected,
# on the ground or on the unit it follows; UnitCommandHandler draws the line to it.

var target_unit = null:
	set(a_target_unit):
		if target_unit == null and a_target_unit != null:
			a_target_unit.tree_exited.connect(_on_target_unit_tree_exited)
		elif target_unit != null and a_target_unit == null:
			target_unit.tree_exited.disconnect(_on_target_unit_tree_exited)
			_reset_position_to_parent()
			if _unit.is_in_group("selected_units"):
				show()
		target_unit = a_target_unit

@onready var _unit = get_parent()
@onready var _animation_player = find_child("AnimationPlayer")


func _ready():
	_animation_player.play("idle")
	visible = _unit.is_in_group("selected_units")
	_unit.selected.connect(_show)
	_unit.deselected.connect(hide)


func _physics_process(_delta):
	if target_unit != null:
		global_position = target_unit.global_position


func is_set():
	"""a rally point that sends the units somewhere, not one left on the building"""
	return target_unit != null or (global_position - _unit.global_position).length() > 0.5


func _show():
	show()
	if target_unit != null:
		var targetability = target_unit.find_child("Targetability")
		if targetability != null:
			targetability.animate()


func _reset_position_to_parent():
	global_position = _unit.global_position


func _on_target_unit_tree_exited():
	target_unit = null
