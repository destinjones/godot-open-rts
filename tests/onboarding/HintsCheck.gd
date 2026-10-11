extends Node

# Checks the first-time hints: each fires once, is remembered in the options so it never
# comes back, can be turned off and brought back in Options, and the new event hints (an
# idle truck, a dry deposit) fire. Saves screenshots of a hint and the Options rows:
#
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --resolution 1600x900 \
#     res://tests/onboarding/HintsCheck.tscn -- --out=/tmp/hints
#
# The player's own seen hints and tips setting are put back when the check ends.
# Exits with code 1 when a check fails.

const Human = preload("res://source/match/players/human/Human.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const MineScene = preload("res://source/match/units/Mine.tscn")
const OptionsScene = preload("res://source/main-menu/Options.tscn")

var _args = {"out": "user://hints-check"}
var _failures = []
var _shown = []  # keys from MatchSignals.hint_shown


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	DirAccess.make_dir_recursive_absolute(_args["out"])
	var kept_seen = Globals.options.seen_hints
	var kept_show = Globals.options.show_tips
	Globals.options.seen_hints = PackedStringArray()
	Globals.options.show_tips = true
	FeatureFlags.remember_first_run = true
	MatchSignals.hint_shown.connect(func(key): _shown.append(key))
	var a_match = load("res://tests/manual/TestOneCityOneRival.tscn").instantiate()
	add_child(a_match)
	await _frames(30)
	var guide = a_match.find_child("Guide", true, false)
	await _check_once_and_forever(guide)
	await _check_idle_truck(guide)
	await _check_dry_deposit(guide)
	a_match.queue_free()
	await _frames(5)
	await _check_options_menu()
	FeatureFlags.remember_first_run = false
	Globals.options.seen_hints = kept_seen
	Globals.options.show_tips = kept_show
	Globals.options.save()
	_report()


func _check_once_and_forever(guide):
	guide.show_hint("HINT_BLACKOUT")
	await _frames(10)
	_expect(guide.find_child("Hint", true, false).visible, "a first-time hint shows")
	_expect("HINT_BLACKOUT" in Globals.options.seen_hints, "it is remembered in the options")
	_expect("HINT_BLACKOUT" in _shown, "hint_shown tells the audio hook which hint")
	_screenshot("1-first-time-hint.png")
	guide.set("_hints_shown", {})  # as in the next match
	guide.call("_update_hint", 99.0)  # the OK button
	guide.show_hint("HINT_BLACKOUT")
	await _frames(5)
	_expect(not guide.find_child("Hint", true, false).visible, "a seen hint never comes back")
	Globals.options.show_tips = false
	guide.show_hint("HINT_CARGO_DESTROYED")
	await _frames(5)
	_expect(
		not "HINT_CARGO_DESTROYED" in Globals.options.seen_hints,
		"with tips off in Options nothing shows or is used up"
	)
	Globals.options.show_tips = true


func _check_idle_truck(guide):
	var player = guide.player
	var haulers = player.logistics.get_haulers()
	_expect(not haulers.is_empty(), "the player has trucks")
	var long_ago = guide.get("_game_time_s") - guide.TRUCK_IDLE_HINT_S - 1.0
	for hauler in haulers:
		guide.get("_idle_since_s")[hauler.get_instance_id()] = long_ago
	guide.call("_check_logistics")
	_expect(
		"HINT_TRUCK_IDLE" in guide.get("_hints_shown"),
		"a truck with nothing to carry for a minute gets a hint"
	)
	await _frames(2)


func _check_dry_deposit(guide):
	var player = guide.player
	var base = player.logistics.get_depots()[0].global_position
	var deposits = get_tree().get_nodes_in_group("deposits").filter(
		func(deposit): return deposit.kind == "iron"
	)
	deposits.sort_custom(
		func(a, b): return a.global_position.distance_to(base) < b.global_position.distance_to(base)
	)
	var deposit = deposits[0]
	var mine = MineScene.instantiate()
	mine.set_meta("spawn_constructed", true)
	var spot = deposit.global_position_yless + Vector3(deposit.radius + 1.4, 0, 0)
	MatchSignals.setup_and_spawn_unit.emit(mine, Transform3D(Basis(), spot), player)
	await _frames(10)
	deposit.extract(deposit.amount)  # dig it out at once
	for _i in range(20):
		await _frames(10)
		guide.call("_check_logistics")
		if "HINT_DEPOSIT_DRY" in guide.get("_hints_shown"):
			break
	_expect(mine.is_depleted(), "the mine's deposit ran dry")
	_expect("HINT_DEPOSIT_DRY" in guide.get("_hints_shown"), "a dry deposit gets a hint")


func _check_options_menu():
	var menu = OptionsScene.instantiate()
	add_child(menu)
	await _frames(10)
	var tabs = menu.find_child("Tabs", true, false)
	tabs.current_tab = tabs.get_tab_idx_from_control(tabs.find_child("Interface", false, false))
	await _frames(5)
	var check = menu.find_child("ShowTips", true, false)
	var reset = menu.find_child("ResetTipsButton", true, false)
	_expect(check != null and check.button_pressed, "Options shows the tips switch, on")
	_expect(reset != null and not reset.disabled, "Show all tips again is offered")
	_screenshot("2-options-tips.png")
	if reset != null:
		reset.pressed.emit()
		_expect(Globals.options.seen_hints.is_empty(), "Show all tips again forgets the seen ones")
	menu.queue_free()


func _expect(condition, what):
	print(("PASS " if condition else "FAIL ") + what)
	if not condition:
		_failures.append(what)


func _report():
	print("%d check(s) failed" % _failures.size() if _failures else "all checks passed")
	get_tree().quit(1 if _failures else 0)


func _screenshot(file_name):
	var path = _args["out"].path_join(file_name)
	get_viewport().get_texture().get_image().save_png(path)
	print("screenshot ", ProjectSettings.globalize_path(path))


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame
