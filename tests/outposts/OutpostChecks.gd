extends Node

# Plays the outposts through in a running match and saves screenshots (see Outposts.gd):
# placement, a capture, a contest, income, vision, a rival taking one back through neutral,
# and the AI sending a squad to take one.
# Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . \
#     res://tests/outposts/OutpostChecks.tscn -- --out=/tmp/outposts
# Prints PASS/FAIL lines and exits with code 1 if anything failed.

const Human = preload("res://source/match/players/human/Human.gd")
const Outposts = preload("res://source/match/outposts/Outposts.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const TankScene = preload("res://source/match/units/Tank.tscn")
const GameData = preload("res://source/data-model/GameData.gd")

var _failures = 0
var _out = "user://outposts"
var _match = null
var _system = null
var _human = null
var _rival = null
var _captures = []


func _ready():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	MatchSignals.outpost_captured.connect(func(o, a, b): _captures.append([o, a, b]))
	_check_data()
	await _start_match()
	_check_placement()
	if _system == null or _system.outposts.size() < 2:
		print("outpost checks: no outposts to play with")
		get_tree().quit(1)
		return
	await _check_overview()
	await _check_capture()
	await _check_contest()
	await _check_income_and_vision()
	await _check_retake()
	await _check_ai_squad()
	Engine.time_scale = 1.0
	print("outpost checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_data():
	var config = GameData.outposts()
	_expect(config.get("enabled", false), "outposts are on")
	_expect(float(config.get("capture_s", 0)) > 0, "a capture takes time")
	_expect(not config.get("income", {}).is_empty(), "an outpost pays income")


func _start_match():
	_match = load("res://tests/outposts/OutpostMatch.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await _frames(40)
	_system = Outposts.of(get_tree())
	var players = get_tree().get_nodes_in_group("players")
	_human = players.filter(func(p): return p is Human)[0]
	_rival = players.filter(func(p): return not p is Human)[0]


func _check_placement():
	_expect(_system != null, "the match has an outpost system")
	var zones = _match.map.get_start_zones()
	var outposts = _system.outposts
	_expect(
		outposts.size() == zones.size() + 1,
		"one outpost in the centre and one between each pair of starts (%d)" % outposts.size()
	)
	var clear = true
	for outpost in outposts:
		var flat = Vector2(outpost.global_position.x, outpost.global_position.z)
		for zone in zones:
			clear = clear and flat.distance_to(zone["center"]) >= zone["radius"] + 9.0
		clear = clear and _match.map.water_depth_at(outpost.global_position) == 0
	_expect(clear, "every outpost is on dry ground, clear of the start zones")
	var centre = Vector3(_match.map.size.x, 0, _match.map.size.y) / 2.0
	var nearest = INF
	for outpost in outposts:
		nearest = min(nearest, outpost.global_position.distance_to(centre))
	_expect(nearest <= 12.0, "one of them is near the centre (%.1f m off)" % nearest)
	_expect(
		outposts.all(func(outpost): return outpost.owner_player == null), "they all start neutral"
	)


func _check_overview():
	var centre = Vector3(_match.map.size.x, 0, _match.map.size.y) / 2.0
	_camera_on(centre, 34.0)
	await _frames(20)
	await _shot("1-outposts-on-the-map")
	_camera_on(_system.outposts[0].global_position, 9.0)
	await _frames(10)
	await _shot("2-neutral-outpost")


func _spawn_tank(player, at):
	var tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(tank, Transform3D(Basis(), at), player)
	await _frames(3)
	return tank


func _check_capture():
	var outpost = _system.outposts[0]
	_system.config["capture_s"] = 6.0
	var tanks = []
	for offset in [Vector3(1, 0, 1), Vector3(-1, 0, 1)]:
		tanks.append(await _spawn_tank(_human, outpost.global_position + offset))
	_expect(_system.holders(outpost).get(_human, 0) == 2, "two tanks stand in the ring")
	await _wait_for(func(): return outpost.progress > 0.45, 2000)
	_expect(
		outpost.capturer == _human and outpost.owner_player == null,
		"the player is capturing it (%.0f%%)" % (outpost.progress * 100.0)
	)
	await _shot("3-capturing-flag-half-up")
	var captured = await _wait_for(func(): return outpost.owner_player == _human, 2000)
	_expect(captured, "two tanks capture it")
	_expect(
		_captures.size() == 1 and _captures[0] == [outpost, null, _human],
		"the capture is announced (MatchSignals.outpost_captured)"
	)
	await _frames(10)
	await _shot("4-captured-blue")
	for tank in tanks:
		tank.set_meta("outpost_holder", true)


func _check_contest():
	var outpost = _system.outposts[1]
	var capture_s = float(_system.config["capture_s"])
	_system.step(outpost, {_human: 1}, capture_s * 0.4)
	var held = outpost.progress
	_system.step(outpost, {_human: 1, _rival: 1}, capture_s * 0.4)
	_expect(outpost.contested, "an enemy in the ring contests it")
	_expect(
		is_equal_approx(outpost.progress, held) and outpost.owner_player == null,
		"a contested capture does not move (%.2f, %.2f)" % [held, outpost.progress]
	)
	_system.step(outpost, {}, capture_s * 0.2)
	_expect(
		outpost.progress < held and not outpost.contested,
		"an abandoned capture falls back (%.2f)" % outpost.progress
	)
	_system.step(outpost, {_human: 3}, capture_s * 0.1)
	_expect(
		outpost.progress > held - 0.1 + 0.1 * 1.9,
		"three units capture faster than one (%.2f)" % outpost.progress
	)
	# the same standoff with real tanks, for the screenshot
	var mine = await _spawn_tank(_human, outpost.global_position + Vector3(1.5, 0, 0))
	var theirs = await _spawn_tank(_rival, outpost.global_position + Vector3(-1.5, 0, 0))
	_camera_on(outpost.global_position, 9.0)
	await _wait_for(func(): return outpost.contested, 200)
	await _shot("5-contested")
	theirs.queue_free()
	mine.queue_free()
	_system.step(outpost, {}, capture_s * 10.0)
	await _frames(5)


func _check_income_and_vision():
	var outpost = _system.outposts[0]
	_expect(outpost.is_in_group("revealed_units"), "the player's outpost reveals the fog")
	var income = _system.income_of(_human)
	var before = _human.get_stock()
	_system.call("_pay_income")
	var after = _human.get_stock()
	var paid = true
	for resource in income:
		paid = paid and after[resource] - before[resource] == income[resource]
	_expect(paid and not income.is_empty(), "an outpost pays %s" % str(income))


func _check_retake():
	var outpost = _system.outposts[0]
	for tank in get_tree().get_nodes_in_group("units"):
		if tank.has_meta("outpost_holder"):
			tank.queue_free()
	await _frames(5)
	_captures.clear()
	# stepped by hand: the rival AI would drive a tank of its own back home
	var capture_s = float(_system.config["capture_s"])
	_system.step(outpost, {_rival: 1}, capture_s * 0.5)
	_expect(
		outpost.owner_player == _human and outpost.capturer == _rival,
		"a rival pulls the player's flag down (%.2f)" % outpost.progress
	)
	_system.step(outpost, {_rival: 1}, capture_s * 0.6)
	_expect(outpost.owner_player == null, "to neutral first")
	_system.step(outpost, {_rival: 1}, capture_s * 1.1)
	_expect(outpost.owner_player == _rival, "and then raises their own")
	_expect(
		_captures.size() == 2 and _captures[0][2] == null and _captures[1][2] == _rival,
		"both steps are announced"
	)
	_system.call("_tick", 0.0)
	var shown = _rival in _match.visible_players  # full visibility shows every player
	_expect(
		outpost.is_in_group("revealed_units") == shown,
		"a rival's outpost reveals the fog only if the rival is shown (%s)" % str(shown)
	)
	_camera_on(outpost.global_position, 9.0)
	await _frames(5)
	await _shot("6-rival-took-it")


func _check_ai_squad():
	var controller = _rival.get_node_or_null("OutpostController")
	_expect(controller != null, "the AI has an outpost controller")
	_system.config["ai_first_outpost_after_s"] = 0.0
	_rival.add_resources({"timber": 300, "iron": 300, "copper": 300, "oil": 300})
	Engine.time_scale = 4.0
	var sent = await _wait_for(
		func(): return controller.committed_units().size() > 0 and controller.target() != null, 2500
	)
	_expect(sent, "the AI builds a squad and sends it to an outpost")
	var target = controller.target()
	var arrived = (
		sent
		and await _wait_for(
			func():
				return controller.committed_units().any(
					func(unit):
						return unit.global_position.distance_to(target.global_position) < 6.0
				),
			2500
		)
	)
	_expect(arrived, "the squad reaches it")
	Engine.time_scale = 1.0
	if arrived:
		_camera_on(target.global_position, 10.0)
		await _frames(10)
		await _shot("7-ai-squad-at-outpost")


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
