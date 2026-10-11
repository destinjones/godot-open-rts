extends Control

# "What is this game": a card over the main menu on the very first launch. It says in four
# lines what Ironbound is about and offers the guided first match (Main.start_tutorial) or
# the menu. Either answer sets Options.intro_seen, so it never shows again. Shown only in a
# real game (FeatureFlags.remember_first_run), never in tests or the play harness, unless
# a test adds it by hand.

signal tutorial_chosen
signal dismissed

const TITLE_FONT = preload("res://assets/ui/fonts/ironbound_title.tres")
const ACCENT = Color("f2a93b")
const INK = Color("efe4cf")
const LINES = ["INTRO_LINE_CITY", "INTRO_LINE_SUPPLY", "INTRO_LINE_ARMY", "INTRO_LINE_WIN"]


static func should_show():
	return FeatureFlags.remember_first_run and not Globals.options.intro_seen


func _ready():
	name = "IntroCard"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP  # the menu behind waits for an answer
	var shade = ColorRect.new()
	shade.color = Color(0.03, 0.025, 0.02, 0.72)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	var center = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color("1d1710")
	style.border_color = ACCENT
	style.border_width_top = 4
	style.set_corner_radius_all(10)
	style.set_content_margin_all(32)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var column = VBoxContainer.new()
	column.custom_minimum_size = Vector2(620, 0)
	column.add_theme_constant_override("separation", 14)
	panel.add_child(column)

	var title = Label.new()
	title.name = "IntroTitle"
	title.text = tr("INTRO_TITLE")
	title.add_theme_font_override("font", TITLE_FONT)
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", INK)
	column.add_child(title)
	column.add_child(_text(tr("INTRO_BODY"), 20, INK.darkened(0.1)))
	var lines = VBoxContainer.new()
	lines.name = "IntroLines"
	lines.add_theme_constant_override("separation", 8)
	column.add_child(lines)
	for index in range(LINES.size()):
		var row = HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var number = _text(str(index + 1), 22, ACCENT)
		number.custom_minimum_size.x = 22
		number.autowrap_mode = TextServer.AUTOWRAP_OFF
		row.add_child(number)
		var line = _text(tr(LINES[index]), 19, INK)
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(line)
		lines.add_child(row)
	column.add_child(_text(tr("INTRO_FOOTER"), 16, INK.darkened(0.3)))

	var buttons = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	column.add_child(buttons)
	var tutorial = _button("IntroTutorialButton", "INTRO_TUTORIAL", true)
	tutorial.pressed.connect(_answer.bind(true))
	buttons.add_child(tutorial)
	var skip = _button("IntroSkipButton", "INTRO_SKIP", false)
	skip.pressed.connect(_answer.bind(false))
	buttons.add_child(skip)
	tutorial.grab_focus.call_deferred()


func _unhandled_input(event):
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_answer(false)


func _answer(tutorial):
	Globals.options.intro_seen = true
	if FeatureFlags.remember_first_run:
		Globals.options.save()
	if tutorial:
		tutorial_chosen.emit()
	else:
		dismissed.emit()
	queue_free()


func _text(text, font_size, color):
	var label = Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(node_name, key, primary):
	var button = Button.new()
	button.name = node_name
	button.text = tr(key)
	button.tooltip_text = tr(key + "_TOOLTIP")
	button.custom_minimum_size = Vector2(0, 48)
	button.add_theme_font_size_override("font_size", 22 if primary else 20)
	var normal = StyleBoxFlat.new()
	normal.bg_color = ACCENT if primary else Color(1, 1, 1, 0.06)
	normal.set_corner_radius_all(8)
	normal.content_margin_left = 22
	normal.content_margin_right = 22
	var hover = normal.duplicate()
	hover.bg_color = ACCENT.lightened(0.15) if primary else Color(1, 1, 1, 0.14)
	for state in ["normal", "focus"]:
		button.add_theme_stylebox_override(state, normal)
	for state in ["hover", "pressed", "hover_pressed"]:
		button.add_theme_stylebox_override(state, hover)
	var ink = Color("1a1206") if primary else INK
	for color_name in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(color_name, ink)
	return button
