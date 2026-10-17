extends Area3D

const ResourceDecayAnimation = preload("res://source/match/utils/ResourceDecayAnimation.tscn")

var radius:
	get:
		if _obstacle == null:
			_obstacle = find_child("MovementObstacle")  # a deep search: look it up once
		return _obstacle.radius
var global_position_yless:
	get:
		return global_position * Vector3(1, 0, 1)

var _obstacle = null


func _enter_tree():
	tree_exiting.connect(_animate_decay)


func _animate_decay():
	var decay_animation = ResourceDecayAnimation.instantiate()
	decay_animation.global_transform = global_transform
	get_parent().add_child.call_deferred(decay_animation)
