extends Node

# Checks that the HUD explains itself on hover: every build-menu and production item gets
# a rich tooltip made from the building-card data (no untranslated keys, the cost with what
# is short, why it is locked), the resources, power, units and city stats have tooltips,
# and no visible HUD button is left without one. Saves screenshots of two hover cards:
#
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --resolution 1600x900 \
#     res://tests/onboarding/TooltipsCheck.tscn -- --out=/tmp/tooltips
#
# Exits with code 1 when a check fails.

const GameData = preload("res://source/data-model/GameData.gd")
const Human = preload("res://source/match/players/human/Human.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const Tooltips = preload("res://source/match/hud/Tooltips.gd")
const RichTooltipButton = preload("res://source/match/hud/RichTooltipButton.gd")

var _args = {"out": "user://tooltips-check"}
var _failures = []
var _raw_key = RegEx.create_from_string("\\b[A-Z][A-Z0-9]+_[A-Z0-9_]+\\b")


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	DirAccess.make_dir_recursive_absolute(_args["out"])
	var a_match = load("res://tests/manual/TestOneCityOneRival.tscn").instantiate()
	add_child(a_match)
	await _frames(40)
	var human = get_tree().get_nodes_in_group("players").filter(func(p): return p is Human)[0]
	_check_every_entry(human)
	var hud = a_match.get_node("HUD")
	_check_bars(hud)
	await _select(human, func(unit): return unit is Worker)
	await _check_menu(hud, human, "1-build-menu-tooltip.png", "vehicle_factory")
	await _select(human, func(unit): return unit.scene_file_path.ends_with("CommandCenter.tscn"))
	await _check_menu(hud, human, "2-production-tooltip.png", "worker")
	_report()


func _check_every_entry(human):
	for entry in GameData.units():
		var text = Tooltips.build_item(entry, human, KEY_T)
		var raw = _raw_key.search(_plain(text))
		_expect(raw == null, "%s: tooltip fully translated%s" % [entry["id"], _found(raw)])
	var factory = GameData.unit_by_id("vehicle_factory")
	var kept = human.iron
	human.iron = 0
	_expect(
		_plain(Tooltips.build_item(factory, human)).contains(tr("TIP_YOU_HAVE").format([0])),
		"a cost the player cannot pay says what they have"
	)
	human.iron = kept
	var tier_three = GameData.units().filter(func(entry): return int(entry.get("tier", 1)) >= 3)
	if not tier_three.is_empty():
		_expect(
			_plain(Tooltips.build_item(tier_three[0], human)).contains(
				tr("TIP_LOCKED").format([""]).strip_edges()
			),
			"a locked item says why: " + tier_three[0]["id"]
		)


func _check_bars(hud):
	var bar = hud.find_child("ResourcesBar", true, false)
	for resource in Constants.Match.Resources.ALL:
		var item = bar.find_child("Resource_" + resource, true, false)
		_expect(item != null and item.tooltip_text != "", "the %s counter has a tooltip" % resource)
	var stats = hud.find_child("Stats", true, false)
	if stats != null:
		for cell in stats.get_children():
			_expect(cell.tooltip_text != "", "city stat %s has a tooltip" % cell.get_index())


func _check_menu(hud, human, shot, wanted_id):
	var buttons = hud.find_children("*", "Button", true, false).filter(
		func(button): return button.get_script() == RichTooltipButton and button.is_visible_in_tree()
	)
	_expect(not buttons.is_empty(), "the menu has hover cards (%s)" % shot)
	var shown = null
	for button in buttons:
		var text = button.tip_maker.call()
		var raw = _raw_key.search(_plain(text))
		_expect(raw == null and button.tooltip_text != "", "a menu card is complete" + _found(raw))
		if _plain(text).contains(tr(GameData.unit_by_id(wanted_id)["name"])):
			shown = button
	var bare = hud.find_children("*", "Button", true, false).filter(
		func(button): return button.is_visible_in_tree() and button.tooltip_text.strip_edges() == ""
	)
	_expect(
		bare.is_empty(),
		"every visible HUD button has a tooltip" + _names(bare.map(func(b): return b.name))
	)
	if shown != null:
		var card = shown._make_custom_tooltip(shown.tooltip_text)
		hud.add_child(card)
		await _frames(3)
		card.position = shown.global_position - Vector2(card.size.x - shown.size.x, card.size.y + 8)
		await _frames(3)
		_screenshot(shot)
		card.queue_free()


func _select(human, filter):
	MatchSignals.deselect_all_units.emit()
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == human and filter.call(unit):
			unit.find_child("Selection").select()
			break
	await _frames(20)


static func _plain(bbcode):
	return RegEx.create_from_string("\\[[^\\]]*\\]").sub(bbcode, "", true)


static func _found(raw):
	return "" if raw == null else " (found %s)" % raw.get_string()


static func _names(names):
	return "" if names.is_empty() else " (missing: %s)" % ", ".join(names)


func _expect(condition, what):
	if not condition:
		_failures.append(what)
		print("FAIL " + what)
	elif not what in _failures:
		print("PASS " + what)


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
