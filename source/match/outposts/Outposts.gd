extends Node3D

# Neutral outposts out between the start zones: something worth fighting over in the
# middle of the map, and income that needs no trucks, only an army to hold it.
#
# - placed when the match starts: one in the centre and one between each pair of
#   neighbouring spawn points (a map entry may list its own spots, or turn them off),
#   moved off water, deposits and start zones, snapped onto the ground navigation,
# - captured by standing combat ground units in the ring with no enemy unit inside: a
#   capture takes capture_s (faster with more units), and an enemy outpost is first pulled
#   down to neutral and then raised, so taking one from a rival takes twice as long,
# - an owned outpost pays income every income_every_s and reveals the fog around it,
# - the AI sends small squads to take them (OutpostController.gd).
#
# Numbers are in data/outposts.json. MatchSignals.outpost_captured fires on every change of
# owner; the minimap pings in the new owner's colour.

const Outpost = preload("res://source/match/outposts/Outpost.gd")
const OutpostMarkers = preload("res://source/match/outposts/OutpostMarkers.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const GameData = preload("res://source/data-model/GameData.gd")

const TICK_S = 0.25
const SEARCH_STEP_M = 2.0
const SEARCH_RINGS = 9
const PAD_CLEARANCE_M = 3.0  # the pad and its sandbags, kept clear of trees and rocks
const DECAY_SHARE = 0.5  # an abandoned capture falls back at half the capture speed

var config = {}
var outposts = []

var _since_tick = 0.0
var _since_income = 0.0

@onready var _match = find_parent("Match")


static func of(tree):
	return tree.get_first_node_in_group("outposts_system")


func _ready():
	add_to_group("outposts_system")
	set_process(false)
	if not _match.is_node_ready():
		await _match.ready
	config = GameData.outposts(_match.map.scene_file_path)
	if not config.get("enabled", true) or (config.get("spots") is float and config["spots"] == 0):
		return
	# the ground navigation map is only queryable after a sync, a couple of frames in
	for _i in range(3):
		await get_tree().physics_frame
	place(spots())
	_add_minimap_markers()
	set_process(true)


func _process(delta):
	_since_tick += delta
	_since_income += delta
	if _since_tick >= TICK_S:
		_tick(_since_tick)
		_since_tick = 0.0
	var every = float(config.get("income_every_s", 10.0))
	if _since_income >= every:
		_since_income -= every
		_pay_income()


func spots():
	"""where the outposts go: the map's own list, or the centre plus one between each pair of
	neighbouring spawn points"""
	var listed = config.get("spots")
	if listed is Array:
		return listed.map(func(spot): return Vector3(float(spot[0]), 0, float(spot[1])))
	var map = _match.map
	var centre = Vector3(map.size.x, 0, map.size.y) / 2.0
	var zones = map.get_start_zones()
	var result = [centre]
	if zones.size() < 2:
		return result
	var angles = []
	var distance = 0.0
	for zone in zones:
		var offset = Vector2(zone["center"].x - centre.x, zone["center"].y - centre.z)
		angles.append(offset.angle())
		distance += offset.length()
	distance = distance / zones.size() * float(config.get("distance_from_centre", 0.55))
	angles.sort()
	for i in range(angles.size()):
		var a = angles[i]
		var b = angles[(i + 1) % angles.size()] + (TAU if i == angles.size() - 1 else 0.0)
		var between = (a + b) / 2.0
		result.append(centre + Vector3(cos(between), 0, sin(between)) * distance)
	return result


func place(points):
	for outpost in outposts:
		outpost.queue_free()
	outposts = []
	for point in points:
		var spot = _free_spot_near(point)
		if spot == null:
			continue
		var outpost = Outpost.new()
		outpost.name = "Outpost%d" % outposts.size()
		outpost.radius = float(config.get("radius_m", 5.0))
		outpost.sight_range = float(config.get("sight_range", 9.0))
		add_child(outpost)
		outpost.global_position = spot
		outposts.append(outpost)


func owned_by(player):
	return outposts.filter(func(outpost): return outpost.owner_player == player)


func income_of(player):
	"""goods per income_every_s the player's outposts bring in"""
	var total = {}
	var income = config.get("income", {})
	for _outpost in owned_by(player):
		for resource in income:
			total[resource] = total.get(resource, 0) + int(income[resource])
	return total


func holders(outpost):
	"""{player: number of their combat ground units inside the ring}"""
	var counts = {}
	var radius_squared = outpost.radius * outpost.radius
	var centre = outpost.global_position * Vector3(1, 0, 1)
	for unit in get_tree().get_nodes_in_group("units"):
		if (
			unit is Structure
			or unit.attack_damage == null
			or unit.hp == null
			or unit.hp <= 0
			or unit.get_movement_trait() == null
			or unit.movement_domain == Constants.Match.Navigation.Domain.AIR
		):
			continue
		if unit.global_position_yless.distance_squared_to(centre) <= radius_squared:
			counts[unit.player] = counts.get(unit.player, 0) + 1
	return counts


func step(outpost, counts, delta):
	"""advances one outpost's capture by delta seconds given who stands in it"""
	var capture_s = float(config.get("capture_s", 14.0))
	var players = counts.keys()
	outpost.contested = false
	if players.is_empty():
		if outpost.capturer != null:
			outpost.progress -= delta / capture_s * DECAY_SHARE
			if outpost.progress <= 0.0:
				outpost.progress = 0.0
				outpost.capturer = null
		return
	for other in players:
		if not _friendly(players[0], other):
			outpost.contested = true
			return
	var owner_player = outpost.owner_player
	if owner_player != null and not is_instance_valid(owner_player):
		owner_player = null
		outpost.owner_player = null
	if owner_player != null and _friendly(owner_player, players[0]):
		# the holders are back: a capture against them is undone
		if outpost.capturer != null:
			outpost.progress -= delta / capture_s
			if outpost.progress <= 0.0:
				outpost.progress = 0.0
				outpost.capturer = null
		return
	var lead = players[0]
	var units = 0
	for player in players:
		units += counts[player]
		if counts[player] > counts[lead]:
			lead = player
	if outpost.capturer != lead:
		if outpost.capturer != null and _friendly(outpost.capturer, lead):
			lead = outpost.capturer  # an ally carries on the capture
		else:
			outpost.capturer = lead
			outpost.progress = 0.0
	var speed = min(float(config.get("max_capture_speed", 2.0)), 1.0 + 0.5 * (units - 1))
	outpost.progress += delta / capture_s * speed
	if outpost.progress < 1.0:
		return
	outpost.progress = 0.0
	var previous = outpost.owner_player
	if previous != null:
		outpost.owner_player = null  # pulled down: now raise our own flag
	else:
		outpost.owner_player = outpost.capturer
		outpost.capturer = null
	_on_owner_changed(outpost, previous)


func _tick(delta):
	for outpost in outposts:
		step(outpost, holders(outpost), delta)
		_update_revealing(outpost)
		outpost.refresh()


func _add_minimap_markers():
	var viewport = _match.find_child("MinimapViewport", true, false)
	if viewport == null:
		return
	var markers = OutpostMarkers.new()
	markers.name = "OutpostMarkers"
	markers.outposts_system = self
	var minimap = _match.find_child("Minimap", true, false)
	if minimap != null and "MINIMAP_PIXELS_PER_WORLD_METER" in minimap:
		markers.pixels_per_meter = minimap.MINIMAP_PIXELS_PER_WORLD_METER
	viewport.add_child(markers)


func _pay_income():
	var income = config.get("income", {})
	for outpost in outposts:
		if outpost.owner_player != null and is_instance_valid(outpost.owner_player):
			outpost.owner_player.add_resources(income)


func _on_owner_changed(outpost, previous):
	MatchSignals.outpost_captured.emit(outpost, previous, outpost.owner_player)
	var minimap = _match.find_child("Minimap", true, false)
	if minimap != null and minimap.has_method("ping"):
		var color = (
			outpost.owner_player.color if outpost.owner_player != null else Outpost.NEUTRAL_COLOR
		)
		minimap.ping(outpost.global_position, color)


func _update_revealing(outpost):
	var reveals = (
		outpost.owner_player != null
		and is_instance_valid(outpost.owner_player)
		and outpost.owner_player in _match.visible_players
	)
	if reveals and not outpost.is_in_group("revealed_units"):
		outpost.add_to_group("revealed_units")
	elif not reveals and outpost.is_in_group("revealed_units"):
		outpost.remove_from_group("revealed_units")


func _start_clearance(map):
	"""min_distance_from_start_m, shrunk on small maps so the outposts still fit between
	the starts"""
	var centre = Vector2(map.size.x, map.size.y) / 2.0
	var nearest = INF
	for zone in map.get_start_zones():
		nearest = min(nearest, centre.distance_to(zone["center"]))
	var wanted = float(config.get("min_distance_from_start_m", 18.0))
	return wanted if nearest == INF else min(wanted, nearest * 0.45)


static func _friendly(a, b):
	return a == b or Diplomacy.allied(a, b)


func _free_spot_near(point):
	"""the nearest spot to point on dry ground, clear of deposits and start zones"""
	var map = _match.map
	for ring in range(SEARCH_RINGS + 1):
		var count = 1 if ring == 0 else ring * 6
		for i in range(count):
			var angle = TAU * i / count
			var candidate = point + Vector3(cos(angle), 0, sin(angle)) * ring * SEARCH_STEP_M
			if _is_free(map, candidate):
				return _on_ground(candidate)
	return null


func _is_free(map, spot):
	var margin = float(config.get("radius_m", 5.0))
	var inside = (
		spot.x >= margin
		and spot.z >= margin
		and spot.x <= map.size.x - margin
		and spot.z <= map.size.y - margin
	)
	var flat = Vector2(spot.x, spot.z)
	# clear of forests, outcrops and lakes on generated maps, and walkable all round
	var obstructed = map.has_method("is_obstructed") and map.is_obstructed(flat, PAD_CLEARANCE_M)
	return (
		inside
		and not obstructed
		and _on_dry_ground(map, spot)
		and _clear_of_starts_and_deposits(map, flat)
		and _walkable_around(spot, PAD_CLEARANCE_M)
	)


func _on_dry_ground(map, spot):
	"""the whole pad must be on dry ground"""
	for offset in [Vector2.ZERO, Vector2(3, 0), Vector2(-3, 0), Vector2(0, 3), Vector2(0, -3)]:
		if map.water_depth_at(Vector3(spot.x + offset.x, 0, spot.z + offset.y)) != 0:
			return false
	return true


func _clear_of_starts_and_deposits(map, flat):
	var from_start = _start_clearance(map)
	for zone in map.get_start_zones():
		if flat.distance_to(zone["center"]) < zone["radius"] + from_start:
			return false
	var from_deposit = float(config.get("min_distance_from_deposit_m", 5.0))
	for deposit in get_tree().get_nodes_in_group("resource_units"):
		var at = Vector2(deposit.global_position.x, deposit.global_position.z)
		if flat.distance_to(at) < from_deposit + 2.0:
			return false
	for outpost in outposts:
		if flat.distance_to(Vector2(outpost.global_position.x, outpost.global_position.z)) < 12:
			return false
	return true


func _walkable_around(spot, reach):
	"""whether the ground navigation covers the spot and a ring of points around it"""
	var navigation = _match.navigation
	if navigation == null:
		return true
	var rid = navigation.get_navigation_map_rid_by_domain(Constants.Match.Navigation.Domain.TERRAIN)
	if NavigationServer3D.map_get_iteration_id(rid) == 0:
		return true  # not synced yet: nothing to go by
	var points = [spot]
	for i in range(8):
		var angle = TAU * i / 8.0
		points.append(spot + Vector3(cos(angle), 0, sin(angle)) * reach)
	for point in points:
		var closest = NavigationServer3D.map_get_closest_point(rid, point)
		if Vector2(closest.x, closest.z).distance_to(Vector2(point.x, point.z)) > 1.0:
			return false
	return true


func _on_ground(spot):
	var navigation = _match.navigation
	if navigation == null:
		return spot
	var rid = navigation.get_navigation_map_rid_by_domain(Constants.Match.Navigation.Domain.TERRAIN)
	var closest = NavigationServer3D.map_get_closest_point(rid, spot)
	if closest.distance_to(spot * Vector3(1, 0, 1)) > 3.0:
		return spot  # navigation not there (yet): keep the spot as it is
	return Vector3(closest.x, 0, closest.z)
