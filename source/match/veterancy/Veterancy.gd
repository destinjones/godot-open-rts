extends Node

# Units that survive fights get better at them.
#
# A kill earns the killer experience worth the victim's cost (half for a structure); enough of
# it promotes the unit to Veteran, Elite and then Heroic (data/veterancy.json). Each rank hits
# harder, takes more punishment, and from Elite on fires faster and patches itself up when it
# has been out of the fight for a few seconds. A ranked unit wears gold chevrons over its
# health bar, and a promotion flashes its rank name above it.
#
# Like CombatEffects, nothing in the unit code calls this: it watches units enter the tree and
# follows their hp. The killer is the unit that landed the last hit (Unit.take_damage keeps it
# in the "last_hit_by" meta). Only mobile units earn ranks: turrets and militia posts have
# their own power-driven rates (CivilDefense.gd).

const Unit = preload("res://source/match/units/Unit.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const GameData = preload("res://source/data-model/GameData.gd")

const HEAL_TICK_S = 1.0
const CHEVRON_PIXEL_SIZE = 0.0095
const CHEVRON_LIFT = 0.12  # the bottom of the chevrons above the health bar
const POPUP_RISE = 1.1
const POPUP_S = 2.2

static var _chevron_textures = {}  # rank -> ImageTexture

var config = {}

var _ranked = []  # units with a rank, for self-repair
var _since_heal_tick = 0.0


static func of(tree):
	return tree.get_first_node_in_group("veterancy")


static func rank_of(unit):
	"""0 for a green unit, 1..n for the ranks of data/veterancy.json"""
	return int(unit.get_meta("veterancy_rank", 0)) if is_instance_valid(unit) else 0


static func xp_of(unit):
	return float(unit.get_meta("veterancy_xp", 0.0)) if is_instance_valid(unit) else 0.0


func _ready():
	add_to_group("veterancy")
	config = GameData.veterancy()
	if not config.get("enabled", true) or config.get("ranks", []).is_empty():
		set_process(false)
		return
	get_tree().node_added.connect(_on_node_added)


func _process(delta):
	_since_heal_tick += delta
	if _since_heal_tick < HEAL_TICK_S:
		return
	_heal(_since_heal_tick)
	_since_heal_tick = 0.0


func rank_name(rank):
	var ranks = config.get("ranks", [])
	if rank <= 0 or rank > ranks.size():
		return ""
	return tr(str(ranks[rank - 1].get("name", "")))


func can_rank(unit):
	return (
		unit is Unit
		and not unit is Structure
		and unit.attack_damage != null
		and unit.get_movement_trait() != null
	)


func award(unit, xp):
	"""adds experience and promotes as far as it reaches; returns the unit's rank"""
	if not is_instance_valid(unit) or not can_rank(unit) or unit.hp == null or unit.hp <= 0:
		return rank_of(unit)
	var total = xp_of(unit) + xp
	unit.set_meta("veterancy_xp", total)
	var ranks = config.get("ranks", [])
	var rank = rank_of(unit)
	var reached = rank
	while reached < ranks.size() and total >= float(ranks[reached].get("xp", INF)):
		reached += 1
	if reached > rank:
		_promote(unit, reached)
	return reached


func kill_xp(victim):
	var scene_path = victim._scene_path()
	var cost = Constants.Match.Units.PRODUCTION_COSTS.get(
		scene_path, Constants.Match.Units.CONSTRUCTION_COSTS.get(scene_path, {})
	)
	var value = 0.0
	for resource in cost:
		value += float(cost[resource])
	value *= float(config.get("xp_per_cost", 1.0))
	if victim is Structure:
		value *= float(config.get("structure_xp_share", 0.5))
	return max(value, float(config.get("min_xp_per_kill", 2)))


func _on_node_added(node):
	if node is Unit and not node.has_meta("_veterancy"):
		node.set_meta("_veterancy", true)
		node.hp_changed.connect(_on_hp_changed.bind(node))


func _on_hp_changed(unit):
	if unit.hp != 0 or unit.has_meta("_veterancy_counted"):
		return
	unit.set_meta("_veterancy_counted", true)
	var killer = _killer_of(unit)
	if killer != null:
		award(killer, kill_xp(unit))


func _killer_of(victim):
	if not victim.has_meta("last_hit_by"):
		return null
	var killer = victim.get_meta("last_hit_by")
	var window_ms = float(config.get("kill_credit_window_s", 3.0)) * 1000.0
	if (
		not is_instance_valid(killer)
		or not killer.is_inside_tree()
		or Time.get_ticks_msec() - int(victim.get_meta("last_hit_at_ms", 0)) > window_ms
		or killer.player == victim.player
	):
		return null
	return killer


func _promote(unit, rank):
	var ranks = config.get("ranks", [])
	if not unit.has_meta("_veterancy_base"):
		(
			unit
			. set_meta(
				"_veterancy_base",
				{
					"attack_damage": unit.attack_damage,
					"attack_interval": unit.attack_interval,
					"hp_max": unit.hp_max,
				}
			)
		)
	var base = unit.get_meta("_veterancy_base")
	var entry = ranks[rank - 1]
	var hp_share = float(unit.hp) / float(unit.hp_max) if unit.hp_max else 1.0
	unit.attack_damage = base["attack_damage"] * float(entry.get("damage", 1.0))
	if base["attack_interval"] != null:
		unit.attack_interval = base["attack_interval"] * float(entry.get("attack_interval", 1.0))
	unit.hp_max = base["hp_max"] * float(entry.get("hp", 1.0))
	var heal = float(config.get("promotion_heal_share", 0.25))
	unit.hp = min(unit.hp_max, unit.hp_max * min(1.0, hp_share + heal))
	unit.set_meta("veterancy_rank", rank)
	if not unit in _ranked:
		_ranked.append(unit)
	_show_chevrons(unit, rank, Color(str(entry.get("color", "#f2c94c"))))
	_show_popup(unit, rank_name(rank), Color(str(entry.get("color", "#f2c94c"))))
	MatchSignals.unit_promoted.emit(unit, rank)


func _heal(elapsed):
	var ranks = config.get("ranks", [])
	var quiet_ms = float(config.get("heal_after_s", 6.0)) * 1000.0
	var now = Time.get_ticks_msec()
	_ranked = _ranked.filter(func(unit): return is_instance_valid(unit) and unit.is_inside_tree())
	for unit in _ranked:
		var per_s = float(ranks[rank_of(unit) - 1].get("heal_per_s", 0.0))
		if per_s <= 0.0 or unit.hp <= 0 or unit.hp >= unit.hp_max:
			continue
		if now - int(unit.get_meta("last_hit_at_ms", -1000000)) < quiet_ms:
			continue
		unit.hp = min(unit.hp_max, unit.hp + unit.hp_max * per_s * elapsed)


func _show_chevrons(unit, rank, color):
	var sprite = unit.get_node_or_null("VeterancyChevrons")
	if sprite == null:
		sprite = Sprite3D.new()
		sprite.name = "VeterancyChevrons"
		sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sprite.no_depth_test = true
		sprite.render_priority = 2
		sprite.pixel_size = CHEVRON_PIXEL_SIZE
		sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		unit.add_child(sprite)
		sprite.position = _badge_position(unit)
	sprite.texture = chevron_texture(rank)
	sprite.offset = Vector2(0, sprite.texture.get_height() / 2.0)  # more ranks grow upwards
	sprite.modulate = color
	if unit.visible and sprite.is_inside_tree():
		sprite.scale = Vector3.ONE * 1.9
		var tween = sprite.create_tween()
		tween.tween_property(sprite, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK)
		tween.set_ease(Tween.EASE_OUT)


func _show_popup(unit, text, color):
	if not unit.visible or text == "":
		return
	var label = Label3D.new()
	label.name = "PromotionPopup"
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.render_priority = 3
	label.pixel_size = 0.006
	label.font_size = 44
	label.outline_size = 12
	label.modulate = color
	label.outline_modulate = Color(0.1, 0.07, 0.02, 0.9)
	unit.add_child(label)
	var start = _badge_position(unit) + Vector3(0, 0.35, 0)
	label.position = start
	var tween = label.create_tween().set_parallel()
	tween.tween_property(label, "position", start + Vector3(0, POPUP_RISE, 0), POPUP_S)
	tween.tween_property(label, "modulate:a", 0.0, POPUP_S * 0.5).set_delay(POPUP_S * 0.5)
	tween.chain().tween_callback(label.queue_free)


func _badge_position(unit):
	var bar = unit.get_node_or_null("HealthBar")
	if bar != null:
		return bar.position + Vector3(0, CHEVRON_LIFT, 0)
	var radius = unit.radius if unit.radius != null else 1.0
	return Vector3(0, radius + 1.0, 0)


static func chevron_texture(rank):
	"""rank stacked chevrons (a star on top for the last rank) on a dark outline, drawn white
	so that modulate can tint them"""
	if rank in _chevron_textures:
		return _chevron_textures[rank]
	var width = 52
	var step = 13
	var star = rank >= 3
	var top = 24 if star else 4
	var height = top + 16 + step * (rank - 1) + 5
	var image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var star_points = _star_polygon(Vector2(width / 2.0, 12.0), 11.0, 4.6)
	for y in range(height):
		for x in range(width):
			var p = Vector2(x + 0.5, y + 0.5)
			var d = INF
			for i in range(rank):
				var apex = Vector2(width / 2.0, top + i * step)
				d = min(d, _segment_distance(p, apex, apex + Vector2(-19, 11)))
				d = min(d, _segment_distance(p, apex, apex + Vector2(19, 11)))
			var in_star = star and Geometry2D.is_point_in_polygon(p, star_points)
			if d <= 3.3 or in_star:
				image.set_pixel(x, y, Color(1, 1, 1, 1))
			elif d <= 5.8 or (star and _polygon_distance(p, star_points) <= 2.5):
				image.set_pixel(x, y, Color(0.07, 0.05, 0.02, 0.9))
	image.generate_mipmaps()
	var texture = ImageTexture.create_from_image(image)
	_chevron_textures[rank] = texture
	return texture


static func _star_polygon(center, outer, inner):
	var points = PackedVector2Array()
	for i in range(10):
		var radius = outer if i % 2 == 0 else inner
		var angle = -PI / 2.0 + i * PI / 5.0
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return points


static func _polygon_distance(p, points):
	var d = INF
	for i in range(points.size()):
		d = min(d, _segment_distance(p, points[i], points[(i + 1) % points.size()]))
	return d


static func _segment_distance(p, a, b):
	var ab = b - a
	var t = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)
