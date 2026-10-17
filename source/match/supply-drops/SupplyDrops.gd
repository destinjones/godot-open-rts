extends Node3D

# Supply drops: every minute or two a crate floats down somewhere between the cities, marked
# by a beacon and a yellow minimap ping, and the first ground unit to reach it takes it for
# its player. Something worth sending a fast unit for, and a reason for skirmishes away
# from the bases. What a crate holds is drawn by weight from data/supply_drops.json:
#
# - goods: a bundle of commodities for the player's stock,
# - repair: the player's units around the crate are patched up to full hp,
# - veterans: experience for the player's combat units around it (Veterancy.gd); a match
#   without veterancy gets goods instead.
#
# Crates nobody takes are gone after a while. MatchSignals.supply_drop_landed and
# supply_drop_collected are there for sounds, hints and the AI (SupplyDropController.gd).

const SupplyCrate = preload("res://source/match/supply-drops/SupplyCrate.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const GameData = preload("res://source/data-model/GameData.gd")

const TICK_S = 0.2
const PING_COLOR = Color(1.0, 0.82, 0.25)
const SPOT_TRIES = 48
const POPUP_S = 2.4

var config = {}
var crates = []

var _until_next_s = 0.0
var _since_tick = 0.0
var _rng = RandomNumberGenerator.new()

@onready var _match = find_parent("Match")


static func of(tree):
	return tree.get_first_node_in_group("supply_drops")


func _ready():
	add_to_group("supply_drops")
	set_process(false)
	config = GameData.supply_drops()
	if not config.get("enabled", true) or config.get("contents", []).is_empty():
		return
	if not _match.is_node_ready():
		await _match.ready
	_rng.randomize()
	_until_next_s = float(config.get("first_drop_after_s", 120.0))
	set_process(true)


func _process(delta):
	_until_next_s -= delta
	if _until_next_s <= 0.0:
		_until_next_s = _next_interval()
		if crates.size() < int(config.get("max_on_map", 2)):
			drop()
	_since_tick += delta
	if _since_tick >= TICK_S:
		_tick()
		_since_tick = 0.0


func drop(at = null, content = null):
	"""drops a crate at a spot (a random one when null) with a content (drawn when null);
	returns the crate or null when no spot was found"""
	var spot = _on_ground(at) if at != null else random_spot()
	if spot == null:
		return null
	var crate = SupplyCrate.new()
	crate.name = "SupplyCrate"
	crate.content = content if content != null else _draw_content()
	crate.fall_s = float(config.get("fall_s", 4.0))
	add_child(crate)
	crate.global_position = spot
	crate.landed.connect(_on_crate_landed.bind(crate))
	crates.append(crate)
	return crate


func collect(crate, unit):
	"""hands the crate's content to the unit's player"""
	if not crate in crates:
		return
	crates.erase(crate)
	var player = unit.player
	var content = crate.content
	var kind = str(content.get("id", "goods"))
	var text = ""
	if kind == "veterans" and _veterancy() == null:
		kind = "goods"
		content = _content_by_id("goods")
	match kind:
		"repair":
			var repaired = 0
			for other in _own_units_near(player, crate.global_position, content, "repair_radius_m"):
				if other.hp < other.hp_max:
					other.hp = other.hp_max
					repaired += 1
			text = tr("SUPPLY_REPAIRED").format([repaired])
		"veterans":
			var veterancy = _veterancy()
			var trained = 0
			for other in _own_units_near(player, crate.global_position, content, "xp_radius_m"):
				if veterancy.can_rank(other):
					veterancy.award(other, float(content.get("xp", 14.0)))
					trained += 1
			text = tr("SUPPLY_TRAINED").format([trained])
		_:
			var goods = {}
			for resource in content.get("resources", {}):  # JSON numbers are floats
				goods[resource] = int(content["resources"][resource])
			player.add_resources(goods)
			var parts = []
			for resource in goods:
				parts.append("+%d %s" % [goods[resource], tr(resource.to_upper())])
			text = "  ".join(parts)
	_popup(crate.global_position, text, player.color)
	MatchSignals.supply_drop_collected.emit(crate, player, kind)
	crate.queue_free()


func random_spot():
	"""a dry, open spot between the cities, nearer the middle more often than not"""
	var map = _match.map
	var centre = Vector3(map.size.x, 0, map.size.y) / 2.0
	var reach = min(map.size.x, map.size.y) * 0.42
	for _i in range(SPOT_TRIES):
		var angle = _rng.randf() * TAU
		var distance = sqrt(_rng.randf()) * reach
		var spot = centre + Vector3(cos(angle), 0, sin(angle)) * distance
		if not _is_open(map, spot):
			continue
		var ground = _on_ground(spot)
		# a spot the navigation mesh doesn't reach (a forest, rocks) is no use to anyone
		if ground.distance_to(spot * Vector3(1, 0, 1)) <= 1.0:
			return ground
	return null


func _tick():
	var radius = float(config.get("pickup_radius_m", 1.8))
	var expires = float(config.get("expires_after_s", 150.0))
	for crate in crates.duplicate():
		if not crate.has_landed:
			continue
		if crate.age_s >= expires:
			crates.erase(crate)
			crate.queue_free()
			continue
		var taker = _nearest_taker(crate.global_position, radius)
		if taker != null:
			collect(crate, taker)


func _nearest_taker(at, radius):
	var best = null
	var best_distance = radius * radius
	var flat = at * Vector3(1, 0, 1)
	for unit in get_tree().get_nodes_in_group("units"):
		if not can_take(unit):
			continue
		var distance = unit.global_position_yless.distance_squared_to(flat)
		if distance <= best_distance:
			best_distance = distance
			best = unit
	return best


static func can_take(unit):
	"""any ground unit that moves can pick a crate up, constructors and trucks included"""
	return (
		not unit is Structure
		and unit.hp != null
		and unit.hp > 0
		and unit.get_movement_trait() != null
		and unit.movement_domain != Constants.Match.Navigation.Domain.AIR
	)


func _own_units_near(player, at, content, radius_key):
	var radius = float(content.get(radius_key, 10.0))
	var flat = at * Vector3(1, 0, 1)
	return get_tree().get_nodes_in_group("units").filter(
		func(unit):
			return (
				unit.player == player
				and not unit is Structure
				and unit.hp != null
				and unit.hp > 0
				and unit.global_position_yless.distance_to(flat) <= radius
			)
	)


func _on_crate_landed(crate):
	MatchSignals.supply_drop_landed.emit(crate)
	var minimap = _match.find_child("Minimap", true, false)
	if minimap != null and minimap.has_method("ping"):
		minimap.ping(crate.global_position, PING_COLOR)


func _draw_content():
	var contents = config.get("contents", [])
	var total = 0.0
	for entry in contents:
		total += float(entry.get("weight", 1.0))
	var roll = _rng.randf() * total
	for entry in contents:
		roll -= float(entry.get("weight", 1.0))
		if roll <= 0.0:
			return entry
	return contents.back()


func _content_by_id(id):
	for entry in config.get("contents", []):
		if entry.get("id") == id:
			return entry
	return {}


func _next_interval():
	var every = config.get("every_s", [80.0, 120.0])
	if every is Array:
		return _rng.randf_range(float(every[0]), float(every[1]))
	return float(every)


func _veterancy():
	var node = get_tree().get_first_node_in_group("veterancy")
	return node if node != null and node.has_method("award") else null


func _is_open(map, spot):
	var margin = 6.0
	if (
		spot.x < margin
		or spot.z < margin
		or spot.x > map.size.x - margin
		or spot.z > map.size.y - margin
	):
		return false
	if map.water_depth_at(spot) != 0:
		return false
	var flat = Vector2(spot.x, spot.z)
	var centre = Vector2(map.size.x, map.size.y) / 2.0
	var nearest_start = INF
	for zone in map.get_start_zones():
		nearest_start = min(nearest_start, centre.distance_to(zone["center"]))
	var clearance = min(
		float(config.get("min_distance_from_start_m", 14.0)),
		nearest_start * 0.4 if nearest_start != INF else INF
	)
	for zone in map.get_start_zones():
		if flat.distance_to(zone["center"]) < zone["radius"] + clearance:
			return false
	for node in (
		get_tree().get_nodes_in_group("units") + get_tree().get_nodes_in_group("resource_units")
	):
		var at = Vector2(node.global_position.x, node.global_position.z)
		if flat.distance_to(at) < (5.0 if node is Structure else 3.0):
			return false
	for crate in crates:
		if flat.distance_to(Vector2(crate.global_position.x, crate.global_position.z)) < 15.0:
			return false
	return true


func _on_ground(spot):
	var navigation = _match.navigation
	if navigation == null:
		return spot
	var rid = navigation.get_navigation_map_rid_by_domain(Constants.Match.Navigation.Domain.TERRAIN)
	var closest = NavigationServer3D.map_get_closest_point(rid, spot)
	if closest == Vector3.ZERO:  # no navigation mesh baked (yet)
		return spot
	return Vector3(closest.x, 0, closest.z)  # the nearest spot units can walk to


func _popup(at, text, color):
	if text == "":
		return
	var label = Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.render_priority = 3
	label.pixel_size = 0.006
	label.font_size = 40
	label.outline_size = 12
	label.modulate = color.lightened(0.35)
	label.outline_modulate = Color(0.05, 0.05, 0.05, 0.9)
	add_child(label)
	var start = at + Vector3(0, 1.6, 0)
	label.global_position = start
	var tween = label.create_tween().set_parallel()
	tween.tween_property(label, "global_position", start + Vector3(0, 1.4, 0), POPUP_S)
	tween.tween_property(label, "modulate:a", 0.0, POPUP_S * 0.45).set_delay(POPUP_S * 0.55)
	tween.chain().tween_callback(label.queue_free)
