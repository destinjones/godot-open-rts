extends Node3D

const ShotEffects = preload("res://source/match/units/projectiles/ShotEffects.gd")

const ARC_MIN_DISTANCE = 5.0  # shorter shots fly straight
const ARC_HEIGHT_RATIO = 0.35  # of the distance: long shots at ground targets are lobbed

var target_unit = null

@onready var _unit = get_parent()
@onready var _visuals = find_child("Visuals")
@onready var _path = find_child("Path3D")
@onready var _animation_player = find_child("AnimationPlayer")
@onready var _rocket = find_child("MeshInstance3D")
@onready var _particles = find_child("GPUParticles3D")


func _ready():
	assert(target_unit != null, "target unit was not provided")
	_visuals.visible = _unit.visible
	_rocket.hide()
	_particles.hide()
	target_unit.tree_exited.connect(queue_free)
	_animation_player.animation_finished.connect(func(_animation): queue_free())
	_setup_path()
	# wait 2 frames for path curve setup so that path follow has correct transform
	await get_tree().physics_frame
	await get_tree().physics_frame
	_animation_player.play("animate")


func _physics_process(_delta):
	_path.curve.set_point_position(1, target_unit.global_position)


func _setup_path():
	var projectile_origin = (
		_unit.global_position
		if _unit.find_child("ProjectileOrigin") == null
		else _unit.find_child("ProjectileOrigin").global_position
	)
	_path.curve.add_point(projectile_origin)
	_path.curve.add_point(target_unit.global_position)
	_setup_arc(projectile_origin, target_unit.global_position)
	if _visuals.visible:
		ShotEffects.rocket_launch(_unit, projectile_origin)


func _setup_arc(from, to):
	"""bends the flight up into a lob, so artillery and missiles come down on the target;
	the handles are relative to the end points and survive the target moving"""
	var distance = from.distance_to(to)
	var at_air = (
		"movement_domain" in target_unit
		and target_unit.movement_domain == Constants.Match.Navigation.Domain.AIR
	)
	if distance < ARC_MIN_DISTANCE or at_air:
		return
	var lift = Vector3.UP * distance * ARC_HEIGHT_RATIO
	_path.curve.set_point_out(0, lift + (to - from) * 0.25)
	_path.curve.set_point_in(1, lift * 0.8)


func _perform_hit():
	if not is_instance_valid(target_unit) or not is_instance_valid(_unit):
		return
	if _visuals.visible or target_unit.visible:
		ShotEffects.rocket_impact(
			target_unit, _path.curve.get_point_position(1), _unit.attack_damage
		)
	target_unit.take_damage(_unit.attack_damage, _unit)
