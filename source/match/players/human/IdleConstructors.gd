extends Node

# Sends the human player's idle constructors to finish sites nobody is building. Placing a
# second building with the same constructor used to leave the first one at 0% for the
# rest of the match, with its materials already delivered, while the other constructors
# stood next to the command centre. The AI has done this all along
# (ConstructionWorksController.gd); auto-expand does it only for constructors it drives.
# A constructor counts as idle once it has had no order for IDLE_BEFORE_S, so a Stop (X)
# is not overridden at once; sites with an enemy at war within DANGER_RADIUS_M are skipped.

const Worker = preload("res://source/match/units/Worker.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Constructing = preload("res://source/match/units/actions/Constructing.gd")
const AutoExpand = preload("res://source/match/units/traits/AutoExpand.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")

const NODE_NAME = "IdleConstructors"
const THINK_INTERVAL_S = 1.0
const IDLE_BEFORE_S = 3.0
const DANGER_RADIUS_M = 14.0

var _idle_since_s = {}  # worker instance id -> clock when it was first seen idle
var _clock_s = 0.0
var _since_think_s = 0.0

@onready var _player = get_parent()


func _process(delta):
	_clock_s += delta
	_since_think_s += delta
	if _since_think_s < THINK_INTERVAL_S:
		return
	_since_think_s = 0.0
	_think()


func _think():
	var units = get_tree().get_nodes_in_group("units")
	var idle = []
	var seen = {}
	for unit in units:
		if not unit is Worker or unit.player != _player or AutoExpand.is_enabled_on(unit):
			continue
		var id = unit.get_instance_id()
		if unit.action != null:
			continue
		seen[id] = true
		var since = _idle_since_s.get(id, _clock_s)
		_idle_since_s[id] = since
		if _clock_s - since >= IDLE_BEFORE_S:
			idle.append(unit)
	for id in _idle_since_s.keys():
		if not id in seen:
			_idle_since_s.erase(id)
	if idle.is_empty():
		return
	var sites = _unclaimed_sites(units)
	for worker in idle:
		if sites.is_empty():
			return
		var closest = null
		for site in sites:
			var distance = worker.global_position_yless.distance_to(site.global_position_yless)
			if closest == null or distance < closest[0]:
				closest = [distance, site]
		sites.erase(closest[1])
		worker.action = Constructing.new(closest[1])
		_idle_since_s.erase(worker.get_instance_id())


func _unclaimed_sites(units):
	var claimed = {}
	for unit in units:
		if unit is Worker and unit.player == _player and unit.action is Constructing:
			var target = unit.action.get("_target_unit")
			if target != null:
				claimed[target] = true
	return units.filter(
		func(unit):
			return (
				unit is Structure
				and unit.player == _player
				and unit.is_under_construction()
				and not unit in claimed
				and _is_safe(unit.global_position_yless, units)
			)
	)


func _is_safe(spot, units):
	for unit in units:
		if unit.player == null or unit.player == _player or unit.attack_damage == null:
			continue
		if not unit.visible or (unit is Structure and not unit.is_constructed()):
			continue
		if not Diplomacy.at_war(_player, unit.player):
			continue
		if unit.global_position_yless.distance_to(spot) <= DANGER_RADIUS_M:
			return false
	return true
