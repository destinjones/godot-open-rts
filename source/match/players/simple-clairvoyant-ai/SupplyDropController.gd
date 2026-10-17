extends Node

# Sends the nearest free ground unit to a supply crate that lands near the AI's army (see
# SupplyDrops.gd), and lets it go back to the army once the crate is taken by anyone.

const Moving = preload("res://source/match/units/actions/Moving.gd")
const SupplyDrops = preload("res://source/match/supply-drops/SupplyDrops.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Worker = preload("res://source/match/units/Worker.gd")

const RETRY_S = 2.0

var _player = null
var _runners = {}  # crate -> unit sent for it

@onready var _ai = get_parent()


func setup(player):
	_player = player
	MatchSignals.supply_drop_landed.connect(_on_crate_landed)
	MatchSignals.supply_drop_collected.connect(func(crate, _p, _k): _runners.erase(crate))
	var timer = Timer.new()
	timer.wait_time = RETRY_S
	timer.autostart = true
	timer.timeout.connect(_on_timer)
	add_child(timer)


func committed_units():
	_runners = _runners.keys().reduce(
		func(kept, crate):
			var unit = _runners[crate]
			if is_instance_valid(crate) and is_instance_valid(unit) and unit.is_inside_tree():
				kept[crate] = unit
			return kept,
		{}
	)
	return _runners.values()


func runner_for(crate):
	return _runners.get(crate)


func _on_crate_landed(crate):
	var system = SupplyDrops.of(get_tree())
	if system == null:
		return
	var reach = float(system.config.get("ai_reaction_radius_m", 40.0))
	var busy = {}
	for name in ["OffenseController", "RaidingController", "OutpostController"]:
		var controller = _ai.get_node_or_null(name)
		if controller != null and controller.has_method("committed_units"):
			for unit in controller.committed_units():
				busy[unit] = true
	for unit in committed_units():
		busy[unit] = true
	var best = null
	var best_distance = reach
	for unit in get_tree().get_nodes_in_group("units"):
		if (
			unit.player != _player
			or unit in busy
			or unit is Worker
			or unit.attack_range == null
			or not SupplyDrops.can_take(unit)
		):
			continue
		var distance = unit.global_position.distance_to(crate.global_position)
		if distance < best_distance:
			best_distance = distance
			best = unit
	if best == null:
		return
	_runners[crate] = best
	_send(best, crate)


func _send(unit, crate):
	var move = Moving.new(crate.global_position)
	move.exact = true  # onto the crate itself, not a free spot next to it
	unit.action = move


func _on_timer():
	"""sends a runner that stopped short (blocked, or its order was replaced) on again"""
	for crate in _runners:
		var unit = _runners[crate]
		if (
			is_instance_valid(crate)
			and is_instance_valid(unit)
			and not unit.action is Moving
			and unit.global_position_yless.distance_to(crate.global_position) > 1.0
		):
			_send(unit, crate)
