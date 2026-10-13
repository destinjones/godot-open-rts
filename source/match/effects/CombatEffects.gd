extends Node3D

# The payoff of combat: what is left when things blow up.
#
# - deaths with weight: every destroyed unit leaves a Wreck (see Wreck.gd), a pure visual
#   made of copies of its meshes, while the real unit is freed as before,
# - particle explosions (fire, smoke, sparks, debris, dust and a brief light) for rocket and
#   heavy gun hits and for deaths; rifles keep the cheap quads of ShotEffects,
# - scorch marks on the ground at explosions and wrecks, fading after a minute.
#
# Like WarSounds, nothing in the unit code has to call this: it watches units enter the tree
# and reacts to one running out of hp. That is read from hp_changed rather than tree_exiting:
# the unit is about to be freed then but still whole, while on tree_exiting its meshes have
# already left the tree. Effects are only made for what the player can
# see: a unit hidden in the fog of war dies without a show, explosions off screen are
# skipped, and wrecks and scorch marks are hidden whenever their spot is out of sight. Wrecks,
# scorch marks, explosions and lights are capped, so a huge battle costs a bounded amount.

const Unit = preload("res://source/match/units/Unit.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Wreck = preload("res://source/match/effects/Wreck.gd")
const EffectParticles = preload("res://source/match/effects/EffectParticles.gd")

const MAX_WRECKS = 36
const MAX_SCORCHES = 48
const SCORCH_LIFE_S = 60.0
const SCORCH_FADE_S = 8.0
const MAX_LIVE_BURSTS = 24
const MAX_LIGHTS = 6
const LIGHT_S = 0.22
const FOG_REFRESH_S = 0.4
const SIGHT_COMPENSATION = 2.0  # as in UnitVisibilityHandler
const INFANTRY_UNITS = ["Militia"]

static var instance = null

var _wrecks = []
var _scorches = []  # [MeshInstance3D, age in seconds]
var _scorch_lift = 0.0  # each new scorch a hair higher, so overlapping ones do not flicker
var _scorch_mesh = null
var _scorch_material = null
var _wreck_char = null
var _structure_char = null
var _live_bursts = 0
var _live_lights = 0
var _since_fog_refresh = 0.0
var _war_sounds = null
var _last_revealers = null  # from the last fog refresh; null while nothing is hidden

@onready var _match = find_parent("Match")


static func explosion(unit, at, size, scorch_size = 0.0):
	"""a particle explosion for a hit on unit; false when there is no budget left for one, so
	that the caller can fall back to its cheap quads"""
	if instance == null or not is_instance_valid(instance) or not instance.is_inside_tree():
		return false
	if scorch_size > 0.0 and _leaves_scorch(unit):
		instance.add_scorch(at, scorch_size)
	return instance.explode(at, size)


static func _leaves_scorch(unit):
	"""nothing scorches the sky or the sea"""
	if not is_instance_valid(unit) or not "navigation_domain" in unit:
		return true
	var domain = unit.navigation_domain
	return (
		domain != Constants.Match.Navigation.Domain.AIR
		and domain != Constants.Match.Navigation.Domain.WATER
	)


func _enter_tree():
	instance = self


func _exit_tree():
	if instance == self:
		instance = null


func _ready():
	# dark enough to read as burnt out, light enough to keep the shape of the model
	_wreck_char = _char_material(Color(0.27, 0.23, 0.2))
	_structure_char = _char_material(Color(0.42, 0.37, 0.32))
	get_tree().node_added.connect(_on_node_added)


func _process(delta):
	_fade_scorches(delta)
	_since_fog_refresh += delta
	if _since_fog_refresh >= FOG_REFRESH_S:
		_since_fog_refresh = 0.0
		_refresh_fog()


func explode(at, size, extras = []):
	"""fire, smoke and sparks (and extras: "debris", "dust") at a world position; returns
	false only when over budget"""
	if not _on_screen(at):
		return true  # nobody would see it
	if _live_bursts >= MAX_LIVE_BURSTS:
		return false
	var burst = Node3D.new()
	burst.name = "Explosion"
	add_child(burst)
	burst.global_position = at
	var kinds = ["fire", "smoke"]
	if size >= 0.7:
		kinds.append("sparks")
	kinds.append_array(extras)
	for kind in kinds:
		burst.add_child(EffectParticles.make(kind, size))
	if size >= 1.0:
		_flash_light(burst, size)
	_live_bursts += 1
	burst.tree_exited.connect(func(): _live_bursts -= 1)
	var tween = burst.create_tween()
	tween.tween_interval(EffectParticles.longest_lifetime(kinds) + 0.3)
	tween.tween_callback(burst.queue_free)
	return true


func add_scorch(at, size):
	"""a dark burnt patch on the ground; the oldest one goes when there are too many"""
	if _scorches.size() >= MAX_SCORCHES:
		var oldest = _scorches.pop_front()
		if is_instance_valid(oldest[0]):
			oldest[0].queue_free()
	if _scorch_mesh == null:
		_scorch_mesh = PlaneMesh.new()
		_scorch_mesh.size = Vector2.ONE
		_scorch_material = ShaderMaterial.new()
		_scorch_material.shader = _scorch_shader()
	var scorch = MeshInstance3D.new()
	scorch.mesh = _scorch_mesh
	scorch.material_override = _scorch_material
	scorch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(scorch)
	_scorch_lift = fmod(_scorch_lift + 0.0015, 0.03)
	scorch.global_transform = Transform3D(
		Basis(Vector3.UP, randf() * TAU).scaled(Vector3.ONE * size * 2.0),
		Vector3(at.x, 0.025 + _scorch_lift, at.z)
	)
	scorch.visible = _is_revealed(at, _last_revealers)
	_scorches.append([scorch, 0.0])


func aircraft_impact(wreck, at, size):
	"""called by a falling aircraft wreck when it hits the ground"""
	if not wreck.visible:
		return
	explode(at + Vector3(0, 0.3, 0), clampf(size * 1.6, 1.0, 2.0), ["debris"])
	add_scorch(at, size * 1.6)
	_play_sound("explosion_large", at, 1.1)


func _on_node_added(node):
	if node is Unit and not node.has_meta("_combat_effects"):
		node.set_meta("_combat_effects", true)
		node.hp_changed.connect(_on_hp_changed.bind(node))


func _on_hp_changed(unit):
	if unit.hp != 0 or unit.has_meta("_wrecked") or not unit.is_inside_tree():
		return
	unit.set_meta("_wrecked", true)
	if unit.visible:  # no show for a death in the fog of war
		_on_unit_died(unit)


func _on_unit_died(unit):
	if unit is Structure:
		_structure_death(unit)
	elif unit.navigation_domain == Constants.Match.Navigation.Domain.AIR:
		_aircraft_death(unit)
	elif _unit_name(unit) in INFANTRY_UNITS:
		_infantry_death(unit)
	else:
		_vehicle_death(unit, unit.navigation_domain == Constants.Match.Navigation.Domain.WATER)


func _vehicle_death(unit, on_water):
	var wreck = _add_wreck(unit, Wreck.Kind.BOAT if on_water else Wreck.Kind.VEHICLE, _wreck_char)
	var size = wreck.size if wreck != null else 0.8
	var height = wreck.height if wreck != null else 0.6
	var center = unit.global_position + Vector3(0, height * 0.5, 0)
	explode(center, clampf(size * 1.4, 1.0, 2.0), ["debris"])
	if not on_water:
		add_scorch(unit.global_position, clampf(size * 1.5, 1.0, 2.2))


func _infantry_death(unit):
	_add_wreck(unit, Wreck.Kind.INFANTRY, null)
	if _on_screen(unit.global_position) and _live_bursts < MAX_LIVE_BURSTS:
		var puff = EffectParticles.make("dust", 0.5)
		puff.amount = 8
		add_child(puff)
		puff.global_position = unit.global_position
		puff.finished.connect(puff.queue_free)


func _aircraft_death(unit):
	var wreck = _add_wreck(unit, Wreck.Kind.AIRCRAFT, _wreck_char)
	if wreck != null:
		var forward = -unit.global_transform.basis.z
		forward.y = 0.0
		wreck.velocity = forward.normalized() * unit.movement_speed * 0.8 + Vector3(0, 0.6, 0)
	explode(unit.global_position, 0.9)  # hit in the air: the burst on the ground comes later


func _structure_death(unit):
	var wreck = _add_wreck(unit, Wreck.Kind.STRUCTURE, _structure_char)
	var size = wreck.size if wreck != null else 1.5
	var height = wreck.height if wreck != null else 1.0
	var center = unit.global_position + Vector3(0, height * 0.4, 0)
	explode(center, clampf(size * 1.1, 1.4, 3.6), ["debris", "dust"])
	add_scorch(unit.global_position, clampf(size * 1.4, 1.6, 4.0))
	# a couple of smaller blasts inside while it comes down
	for delay in [0.45, 1.1]:
		var offset = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)) * size * 0.5
		var timer = get_tree().create_timer(delay, false)
		timer.timeout.connect(explode.bind(center + offset, clampf(size * 0.7, 0.75, 1.4)))


