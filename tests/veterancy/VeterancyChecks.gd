extends Node

# Earns every veterancy rank in a running match and saves screenshots (see Veterancy.gd):
# kill credit and experience, the three promotions and what they add, self-repair from
# Elite on, no credit for friendly fire, structures that never rank, and the chevrons.
# Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . \
#     res://tests/veterancy/VeterancyChecks.tscn -- --out=/tmp/veterancy
# Prints PASS/FAIL lines and exits with code 1 if anything failed.

const Human = preload("res://source/match/players/human/Human.gd")
const Veterancy = preload("res://source/match/veterancy/Veterancy.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const TankScene = preload("res://source/match/units/Tank.tscn")
const GameData = preload("res://source/data-model/GameData.gd")

var _failures = 0
var _out = "user://veterancy"
var _match = null
var _veterancy = null
var _human = null
var _rival = null
var _spot = Vector3.ZERO
var _promotions = []


func _ready():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	MatchSignals.unit_promoted.connect(func(unit, rank): _promotions.append([unit, rank]))
	_check_data()
	await _start_match()
	await _check_lineup_before()
	await _check_ranks()
	await _check_self_repair()
	await _check_friendly_fire()
	_check_structures()
	await _check_lineup_after()
	print("veterancy checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_data():
	var config = GameData.veterancy()
	var ranks = config.get("ranks", [])
	_expect(ranks.size() == 3, "three ranks: Veteran, Elite, Heroic (%d)" % ranks.size())
	var ordered = true
	for i in range(1, ranks.size()):
		ordered = ordered and float(ranks[i]["xp"]) > float(ranks[i - 1]["xp"])
		ordered = ordered and float(ranks[i]["damage"]) >= float(ranks[i - 1]["damage"])
	_expect(ordered, "each rank needs more experience and hits at least as hard")


func _start_match():
	_match = load("res://tests/veterancy/VeterancyMatch.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await _frames(40)
	_veterancy = Veterancy.of(get_tree())
	_expect(_veterancy != null, "the match has veterancy")
	var players = get_tree().get_nodes_in_group("players")
	_human = players.filter(func(p): return p is Human)[0]
	_rival = players.filter(func(p): return not p is Human)[0]
	var cc = _own(_human, func(unit): return unit is CommandCenter)
	var rival_cc = _own(_rival, func(unit): return unit is CommandCenter)
	_spot = cc.global_position.lerp(rival_cc.global_position, 0.35) * Vector3(1, 0, 1)


func _spawn_tank(player, offset):
	var tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(tank, Transform3D(Basis(), _spot + offset), player)
	await _frames(3)
	return tank


func _kill(victim, killer):
	victim.take_damage(victim.hp, killer)
	await _frames(2)


func _check_lineup_before():
	var tank = await _spawn_tank(_human, Vector3(0, 0, 0))
	tank.set_meta("lineup", true)
	_camera_on(_spot, 9.0)
	await _frames(30)
	await _shot("1-before-no-ranks")
	tank.queue_free()
	await _frames(3)


func _check_ranks():
	var tank = await _spawn_tank(_human, Vector3(0, 0, 0))
	var base_damage = tank.attack_damage
	var base_hp_max = tank.hp_max
	var base_interval = tank.attack_interval
	var ranks = _veterancy.config["ranks"]
	var victim = await _spawn_tank(_rival, Vector3(3, 0, 0))
	var xp_per_tank = _veterancy.kill_xp(victim)
	_expect(xp_per_tank == 9.0, "a tank is worth its cost, 9 experience (%.1f)" % xp_per_tank)
	await _kill(victim, tank)
	_expect(
		Veterancy.xp_of(tank) == xp_per_tank and Veterancy.rank_of(tank) == 0,
		"one tank kill is not a promotion yet (xp %.1f)" % Veterancy.xp_of(tank)
	)
	victim = await _spawn_tank(_rival, Vector3(3, 0, 0))
	await _kill(victim, tank)
	_expect(Veterancy.rank_of(tank) == 1, "a second kill makes a Veteran")
	_expect(
		is_equal_approx(tank.attack_damage, base_damage * float(ranks[0]["damage"])),
		"a Veteran hits 15%% harder (%.2f)" % tank.attack_damage
	)
	_expect(
		is_equal_approx(tank.hp_max, base_hp_max * float(ranks[0]["hp"])),
		"a Veteran has 10%% more hp (%.2f)" % tank.hp_max
	)
	_expect(tank.get_node_or_null("VeterancyChevrons") != null, "a Veteran wears chevrons")
	_expect(
		_promotions.size() == 1 and _promotions[0] == [tank, 1],
		"the promotion is announced (MatchSignals.unit_promoted)"
	)
	_expect(tank.get_node_or_null("PromotionPopup") != null, "the rank name pops up")
	while Veterancy.rank_of(tank) < 3:
		victim = await _spawn_tank(_rival, Vector3(3, 0, 0))
		await _kill(victim, tank)
	_expect(Veterancy.xp_of(tank) >= float(ranks[2]["xp"]), "Heroic takes 64 experience")
	_expect(
		is_equal_approx(tank.attack_damage, base_damage * float(ranks[2]["damage"])),
		"a Heroic unit hits 50%% harder (%.2f, from %.2f)" % [tank.attack_damage, base_damage]
	)
	_expect(
		is_equal_approx(tank.attack_interval, base_interval * float(ranks[2]["attack_interval"])),
		"and fires 20%% faster (every %.2f s)" % tank.attack_interval
	)
	_expect(_promotions.size() == 3, "three promotions announced (%d)" % _promotions.size())
	_camera_on(_spot, 7.0)
	await _frames(8)
	await _shot("2-heroic-promotion")
	tank.set_meta("heroic", true)


func _check_self_repair():
	var tank = _own(_human, func(unit): return unit.has_meta("heroic"))
	var cc = _own(_human, func(unit): return unit is CommandCenter)
	tank.global_position = cc.global_position + Vector3(5, 0, 5)  # away from rival fire
	tank.hp = tank.hp_max * 0.5
	tank.set_meta("last_hit_at_ms", Time.get_ticks_msec())
	var hurt = tank.hp
	await _wait_ms(1500)
	_expect(is_equal_approx(tank.hp, hurt), "no repair while it is still being shot at")
	tank.set_meta("last_hit_at_ms", Time.get_ticks_msec() - 60000)
	await _wait_ms(2500)
	_expect(
		tank.hp > hurt,
		"a Heroic unit out of the fight repairs itself (%.2f > %.2f)" % [tank.hp, hurt]
	)
	tank.hp = tank.hp_max


func _check_friendly_fire():
	var shooter = await _spawn_tank(_human, Vector3(-3, 0, 2))
	var friend = await _spawn_tank(_human, Vector3(-3, 0, 4))
	friend.set_meta("last_hit_by", shooter)
	friend.set_meta("last_hit_at_ms", Time.get_ticks_msec())
	friend.hp = 0
	await _frames(2)
	_expect(Veterancy.xp_of(shooter) == 0.0, "losing your own unit earns nothing")
	var victim = await _spawn_tank(_rival, Vector3(-3, 0, 6))
	victim.set_meta("last_hit_by", shooter)
	victim.set_meta("last_hit_at_ms", Time.get_ticks_msec() - 10000)
	victim.hp = 0
	await _frames(2)
	_expect(Veterancy.xp_of(shooter) == 0.0, "a hit long before the death earns no credit")
	shooter.queue_free()


func _check_structures():
	var cc = _own(_human, func(unit): return unit is CommandCenter)
	_expect(not _veterancy.can_rank(cc), "structures never rank")
	_expect(_veterancy.award(cc, 500) == 0, "and experience given to them is ignored")


func _check_lineup_after():
	for i in range(4):
		var tank = await _spawn_tank(_human, Vector3(-4.5 + i * 3.0, 0, -5))
		tank.rotation.y = PI * 0.75
		if i > 0:
			_veterancy.award(tank, float(_veterancy.config["ranks"][i - 1]["xp"]))
	_camera_on(_spot + Vector3(0, 0, -5), 9.0)
	await _shot("3-green-veteran-elite-heroic")
	await _frames(90)  # the popups have faded
	await _shot("4-ranks-at-rest")


func _own(player, predicate):
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == player and predicate.call(unit):
			return unit
	return null


func _camera_on(position, size):
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(size)
	camera.set_position_safely(position)


func _expect(condition, description):
	print(("PASS " if condition else "FAIL ") + description)
	if not condition:
		_failures += 1


func _wait_ms(ms):
	var start = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < ms:
		await get_tree().process_frame


func _shot(name):
	await _frames(3)
	var path = "{0}/{1}.png".format([_out, name])
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame
