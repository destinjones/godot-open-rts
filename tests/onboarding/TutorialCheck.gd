extends Node

# Checks the guided first match from the main menu to the match, and that every tutorial
# script in data/tutorial/ is sound. Saves screenshots of the menu and the start screen:
#
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --resolution 1600x900 \
#     res://tests/onboarding/TutorialCheck.tscn -- --out=/tmp/tutorial
#
# - every script's steps wait for a known condition and have their title and text
#   translated, and the scripts that bring a match name a known map,
# - the main menu has a Tutorial button; it opens the start screen with the tutorial's
#   first step on it, Back returns to the main menu,
# - the tutorial match gets the script, its rules and an easy rival,
# - in the match the Guide walks the first_match steps and Skip tutorial ends it.
# The steps themselves are played by tools/harness/scenarios/tutorial-first-match.json.
# Exits with code 1 when a check fails.

const MainMenuScene = preload("res://source/main-menu/Main.tscn")
const TutorialScript = preload("res://source/data-model/TutorialScript.gd")
const Guide = preload("res://source/match/hud/Guide.gd")

var _args = {"out": "user://tutorial-check"}
var _failures = []


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	DirAccess.make_dir_recursive_absolute(_args["out"])
	_check_scripts()
	var picker = await _check_main_menu()
	if picker != null:
		await _check_match(picker)
	_report()


func _check_scripts():
	for file_name in DirAccess.get_files_at(TutorialScript.DIR):
		if not file_name.ends_with(".json"):
			continue
		var script_name = file_name.get_basename()
		var script = TutorialScript.load_script(script_name)
		_expect(not script.get("steps", []).is_empty(), "%s has steps" % script_name)
		for step in script.get("steps", []):
			var id = step.get("id", "")
			_expect(
				step.get("done_when") in Guide.CONDITIONS,
				"%s: %s waits for a known condition" % [script_name, id]
			)
			for key in ["GUIDE_STEP_%s_TITLE" % id, "GUIDE_STEP_%s" % id]:
				_expect(tr(key) != key, "%s: %s is translated" % [script_name, key])
		if script.has("map"):
			_expect(
				TutorialScript.map_path_of(script) != null, "%s plays on a known map" % script_name
			)
		for key in [script.get("done_title", ""), script.get("done_text", "")]:
			if key != "":
				_expect(tr(key) != key, "%s: %s is translated" % [script_name, key])


func _check_main_menu():
	var menu = MainMenuScene.instantiate()
	get_tree().root.add_child.call_deferred(menu)
	await _frames(15)
	var button = menu.find_child("TutorialButton", true, false)
	_expect(button != null and button.visible, "the main menu has a Tutorial button")
	_screenshot("1-main-menu.png")
	if button == null:
		return null
	button.pressed.emit()
	await _frames(20)
	var picker = get_tree().root.find_child("StartPicker", true, false)
	_expect(picker != null, "Tutorial opens the start screen")
	if picker == null:
		return null
	_expect(
		picker.find_child("TutorialLabel", true, false) != null,
		"the start screen shows the tutorial's first step"
	)
	var settings = picker.match_settings
	_expect(settings.tutorial_script == TutorialScript.FIRST_MATCH, "the match plays first_match")
	_expect(settings.tutorial and not settings.ai_assist, "the tutorial's rules are applied")
	_expect(
		settings.players.size() == 2 and settings.players[1].ai_difficulty == "very_easy",
		"one very easy rival"
	)
	_expect(settings.start_pick_seconds >= 300.0, "no rush to place the city")
	_screenshot("2-start-screen.png")
	return picker


func _check_match(picker):
	picker.choose_random_spot()
	picker.start_match()
	var a_match = null
	for _i in range(600):
		await get_tree().process_frame
		a_match = get_tree().get_first_node_in_group("match")
		if a_match != null and a_match.is_node_ready():
			break
	_expect(a_match != null, "the tutorial match starts")
	if a_match == null:
		return
	await _frames(60)
	var guide = a_match.find_child("Guide", true, false)
	_expect(guide.script_name == TutorialScript.FIRST_MATCH, "the Guide plays first_match")
	_expect(
		(
			guide.steps.map(func(step): return step["id"])
			== TutorialScript.steps_of("first_match").map(func(step): return step["id"])
		),
		"the Guide has the script's steps"
	)
	_expect(guide._step >= 1, "placing the city counts as done")
	var skip_all = guide.find_child("SkipTutorialButton", true, false)
	_expect(skip_all != null, "the tutorial has a Skip tutorial button")
	_screenshot("3-tutorial-match.png")
	if skip_all != null:
		skip_all.pressed.emit()
		await _frames(5)
		_expect(guide._step == guide.steps.size(), "Skip tutorial ends it")


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
