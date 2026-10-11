extends Node

# Checks what a new player meets on the first launch, and saves screenshots:
#
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --resolution 1600x900 \
#     res://tests/onboarding/FirstRunCheck.tscn -- --out=/tmp/first-run
#
# - the main menu opens with the "what is this game" card, translated, and it only shows
#   in a real game (FeatureFlags.remember_first_run); "Go to the menu" closes it for good,
#   "Play the tutorial" closes it and opens the guided first match,
# - the Play menu starts a new player on the starter map against an easy AI, and after a
#   match it opens on the last map and AI difficulty instead.
# Leaves the player's options as they were. Exits with code 1 when a check fails.

const MainMenuScene = preload("res://source/main-menu/Main.tscn")
const PlayScene = preload("res://source/main-menu/Play.tscn")
const IntroCard = preload("res://source/main-menu/IntroCard.gd")
const Play = preload("res://source/main-menu/Play.gd")
const KEPT = ["intro_seen", "last_map", "last_ai_difficulty"]

var _args = {"out": "user://first-run-check"}
var _failures = []


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	DirAccess.make_dir_recursive_absolute(_args["out"])
	var kept = {}
	for property in KEPT:
		kept[property] = Globals.options.get(property)
	var defaults = Globals.options.get_script().new()
	for property in KEPT:
		Globals.options.set(property, defaults.get(property))
	_expect(not IntroCard.should_show(), "no intro card in tests and the play harness")
	FeatureFlags.remember_first_run = true
	await _check_intro_skip()
	await _check_intro_tutorial()
	await _check_play_defaults()
	FeatureFlags.remember_first_run = false
	for property in KEPT:
		Globals.options.set(property, kept[property])
	Globals.options.save()
	_report()


func _check_intro_skip():
	var menu = await _open(MainMenuScene)
	var card = menu.find_child("IntroCard", true, false)
	_expect(card != null, "the first launch shows the intro card")
	if card == null:
		return
	for label in card.find_children("*", "Label", true, false):
		_expect(not label.text.begins_with("INTRO_"), "intro text is translated: " + label.text)
	_screenshot("1-intro-card.png")
	card.find_child("IntroSkipButton", true, false).pressed.emit()
	await _frames(5)
	_expect(menu.find_child("IntroCard", true, false) == null, "Go to the menu closes the card")
	_expect(Globals.options.intro_seen, "the card is marked as seen")
	_screenshot("2-main-menu-after-intro.png")
	menu.queue_free()
	await _frames(5)
	menu = await _open(MainMenuScene)
	_expect(menu.find_child("IntroCard", true, false) == null, "the card never comes back")
	menu.queue_free()
	await _frames(5)


func _check_intro_tutorial():
	Globals.options.intro_seen = false
	var menu = await _open(MainMenuScene)
	var card = menu.find_child("IntroCard", true, false)
	_expect(card != null, "the card shows again once intro_seen is cleared")
	if card == null:
		return
	card.find_child("IntroTutorialButton", true, false).pressed.emit()
	await _frames(20)
	var picker = get_tree().root.find_child("StartPicker", true, false)
	_expect(picker != null, "Play the tutorial opens the guided first match")
	_expect(
		picker != null and picker.match_settings.tutorial_script == "first_match",
		"it is the first_match tutorial"
	)
	_expect(Globals.options.intro_seen, "choosing the tutorial marks the card as seen too")
	if picker != null:
		picker.queue_free()
	await _frames(5)


func _check_play_defaults():
	var play = await _open(PlayScene)
	_expect(_map_of(play) == Play.STARTER_MAP, "a new player starts on " + _map_of(play))
	_expect(
		_ai_difficulties(play).all(func(id): return id == Play.STARTER_AI_DIFFICULTY),
		"against an easy AI: " + str(_ai_difficulties(play))
	)
	_screenshot("3-play-menu-first-run.png")
	var map_paths = play.get("_map_paths")
	for index in range(map_paths.size()):
		if Play._map_id(map_paths[index]) == "twin_isles":
			play.find_child("MapList").select(index)
			play.find_child("MapList").item_selected.emit(index)
	play.get("_slot_options").set_difficulty(1, "hard")
	play.call("_remember_choices", play.call("_create_match_settings"))
	_expect(Globals.options.last_map == "twin_isles", "the map played is remembered")
	_expect(Globals.options.last_ai_difficulty == "hard", "the AI difficulty is remembered")
	play.queue_free()
	await _frames(5)
	play = await _open(PlayScene)
	_expect(_map_of(play) == "twin_isles", "the next visit opens on the last map")
	_expect(_ai_difficulties(play) == ["hard"], "and the last AI difficulty")
	play.queue_free()
	await _frames(5)


func _map_of(play):
	return Play._map_id(play.call("_get_selected_map_path"))


func _ai_difficulties(play):
	var settings = play.call("_create_match_settings")
	var ais = settings.players.filter(
		func(player): return player.controller == Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	)
	return ais.map(func(player): return player.ai_difficulty)


func _open(scene):
	var node = scene.instantiate()
	get_tree().root.add_child.call_deferred(node)
	await _frames(15)
	return node


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
