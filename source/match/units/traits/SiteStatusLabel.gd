extends Label3D

# Floating text over the player's own construction sites, saying what the site is waiting
# for: a constructor (sites never build themselves), the constructor on its way, or the
# materials that haulers still have to bring. Removes itself once the site is finished.
# "Needs a constructor" shows all the time, since nothing happens until the player acts;
# the rest shows while the site is hovered or selected, or while a constructor is selected.

const WorldLabel = preload("res://source/match/units/traits/WorldLabel.gd")

const Worker = preload("res://source/match/units/Worker.gd")
# Constructing is matched by path: preloading it here would make a cycle with Structure.gd
const CONSTRUCTING_PATH = "res://source/match/units/actions/Constructing.gd"

const REFRESH_INTERVAL_S = 0.4
const COLOR_WAITING = Color(1.0, 0.55, 0.45)
const COLOR_WORKING = Color(0.75, 1.0, 0.7)

var _since_refresh_s = REFRESH_INTERVAL_S

@onready var _site = get_parent()


func _ready():
	WorldLabel.style(self, 21, 2.2 + _site.radius)
	WorldLabel.track_focus(self, _site, _refresh)
	_site.constructed.connect(queue_free)
	_refresh()


func _process(delta):
	_since_refresh_s += delta
	if _since_refresh_s >= REFRESH_INTERVAL_S:
		_since_refresh_s = 0.0
		_refresh()


func _refresh():
	visible = _site.is_in_group("controlled_units") and _site.is_under_construction()
	if not visible:
		return
	var percent = int(_site.get_construction_progress() * 100.0)
	var building = false
	var on_the_way = false
	var constructor_selected = false
	for unit in get_tree().get_nodes_in_group("units"):
		if not unit is Worker or unit.player != _site.player:
			continue
		constructor_selected = constructor_selected or unit.is_in_group("selected_units")
		if (
			unit.action == null
			or unit.action.get_script().resource_path != CONSTRUCTING_PATH
			or unit.action.get("_target_unit") != _site
		):
			continue
		if Utils.Match.Unit.Movement.units_adhere(unit, _site):
			building = true
		else:
			on_the_way = true
	var lines = []
	if building:
		if _site.get_construction_progress() >= _site.get_materials_ratio() - 0.001:
			lines.append(tr("SITE_WAITING_FOR_MATERIALS").format([percent]))
		else:
			lines.append(tr("SITE_BUILDING").format([percent]))
	elif on_the_way:
		lines.append(tr("SITE_CONSTRUCTOR_ON_THE_WAY").format([percent]))
	else:
		lines.append(tr("SITE_NEEDS_CONSTRUCTOR").format([percent]))
	text = "\n".join(lines)
	visible = (
		not (building or on_the_way) or constructor_selected or WorldLabel.focused(self, _site)
	)
	modulate = COLOR_WORKING if building else COLOR_WAITING
