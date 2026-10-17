extends Node

# Drops supply crates in a running match and saves screenshots (see SupplyDrops.gd): the
# fall and landing, a pickup of each kind, expiry, and the AI sending a unit for one.
# Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . \
#     res://tests/supply-drops/SupplyDropChecks.tscn -- --out=/tmp/supply-drops
# Prints PASS/FAIL lines and exits with code 1 if anything failed.

const Human = preload("res://source/match/players/human/Human.gd")
const SupplyDrops = preload("res://source/match/supply-drops/SupplyDrops.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const TankScene = preload("res://source/match/units/Tank.tscn")
const GameData = preload("res://source/data-model/GameData.gd")

var _failures = 0
var _out = "user://supply-drops"
var _match = null
var _system = null
var _human = null
var _rival = null
var _landed = []
var _collected = []


func _ready():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	MatchSignals.supply_drop_landed.connect(func(crate): _landed.append(crate))
	MatchSignals.supply_drop_collected.connect(func(c, p, k): _collected.append([c, p, k]))
	_check_data()
	await _start_match()
	await _check_fall_and_land()
	await _check_goods()
	await _check_repair()
	await _check_veterans_fallback()
	await _check_expiry()
	await _check_ai_runner()
	print("supply drop checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_data():
	var config = GameData.supply_drops()
	var ids = config.get("contents", []).map(func(entry): return entry.get("id"))
	_expect(
		"goods" in ids and "repair" in ids and "veterans" in ids,
		"crates hold goods, repairs or training (%s)" % str(ids)
	)
	_expect(float(config.get("first_drop_after_s", 0)) > 0, "the first crate comes after a while")


func _start_match():
	_match = load("res://tests/supply-drops/SupplyDropMatch.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await _frames(40)
	_system = SupplyDrops.of(get_tree())
	_expect(_system != null, "the match has supply drops")
	var players = get_tree().get_nodes_in_group("players")
	_human = players.filter(func(p): return p is Human)[0]
	_rival = players.filter(func(p): return not p is Human)[0]
	_system.config["fall_s"] = 1.5
	_system.config["first_drop_after_s"] = 9999.0
	_system.set("_until_next_s", 9999.0)
	# the AI would send runners for the test's own crates; _check_ai_runner turns it back on
	_system.config["ai_reaction_radius_m"] = 0.0


func _check_fall_and_land():
	var spots = []
	for _i in range(20):
		var spot = _system.random_spot()
		if spot != null:
			spots.append(spot)
	_expect(spots.size() == 20, "random spots are found (%d of 20)" % spots.size())
	var dry = spots.all(func(spot): return _match.map.water_depth_at(spot) == 0)
	_expect(dry, "and all of them are on dry ground")
	var crate = _system.drop(null, _system.call("_content_by_id", "goods"))
	_expect(crate != null and not crate.has_landed, "a crate starts falling")
	# frame it half way down, so that the crate and its parachute are both in the shot
	await _wait_for(func(): return crate.get_node("Body").position.y < 8.0, 600)
	_camera_on(crate.global_position + Vector3(0, 6.0, 2), 12.0)
	await _frames(1)
	await _shot("1-crate-falling")
	_camera_on(crate.global_position + Vector3(0, 0, 3), 12.0)
	var landed = await _wait_for(func(): return crate.has_landed, 2000)
	_expect(landed and crate in _landed, "it lands and the landing is announced")
	await _frames(10)
	await _shot("2-crate-landed-beacon")
	if is_instance_valid(crate):
		crate.set_meta("first", true)


func _spawn_tank(player, at):
	var tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(tank, Transform3D(Basis(), at), player)
	await _frames(3)
	return tank


func _check_goods():
	var firsts = _system.crates.filter(func(c): return c.has_meta("first"))
	var crate = firsts[0] if not firsts.is_empty() else null
	_expect(crate != null, "the landed crate waits for a taker")
	if crate == null:
		return
	var goods = crate.content.get("resources", {})
	var before = _human.get_stock()
	var tank = await _spawn_tank(_human, crate.global_position + Vector3(0.6, 0, 0))
	var taken = await _wait_for(func(): return not is_instance_valid(crate), 600)
	_expect(taken, "a unit next to the crate picks it up")
	var after = _human.get_stock()
	var paid = true
	for resource in goods:
		paid = paid and after[resource] - before[resource] == goods[resource]
	_expect(paid, "a goods crate adds %s to the stock" % str(goods))
	_expect(
		goods.keys().all(func(resource): return typeof(after[resource]) == TYPE_INT),
		"and the stock stays in whole numbers (%s)" % str(after)
	)
	_expect(
		_collected.size() == 1 and _collected[0][1] == _human and _collected[0][2] == "goods",
		"the pickup is announced"
	)
	await _frames(2)
	await _shot("3-goods-picked-up")
	tank.queue_free()


func _check_repair():
	var spot = _system.random_spot()
	var hurt = []
	for offset in [Vector3(3, 0, 0), Vector3(-3, 0, 2)]:
		var tank = await _spawn_tank(_human, spot + offset)
		tank.hp = tank.hp_max * 0.3
		hurt.append(tank)
	var crate = _system.drop(spot, _system.call("_content_by_id", "repair"))
	await _wait_for(func(): return crate.has_landed, 2000)
	_system.collect(crate, hurt[0])
	_expect(
		hurt.all(func(tank): return tank.hp == tank.hp_max),
		"a repair crate patches up the units around it"
	)
	for tank in hurt:
		tank.queue_free()


func _check_veterans_fallback():
	var spot = _system.random_spot()
	var tank = await _spawn_tank(_human, spot + Vector3(2, 0, 0))
	var crate = _system.drop(spot, _system.call("_content_by_id", "veterans"))
	await _wait_for(func(): return crate.has_landed, 2000)
	var before = _human.get_stock()
	_system.collect(crate, tank)
	var veterancy = get_tree().get_first_node_in_group("veterancy")
	if veterancy == null:
		_expect(
			_human.get_stock() != before and _collected.back()[2] == "goods",
			"without veterancy a training crate holds goods instead"
		)
	else:
		_expect(
			float(tank.get_meta("veterancy_xp", 0.0)) > 0.0,
			"a training crate gives the units around it experience"
		)
	tank.queue_free()


func _check_expiry():
	_system.config["expires_after_s"] = 1.0
	var crate = _system.drop()
	var gone = await _wait_for(func(): return not is_instance_valid(crate), 2000)
	_expect(gone and not crate in _system.crates, "a crate nobody takes is gone after a while")
	_system.config["expires_after_s"] = 150.0


func _check_ai_runner():
	var controller = _rival.get_node_or_null("SupplyDropController")
	_expect(controller != null, "the AI has a supply drop controller")
	_system.config["ai_reaction_radius_m"] = 40.0
	var rival_cc = null
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == _rival and unit is CommandCenter:
			rival_cc = unit
	var runner = await _spawn_tank(_rival, rival_cc.global_position + Vector3(6, 0, 6))
	var crate = _system.drop(rival_cc.global_position + Vector3(14, 0, 10))
	await _wait_for(func(): return crate.has_landed, 2000)
	await _frames(2)
	_expect(controller.runner_for(crate) != null, "the AI sends a unit for a crate near it")
	_expect(
		controller.runner_for(crate) in controller.committed_units(),
		"and keeps it out of the army's hands meanwhile"
	)
	_system.config["expires_after_s"] = 9999.0  # a slow renderer must not time it out
	var unit = controller.runner_for(crate)
	var taken = await _wait_for(func(): return not is_instance_valid(crate), 2400)
	if not taken:
		print(
			(
				"runner at %s, crate at %s, action %s"
				% [
					unit.global_position if is_instance_valid(unit) else "gone",
					crate.global_position,
					str(unit.action) if is_instance_valid(unit) else "-"
				]
			)
		)
	_expect(taken and _collected.back()[1] == _rival, "the AI's unit picks it up (%s)" % str(taken))
	runner.queue_free()


func _camera_on(position, size):
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(size)
	camera.set_position_safely(position)


func _expect(condition, description):
	print(("PASS " if condition else "FAIL ") + description)
	if not condition:
		_failures += 1


func _wait_for(predicate, max_frames):
	for _i in range(max_frames):
		if predicate.call():
			return true
		await get_tree().process_frame
	return predicate.call()


func _shot(name):
	await _frames(3)
	var path = "{0}/{1}.png".format([_out, name])
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame
