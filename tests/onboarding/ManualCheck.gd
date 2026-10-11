extends Node

# Checks the F1 manual's search and the hints that link into it, and saves screenshots:
#
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --resolution 1600x900 \
#     res://tests/onboarding/ManualCheck.tscn -- --out=/tmp/manual
#
# - every topic is translated and every hint's topic exists,
# - a search keeps the topics that mention every word, title matches first, and marks the
#   words; no match says so; an empty search brings all topics back,
# - opening a topic the search hides clears the search,
# - Ctrl+F puts the cursor in the search box, Esc there closes the manual,
# - a hint with a topic shows "Read more", which opens the manual on that topic; an alert
#   (no topic) does not.
# Exits with code 1 when a check fails.

const HelpWindow = preload("res://source/match/hud/HelpWindow.gd")
const Guide = preload("res://source/match/hud/Guide.gd")

var _args = {"out": "user://manual-check"}
var _failures = []


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	DirAccess.make_dir_recursive_absolute(_args["out"])
	_check_texts()
	var a_match = load("res://tests/manual/TestOneCityOneRival.tscn").instantiate()
	add_child(a_match)
	await _frames(30)
	var guide = a_match.find_child("Guide", true, false)
	await _check_search(guide.help_window, guide)
	await _check_keys(guide.help_window, guide)
	await _check_hint_link(guide)
	_report()


func _check_texts():
	for topic in HelpWindow.TOPICS:
		for key in ["HELP_%s_TITLE" % topic, "HELP_%s_BODY" % topic]:
			_expect(tr(key) != key, key + " is translated")
	for key in ["HELP_SEARCH", "HELP_SEARCH_TOOLTIP", "HELP_SEARCH_NONE", "HINT_MORE"]:
		_expect(tr(key) != key, key + " is translated")
	for hint in Guide.HINT_TOPICS:
		_expect(tr(hint) != hint, hint + " is translated")
		_expect(
			Guide.HINT_TOPICS[hint] in HelpWindow.TOPICS,
			"%s links to a manual topic (%s)" % [hint, Guide.HINT_TOPICS[hint]]
		)


func _check_search(manual, guide):
	guide.toggle_help("BASICS", true)
	await _frames(5)
	manual.search_box.text = "power"
	manual.search("power")
	await _frames(5)
	var shown = manual.shown_topics()
	_expect(
		shown.size() > 0 and shown[0] == "POWER", "power: the Power topic comes first " + str(shown)
	)
	_expect(shown.size() < HelpWindow.TOPICS.size(), "power: other topics are left out")
	var body = manual.get("_body").text
	_expect("[bgcolor=" in body, "the words found are marked")
	_screenshot("1-search-power.png")
	manual.search("haul escort")
	_expect(
		manual.shown_topics().all(
			func(topic): return "haul" in _plain(topic) and "escort" in _plain(topic)
		),
		"every word must be in the topic: " + str(manual.shown_topics())
	)
	manual.search_box.text = "zeppelin"
	manual.search("zeppelin")
	await _frames(5)
	_expect(manual.shown_topics().is_empty(), "zeppelin: no topic")
	_expect("zeppelin" in manual.get("_body").text, "no match says what was searched")
	_screenshot("2-search-nothing.png")
	manual.show_topic("TRADE")
	_expect(manual.search_box.text == "", "opening a hidden topic clears the search")
	_expect(manual.shown_topics() == HelpWindow.TOPICS, "and brings every topic back")
	_expect(tr("HELP_TRADE_TITLE") in manual.get("_body").text, "and shows Trade")
	manual.search("")
	_expect(manual.shown_topics() == HelpWindow.TOPICS, "an empty search shows all topics")


func _check_keys(manual, guide):
	guide.toggle_help(null, true)
	await _frames(3)
	await _key(KEY_F, true)
	_expect(manual.search_box.has_focus(), "Ctrl+F puts the cursor in the search box")
	await _key(KEY_ESCAPE)
	_expect(not manual.visible, "Esc in the search box closes the manual")


func _check_hint_link(guide):
	guide.show_hint("HINT_BLACKOUT")
	await _frames(10)
	var more = guide.find_child("HintMore", true, false)
	_expect(more != null and more.is_visible_in_tree(), "a hint shows Read more")
	_screenshot("3-hint-read-more.png")
	if more == null:
		return
	more.pressed.emit()
	await _frames(5)
	var manual = guide.help_window
	var selected = manual.get("_topics").get_selected_items()
	_expect(
		(
			manual.visible
			and not selected.is_empty()
			and manual.shown_topics()[selected[0]] == "POWER"
		),
		"Read more opens the manual on Power"
	)
	_screenshot("4-hint-opens-power.png")
	manual.hide()
	guide.set("_hint_time_left_s", 0.0)
	guide.show_alert("a test alert")
	await _frames(5)
	_expect(not more.visible, "an alert has no Read more")


func _plain(topic):
	return (tr("HELP_%s_TITLE" % topic) + " " + tr("HELP_%s_BODY" % topic)).to_lower()


func _key(keycode, ctrl = false):
	for state in [true, false]:
		var event = InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.ctrl_pressed = ctrl
		event.pressed = state
		Input.parse_input_event(event)
		await _frames(2)


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