func _add_wreck(unit, kind, material):
	var wreck = Wreck.from_unit(unit, material)
	if wreck == null:
		return null
	wreck.kind = kind
	wreck.effects = self
	var attacker = unit.get_meta("last_hit_by") if unit.has_meta("last_hit_by") else null
	if is_instance_valid(attacker) and attacker.is_inside_tree():
		var away = (unit.global_position - attacker.global_position) * Vector3(1, 0, 1)
		if away.length_squared() > 0.01:
			wreck.blown_towards = away.normalized()
	wreck.name = "Wreck"
	add_child(wreck)
	_wrecks.append(wreck)
	wreck.tree_exited.connect(func(): _wrecks.erase(wreck))
	var lasting = _wrecks.filter(func(a_wreck): return not a_wreck.is_sinking())
	if lasting.size() > MAX_WRECKS:
		lasting[0].sink_soon()
	return wreck


func _flash_light(parent, size):
	if _live_lights >= MAX_LIGHTS:
		return
	var light = OmniLight3D.new()
	light.light_color = Color(1.0, 0.62, 0.28)
	light.omni_range = 2.5 + 2.0 * size
	light.light_energy = 2.5 + size
	light.shadow_enabled = false
	parent.add_child(light)
	light.position = Vector3(0, 0.4, 0)
	_live_lights += 1
	light.tree_exited.connect(func(): _live_lights -= 1)
	var tween = light.create_tween()
	tween.tween_property(light, "light_energy", 0.0, LIGHT_S).set_ease(Tween.EASE_OUT)
	tween.tween_callback(light.queue_free)


