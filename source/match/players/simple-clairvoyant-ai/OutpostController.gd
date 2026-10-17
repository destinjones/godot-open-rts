extends Node

# Sends a small squad to take the map's neutral outposts (see Outposts.gd): the nearest one
# not held by this AI or an ally first, an enemy's one only when the AI would attack that
# player anyway. The squad is the faction's "raider" role, ordered from the vehicle factory
# like RaidingController's; once every outpost in reach is held it stays on the last one.

signal resources_required(resources, metadata)

const Factions = preload("res://source/data-model/Factions.gd")
const VehicleFactory = preload("res://source/match/units/VehicleFactory.gd")
const AttackMoving = preload("res://source/match/units/actions/AttackMoving.gd")
const Outposts = preload("res://source/match/outposts/Outposts.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")

const RETARGET_INTERVAL_S = 3.0

var _player = null
var _squad = []
var _pending_requests = 0
var _awaited = 0
var _unit_scene = null
var _target = null

@onready var _ai = get_parent()


func setup(player):
	_player = player
	var path = Factions.role_scene_of(player, "raider")
	_unit_scene = load(path) if path != null else null
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	var timer = Timer.new()
	var interval = _ai.think_interval(RETARGET_INTERVAL_S)
	timer.timeout.connect(_tick)
	add_child(timer)
	timer.start(interval)


func provision(resources, _metadata):
	_pending_requests -= 1
	var factory = _factory()
	if factory == null or _unit_scene == null or not _player.has_resources(resources):
		return
	if factory.production_queue.produce(_unit_scene, true) != null:
		_awaited += 1


func committed_units():
	return _squad.filter(func(unit): return is_instance_valid(unit))


func claims(unit):
	if unit in _squad:
		return true
	if (
		_awaited <= 0
		or unit.player != _player
		or _unit_scene == null
		or unit._scene_path() != _unit_scene.resource_path
	):
		return false
	_awaited -= 1
	_squad.append(unit)
	return true


func target():
	return _target


func _tick():
	var system = Outposts.of(get_tree())
	if system == null or system.outposts.is_empty() or _unit_scene == null:
		return
	var config = system.config
	if _ai.match_time_s < float(config.get("ai_first_outpost_after_s", 90.0)):
		return
	_squad = _squad.filter(func(unit): return is_instance_valid(unit) and unit.is_inside_tree())
	var wanted = int(config.get("ai_squad_size", 2))
	if (
		_squad.size() + _pending_requests + _awaited < wanted
		and _factory() != null
		and _pick_target(system) != null
	):
		_pending_requests += 1
		resources_required.emit(
			Constants.Match.Units.PRODUCTION_COSTS[_unit_scene.resource_path], "outpost"
		)
	if _squad.is_empty():
		return
	var next = _pick_target(system)
	if next != null:
		_target = next
	if _target == null or not is_instance_valid(_target):
		return
	for unit in _squad:
		var far = (
			unit.global_position_yless.distance_to(_target.global_position * Vector3(1, 0, 1))
			> _target.radius * 0.6
		)
		if far and not unit.action is AttackMoving:
			unit.action = AttackMoving.new(_target.global_position)


func _pick_target(system):
	var centre = _squad_centre()
	var best = null
	var best_distance = INF
	for outpost in system.outposts:
		var holder = outpost.owner_player
		if holder != null and is_instance_valid(holder):
			if holder == _player or Diplomacy.allied(holder, _player):
				continue
			if not _ai.wants_to_attack(holder) or not _ai.may_launch_attacks():
				continue
		var distance = outpost.global_position.distance_to(centre)
		if distance < best_distance:
			best_distance = distance
			best = outpost
	return best


func _squad_centre():
	var alive = committed_units()
	if alive.is_empty():
		var factory = _factory()
		return factory.global_position if factory != null else Vector3.ZERO
	var sum = Vector3.ZERO
	for unit in alive:
		sum += unit.global_position
	return sum / alive.size()


func _factory():
	for unit in get_tree().get_nodes_in_group("units"):
		if unit is VehicleFactory and unit.player == _player and unit.is_constructed():
			return unit
	return null


func _on_unit_spawned(unit):
	claims(unit)
