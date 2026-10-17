extends RefCounted

# Shared look and visibility rule for the text that floats over units and buildings
# (SiteStatusLabel, BufferGauge, the aircraft fuel warning). Routine status shows only
# while its unit is hovered or selected; text that needs the player (a site nobody is
# building, a full extractor, an aircraft that will crash) shows all the time. Same font
# as the HUD, drawn as a signed distance field so it stays sharp at any zoom.

const FONT_PATH = "res://assets/ui/fonts/barlow-600.woff2"
const HUD_BG = Color("#14110d")

static var _font = null


static func style(label, font_size, height_m):
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.font = _sdf_font()
	label.font_size = font_size
	label.pixel_size = 0.0018
	label.outline_size = 9
	label.outline_modulate = Color(HUD_BG, 0.9)
	label.render_priority = 10
	label.outline_render_priority = 9
	label.position = Vector3(0, height_m, 0)


static func _sdf_font():
	if _font == null:
		_font = load(FONT_PATH).duplicate()
		_font.multichannel_signed_distance_field = true
		_font.msdf_pixel_range = 14  # room for the outline
		_font.msdf_size = 48
	return _font


static func track_focus(label, unit, on_change = null):
	"""keeps label.get_meta("hovered") in step with the cursor over the unit, and calls
	on_change when the unit is hovered, left, selected or deselected"""
	label.set_meta("hovered", false)
	for entry in [[unit.mouse_entered, true], [unit.mouse_exited, false]]:
		entry[0].connect(
			func():
				label.set_meta("hovered", entry[1])
				if on_change != null:
					on_change.call()
		)
	if on_change != null and unit.has_signal("selected"):
		unit.selected.connect(on_change)
		unit.deselected.connect(on_change)


static func focused(label, unit):
	return unit.is_in_group("selected_units") or label.get_meta("hovered", false)