func _fade_scorches(delta):
	var index = 0
	while index < _scorches.size():
		var entry = _scorches[index]
		entry[1] += delta
		var fade = (entry[1] - SCORCH_LIFE_S) / SCORCH_FADE_S
		if not is_instance_valid(entry[0]) or fade >= 1.0:
			if is_instance_valid(entry[0]):
				entry[0].queue_free()
			_scorches.remove_at(index)
			continue
		if fade > 0.0:
			entry[0].transparency = fade
		index += 1


func _refresh_fog():
	var revealers = _revealers()
	_last_revealers = revealers
	for wreck in _wrecks:
		wreck.visible = _is_revealed(wreck.global_position, revealers)
	for entry in _scorches:
		if is_instance_valid(entry[0]):
			entry[0].visible = _is_revealed(entry[0].global_position, revealers)


func _revealers():
	"""[position, reach squared] of everything that sees for the player; null when nothing is
	hidden"""
	var handler = _match.find_child("UnitVisibilityHandler", true, false) if _match else null
	if handler == null or not handler.visible:
		return null
	var revealers = []
	for unit in get_tree().get_nodes_in_group("revealed_units"):
		if not unit.is_revealing():
			continue
		var sight_range = unit.sight_range
		if sight_range == null:
			continue
		var reach = sight_range + SIGHT_COMPENSATION
		revealers.append([Vector2(unit.global_position.x, unit.global_position.z), reach * reach])
	return revealers


func _is_revealed(at, revealers):
	if revealers == null:
		return true
	var spot = Vector2(at.x, at.z)
	for revealer in revealers:
		if revealer[0].distance_squared_to(spot) <= revealer[1]:
			return true
	return false


func _on_screen(at):
	var camera = get_viewport().get_camera_3d()
	return camera == null or camera.is_position_in_frustum(at)


func _play_sound(kind, at, loudness):
	if _war_sounds == null or not is_instance_valid(_war_sounds):
		_war_sounds = _match.find_child("WarSounds", true, false) if _match else null
	if _war_sounds != null:
		_war_sounds.play(kind, at, loudness)


func _unit_name(unit):
	return unit.scene_file_path.get_file().get_basename()


func _char_material(color):
	"""burnt paint: the model's vertex colours, darkened"""
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.85
	material.metallic_specular = 0.3
	return material


func _scorch_shader():
	var shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float d = length(p);
	float a = atan(p.y, p.x);
	// a crater: a black pit, a lighter rim of thrown-up earth, then soot fading out in a
	// slightly uneven edge with faint streaks, so that no two marks line up the same way
	float edge = 0.9 + 0.06 * sin(a * 3.0 + sin(a * 2.0) * 1.5) + 0.03 * sin(a * 11.0);
	float streaks = 0.5 + 0.5 * sin(a * 7.0 + d * 4.0);
	float soot = 1.0 - smoothstep(edge * 0.35, edge, d);
	float rim = smoothstep(0.18, 0.3, d) * (1.0 - smoothstep(0.3, 0.45, d));
	vec3 pit = vec3(0.03, 0.026, 0.022);
	vec3 burnt = vec3(0.12, 0.1, 0.08) + 0.03 * streaks;
	ALBEDO = mix(mix(pit, burnt, smoothstep(0.1, 0.35, d)), vec3(0.3, 0.25, 0.19), rim * 0.6);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	ALPHA = clamp(soot * 0.9 + rim * 0.3, 0.0, 0.92);
}
"""
	return shader
