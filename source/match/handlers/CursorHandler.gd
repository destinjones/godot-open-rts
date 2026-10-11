extends Node

# The mouse cursor says what a click will do (StarCraft II style):
# - with units selected, over an enemy: a red crosshair (right-click attacks),
# - with constructors selected, over one of the player's unfinished buildings: a yellow
#   build mark (right-click sends them to build it),
# - while a fight, patrol or guard order waits for its click: that order's crosshair, in
#   the colour of its line on the ground (UnitCommandHandler.COLORS),
# - for a moment after an order that could not be carried out: a red "no" sign, and a
#   red cross on the spot. That moment is MatchSignals.units_ordered(units, "cannot"),
#   which the unit voices and any other sound hook already listen to.
# Over the HUD, while placing a building and otherwise it is the normal arrow.

const UnitCommandHandler = preload("res://source/match/handlers/UnitCommandHandler.gd")
const VirtualPointer = preload("res://source/utils/VirtualPointer.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
const Constructing = preload("res://source/match/units/actions/Constructing.gd")
const CannotMark = preload("res://source/match/utils/CannotMark.tscn")

const CROSSHAIRS = "res://assets/ui/kenney-crosshairs/crosshair%03d.png"
const SIZE_PX = 36
# cursor -> [crosshair number, colour]
const LOOKS = {
	"attack": [64, Color(1.0, 0.35, 0.25)],
	"build": [25, Color(1.0, 0.85, 0.3)],
	"fight": [64, UnitCommandHandler.COLORS["fight"]],
	"patrol": [97, UnitCommandHandler.COLORS["patrol"]],
	"guard": [38, UnitCommandHandler.COLORS["guard"]],
	"cannot": [113, Color(1.0, 0.3, 0.25)],
}
const UNITS_COLLISION_MASK = 0b10  # layer 2: unit pick shapes

var cannot_s = 0.6  # how long the "no" sign shows
var current = ""  # the cursor shown, "" for the arrow; for tests
var last_cannot_position = null  # where the last red cross went; for tests

var _images = {}
var _cannot_until_ms = 0
var _last_target = null  # where the last order went: a position or a unit

@onready var _match = find_parent("Match")


func _ready():
	name = "CursorHandler"
	add_to_group("cursor_handler")
	for cursor in LOOKS:
		_images[cursor] = _make_image(LOOKS[cursor][0], LOOKS[cursor][1])
	MatchSignals.terrain_targeted.connect(func(position): _last_target = position)
	MatchSignals.unit_targeted.connect(func(unit): _last_target = unit)
	MatchSignals.units_ordered.connect(_on_units_ordered)


static func of(tree):
	return tree.get_first_node_in_group("cursor_handler")


func _exit_tree():
	Input.set_custom_mouse_cursor(null)


func _process(_delta):
	_show(_wanted_cursor())


func _wanted_cursor():
	if Time.get_ticks_msec() < _cannot_until_ms:
		return "cannot"
	if get_viewport().gui_get_hovered_control() != null or _placing_structure():
		return ""
	var handler = UnitCommandHandler.of(get_tree())
	if handler == null:
		return ""
	if handler.mode != null:
		return handler.mode
	var selected = handler.selected_units()
	return "" if selected.is_empty() else _cursor_over(hovered_unit(), selected)


func _cursor_over(hovered, selected):
	"""the same tests the right-click order uses (UnitActionsController)"""
	if hovered == null:
		return ""
	if (
		hovered.is_in_group("adversary_units")
		and selected.any(func(unit): return AutoAttacking.is_applicable(unit, hovered))
	):
		return "attack"
	if (
		hovered.is_in_group("controlled_units")
		and selected.any(func(unit): return Constructing.is_applicable(unit, hovered))
	):
		return "build"
	return ""


func hovered_unit():
	"""the unit or deposit under the mouse, if the player can see it"""
	var camera = get_viewport().get_camera_3d()
	if camera == null:
		return null
	var mouse = VirtualPointer.get_position(get_viewport())
	var origin = camera.project_ray_origin(mouse)
	var query = PhysicsRayQueryParameters3D.create(
		origin, origin + camera.project_ray_normal(mouse) * 1000.0, UNITS_COLLISION_MASK
	)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit = camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	var node = hit["collider"]
	while node != null and not (node.is_in_group("units") or node.is_in_group("resource_units")):
		node = node.get_parent()
	if node == null or not node.visible:
		return null
	return node


func _placing_structure():
	for player in get_tree().get_nodes_in_group("players"):
		var handler = player.get_node_or_null("StructurePlacementHandler")
		if handler != null and handler._structure_placement_started():
			return true
	return false


func _show(cursor):
	if cursor == current:
		return
	current = cursor
	if cursor == "":
		Input.set_custom_mouse_cursor(null)
	else:
		Input.set_custom_mouse_cursor(
			_images[cursor], Input.CURSOR_ARROW, Vector2.ONE * SIZE_PX / 2
		)


func _make_image(number, color):
	var image = load(CROSSHAIRS % number).get_image()
	image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	image.resize(SIZE_PX, SIZE_PX, Image.INTERPOLATE_LANCZOS)
	# white artwork: tint it, with a dark edge so it reads on bright sand too
	var tinted = Image.create(SIZE_PX, SIZE_PX, false, Image.FORMAT_RGBA8)
	for y in range(SIZE_PX):
		for x in range(SIZE_PX):
			var alpha = image.get_pixel(x, y).a
			if alpha > 0.0:
				tinted.set_pixel(x, y, Color(color, alpha))
				continue
			var edge = 0.0
			for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var other = Vector2i(x, y) + offset
				if other.x >= 0 and other.y >= 0 and other.x < SIZE_PX and other.y < SIZE_PX:
					edge = max(edge, image.get_pixelv(other).a)
			if edge > 0.0:
				tinted.set_pixel(x, y, Color(0, 0, 0, edge * 0.8))
	return tinted


func image_of(cursor):
	"""for tests and screenshots: the picture of a cursor"""
	return _images.get(cursor)


func _on_units_ordered(_units, order):
	if order != "cannot":
		return
	_cannot_until_ms = Time.get_ticks_msec() + int(cannot_s * 1000)
	var target = _last_target
	if target is Node3D and is_instance_valid(target):
		target = target.global_position
	if not target is Vector3 or _match == null:
		return
	last_cannot_position = target
	var mark = CannotMark.instantiate()
	_match.add_child(mark)
	mark.global_position = target * Vector3(1, 0, 1)
