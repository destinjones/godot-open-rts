extends RefCounted

# Hover texts for the build and production menus, made from the same data as the
# building card (BuildingInfoText.gd), so a button explains itself before it is built:
# what it is, what it does, what it needs and makes, its cost with what is short right
# now, and why it is locked. BBCode for the rich tooltip of RichTooltipButton.gd.

const HudStyle = preload("res://source/match/hud/HudStyle.gd")
const Text = preload("res://source/match/hud/BuildingInfoText.gd")

const WIDTH = 340


static func build_item(entry, player = null, hotkey = KEY_NONE):
	var lines = [_title(entry)]
	var info = _tr(entry.get("info", ""))
	if info == "" or info == entry.get("info", ""):
		info = _tr(entry.get("description", ""))
		info = info.left(1).to_upper() + info.substr(1)
	lines.append(info)
	var no_cost = entry.duplicate()
	no_cost.erase("cost")
	var needs = Text.needs_for(no_cost)
	if needs != "":
		lines.append(_field("INFO_NEEDS", needs))
	var faction = player.get("faction") if player != null else ""
	var makes = Text.makes_for(entry, faction if faction is String else "")
	if makes != _tr("INFO_NOTHING"):
		lines.append(_field("INFO_MAKES", makes))
	var properties = entry.get("properties", {})
	var stats = []
	if "hp_max" in properties:
		stats.append(_tr("TIP_HEALTH").format([int(properties["hp_max"])]))
	if "cargo_capacity" in properties:
		stats.append(_tr("CARGO_CAPACITY").format([int(properties["cargo_capacity"])]))
	if not stats.is_empty():
		lines.append(" · ".join(stats))
	lines.append(_cost_line(entry.get("cost", {}), player))
	var locked = _locked_reason(entry, player)
	if locked != "":
		lines.append(_colored(_tr("TIP_LOCKED").format([locked]), HudStyle.BAD))
	elif "extracts" in entry:
		lines.append(_muted(_tr("EXTRACTOR_PLACEMENT_HINT")))
	elif entry.get("category") == "structure":
		lines.append(_muted(_tr("STRUCTURE_BUILD_HINT")))
	if hotkey != KEY_NONE:
		lines.append(_muted(_tr("HOTKEY").format([OS.get_keycode_string(hotkey)])))
	return "\n".join(lines)


static func panel(bbcode):
	"""the tooltip itself: the HUD's dark panel around a RichTextLabel"""
	var box = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color(HudStyle.SURFACE, 0.97)
	style.border_color = HudStyle.ACCENT
	style.border_width_top = 2
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	box.add_theme_stylebox_override("panel", style)
	var label = RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(WIDTH, 0)
	label.add_theme_font_size_override("normal_font_size", 14)
	label.add_theme_font_size_override("bold_font_size", 16)
	label.add_theme_color_override("default_color", HudStyle.FG)
	label.text = bbcode
	box.add_child(label)
	return box


static func _title(entry):
	var role = "ROLE_UNIT"
	if entry.get("category") == "structure":
		role = "ROLE_" + str(entry.get("role", "support")).to_upper()
	var tier = int(entry.get("tier", 1))
	var tier_text = "  T%d" % tier if tier > 1 else ""
	return "[b]{0}[/b]  {1}".format(
		[_colored(_tr(entry["name"]), HudStyle.ACCENT), _muted(_tr(role) + tier_text)]
	)


static func _cost_line(cost, player):
	"""the cost, each commodity the player is short of in red with what they have"""
	var parts = []
	for resource in Constants.Match.Resources.ALL:
		var amount = int(cost.get(resource, 0))
		if amount <= 0:
			continue
		var part = "{0} {1}".format([amount, _tr(resource.to_upper())])
		var stock = player.get(resource) if player != null else null
		if stock != null and int(stock) < amount:
			part = _colored(part + " " + _tr("TIP_YOU_HAVE").format([int(stock)]), HudStyle.BAD)
		parts.append(part)
	if parts.is_empty():
		return _field("INFO_COSTS", _tr("INFO_NOTHING"))
	return _field("INFO_COSTS", ", ".join(parts))


static func _locked_reason(entry, player):
	if player == null or not player.has_method("can_produce"):
		return ""
	var scene_path = entry.get("scene", "")
	if not player.meets_tier_requirement(scene_path):
		var tier = Constants.Match.Tech.TIERS[int(entry.get("tier", 1)) - 1]["name"]
		return _tr("REQUIRES_TIER").format([_tr(tier)])
	if player.needs_airport_for(scene_path):
		return _tr("NEEDS_AIRPORT").format([int(entry.get("flight_endurance_s", 0))])
	if player.at_city_centre_limit(scene_path):
		return _tr("TIP_CITY_CENTRE_LIMIT")
	return ""


static func _field(caption_key, text):
	return "{0} {1}".format([_muted("[b]%s[/b]" % _tr(caption_key)), text])


static func _muted(text):
	return _colored(text, HudStyle.MUTED)


static func _colored(text, color):
	return "[color=#{0}]{1}[/color]".format([color.to_html(false), text])


static func _tr(key):
	return TranslationServer.translate(key) if key != "" else ""
