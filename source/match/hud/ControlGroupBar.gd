extends HBoxContainer

# The control groups on screen (StarCraft II style), top centre under the diplomacy bar,
# where no panel sits: one slot per group that has units, with its number, how many
# units are in it and the icon of the most common unit type. A slot lights up when its
# group is recalled or changed; clicking it selects the group (twice quickly: the camera
# goes to it).

const GameData = preload("res://source/data-model/GameData.gd")
const HudStyle = preload("res://source/match/hud/HudStyle.gd")
const UnitGroupSelectionHandler = preload(
	"res://source/match/handlers/UnitGroupSelectionHandler.gd"
)

const SLOT_SIZE = Vector2(48, 48)
const REFRESH_S = 0.25  # groups shrink as units die; a cheap poll keeps the counts right

var flash_s = 0.35

var _handler = null
var _slots = {}  # group id -> Button
var _since_refresh = 0.0
var _shown = {}  # group id -> [count, icon path] last drawn, to rebuild only on change


func _ready():
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", 4)
	_setup.call_deferred()  # the handlers come after the HUD in the match scene


func _setup():
	_handler = UnitGroupSelectionHandler.of(get_tree())
	if _handler == null:
		hide()
		return
	_handler.group_changed.connect(_on_group_touched)
	_handler.group_recalled.connect(_on_group_touched)
	for group_id in range(1, 10):
		_slots[group_id] = _make_slot(group_id)
		add_child(_slots[group_id])
	_refresh()


func _process(delta):
	if _handler == null:
		return
	_since_refresh += delta
	if _since_refresh >= REFRESH_S:
		_refresh()


func slot(group_id):
	"""for tests"""
	return _slots.get(group_id)


func _make_slot(group_id):
	var button = Button.new()
	button.theme_type_variation = "SlotButton"
	button.custom_minimum_size = SLOT_SIZE
	button.focus_mode = Control.FOCUS_NONE
	button.pivot_offset = SLOT_SIZE / 2.0
	button.pressed.connect(func(): _handler.access_group(group_id))
	var icon = HudStyle.icon_rect(null, 30)
	icon.name = "Icon"
	icon.position = (SLOT_SIZE - icon.custom_minimum_size) / 2.0 + Vector2(0, -2)
	button.add_child(icon)
	var number = _label(str(group_id), 15, HudStyle.ACCENT)
	number.name = "Number"
	number.position = Vector2(5, 1)
	button.add_child(number)
	var count = _label("", 13, HudStyle.FG)
	count.name = "Count"
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.size = Vector2(SLOT_SIZE.x - 6, 16)
	count.position = Vector2(0, SLOT_SIZE.y - 18)
	button.add_child(count)
	button.hide()
	return button


func _label(text, font_size, color):
	var label = Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	return label


func _refresh():
	_since_refresh = 0.0
	for group_id in _slots:
		var units = _handler.units_in_group(group_id)
		var icon_path = _main_icon(units)
		var drawn = [units.size(), icon_path]
		if _shown.get(group_id) == drawn:
			continue
		_shown[group_id] = drawn
		var button = _slots[group_id]
		button.visible = not units.is_empty()
		button.get_node("Count").text = str(units.size()) if units.size() > 1 else ""
		var icon = button.get_node("Icon")
		icon.texture = load(icon_path) if icon_path != "" else null
		button.text = "" if icon_path != "" or units.is_empty() else "·"


func _main_icon(units):
	"""the icon of the unit type the group has most of"""
	var counts = {}
	for unit in units:
		counts[unit.scene_file_path] = counts.get(unit.scene_file_path, 0) + 1
	var best = ""
	for scene_path in counts:
		if best == "" or counts[scene_path] > counts[best]:
			best = scene_path
	if best == "":
		return ""
	var entry = GameData.unit_by_scene(best)
	if entry != null and "icon" in entry and ResourceLoader.exists(entry["icon"]):
		return entry["icon"]
	return ""


func _on_group_touched(group_id):
	_refresh()
	var button = _slots.get(group_id)
	if button == null or not button.visible:
		return
	button.modulate = Color(1.6, 1.4, 1.0)
	button.scale = Vector2(1.12, 1.12)
	var tween = button.create_tween().set_parallel()
	tween.tween_property(button, "modulate", Color.WHITE, flash_s)
	tween.tween_property(button, "scale", Vector2.ONE, flash_s).set_trans(Tween.TRANS_BACK)
