extends Node3D

# One neutral outpost: a concrete pad, a flag pole and a capture ring. The flag carries the
# owner's colour and rises up the pole while a player captures it; the ring fills in the
# capturer's colour. All the rules live in Outposts.gd; this node only holds the state and
# shows it. While a visible player owns it, it reveals the fog around it like a unit does.

const NEUTRAL_COLOR = Color(0.58, 0.58, 0.6)  # grey: reads against sand and grass
const POLE_HEIGHT = 4.2
const FLAG_SIZE = Vector3(1.6, 0.9, 0.06)
const FLAG_LOW = 0.6

var owner_player = null  # the player holding it, null while neutral
var capturer = null  # the player capturing it (or taking it back to neutral)
var progress = 0.0  # 0..1 of the capture under way
var contested = false
var radius = 5.0
var sight_range = 9.0
var global_position_yless:  # read by the fog of war code, like Unit's
	get:
		return global_position * Vector3(1, 0, 1)

var _flag = null
var _flag_material = null
var _ring_material = null
var _wave_time = 0.0


func _ready():
	_build()
	refresh()


func _process(delta):
	_wave_time += delta
	_flag.rotation.y = sin(_wave_time * 2.3) * 0.12
	_flag.rotation.z = sin(_wave_time * 3.1) * 0.03


func is_revealing():
	return is_in_group("revealed_units") and visible


func refresh():
	"""shows owner, capture and contest state"""
	var owner_color = owner_player.color if _valid(owner_player) else NEUTRAL_COLOR
	var capture_color = capturer.color if _valid(capturer) else owner_color
	# a player taking it from someone else first pulls the owner's flag down
	var flag_height = 1.0
	if _valid(capturer):
		flag_height = progress if not _valid(owner_player) else 1.0 - progress
	_flag.position.y = lerpf(FLAG_LOW, POLE_HEIGHT - FLAG_SIZE.y * 0.5, flag_height)
	_flag_material.albedo_color = owner_color
	_flag_material.emission = owner_color
	_ring_material.set_shader_parameter("owner_color", owner_color)
	_ring_material.set_shader_parameter("capture_color", capture_color)
	_ring_material.set_shader_parameter("progress", progress if _valid(capturer) else 0.0)
	_ring_material.set_shader_parameter("contested", 1.0 if contested else 0.0)


func _valid(player):
	return player != null and is_instance_valid(player)


func _build():
	var concrete = StandardMaterial3D.new()
	concrete.albedo_color = Color(0.56, 0.53, 0.48)
	concrete.roughness = 0.9
	var metal = StandardMaterial3D.new()
	metal.albedo_color = Color(0.2, 0.21, 0.22)
	metal.metallic = 0.6
	metal.roughness = 0.45
	var sandbag = StandardMaterial3D.new()
	sandbag.albedo_color = Color(0.45, 0.4, 0.3)
	sandbag.roughness = 1.0

	var pad = MeshInstance3D.new()
	pad.name = "Pad"
	var pad_mesh = CylinderMesh.new()
	pad_mesh.top_radius = 1.7
	pad_mesh.bottom_radius = 1.9
	pad_mesh.height = 0.24
	pad_mesh.radial_segments = 8
	pad.mesh = pad_mesh
	pad.material_override = concrete
	pad.position.y = 0.12
	add_child(pad)

	for i in range(14):  # a knee-high sandbag ring around the pad, open on one side
		if i == 3 or i == 4:
			continue
		var angle = TAU * (i + 0.5) / 14.0
		var bag = MeshInstance3D.new()
		var bag_mesh = BoxMesh.new()
		bag_mesh.size = Vector3(0.95, 0.3, 0.38)
		bag.mesh = bag_mesh
		bag.material_override = sandbag
		bag.position = Vector3(cos(angle), 0, sin(angle)) * 2.2 + Vector3(0, 0.15, 0)
		bag.rotation.y = -angle + PI / 2.0
		add_child(bag)

	var pole = MeshInstance3D.new()
	pole.name = "Pole"
	var pole_mesh = CylinderMesh.new()
	pole_mesh.top_radius = 0.05
	pole_mesh.bottom_radius = 0.07
	pole_mesh.height = POLE_HEIGHT
	pole_mesh.radial_segments = 8
	pole_mesh.rings = 1
	pole.mesh = pole_mesh
	pole.material_override = metal
	pole.position.y = POLE_HEIGHT / 2.0
	add_child(pole)
	var cap = MeshInstance3D.new()
	var cap_mesh = SphereMesh.new()
	cap_mesh.radius = 0.11
	cap_mesh.height = 0.22
	cap_mesh.radial_segments = 8
	cap_mesh.rings = 4
	cap.mesh = cap_mesh
	cap.material_override = metal
	cap.position.y = POLE_HEIGHT
	add_child(cap)

	_flag = Node3D.new()
	_flag.name = "Flag"
	add_child(_flag)
	var cloth = MeshInstance3D.new()
	var cloth_mesh = BoxMesh.new()
	cloth_mesh.size = FLAG_SIZE
	cloth.mesh = cloth_mesh
	cloth.position.x = FLAG_SIZE.x * 0.5 + 0.06
	_flag_material = StandardMaterial3D.new()
	_flag_material.roughness = 0.8
	_flag_material.emission_enabled = true
	_flag_material.emission_energy_multiplier = 0.35  # readable in shade and haze
	cloth.material_override = _flag_material
	_flag.add_child(cloth)

	var ring = MeshInstance3D.new()
	ring.name = "CaptureRing"
	var ring_mesh = PlaneMesh.new()
	ring_mesh.size = Vector2.ONE * radius * 2.0
	ring.mesh = ring_mesh
	ring.position.y = 0.04
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring_material = ShaderMaterial.new()
	_ring_material.shader = _ring_shader()
	ring.material_override = _ring_material
	add_child(ring)


static func _ring_shader():
	var shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 owner_color : source_color = vec4(1.0);
uniform vec4 capture_color : source_color = vec4(1.0);
uniform float progress = 0.0;
uniform float contested = 0.0;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float angle = fract(atan(p.x, -p.y) / 6.2831853 + 1.0);
	// the zone's edge, dashed so that it reads as an area and not a wall
	float edge = smoothstep(0.9, 0.93, r) * (1.0 - smoothstep(0.97, 1.0, r));
	float dashes = step(0.45, fract(angle * 36.0));
	float edge_alpha = edge * dashes * 0.75;
	// the capture arc just inside it, filling clockwise from the top
	float band = smoothstep(0.78, 0.8, r) * (1.0 - smoothstep(0.86, 0.88, r));
	float filled = step(angle, progress);
	float pulse = contested * (0.5 + 0.5 * sin(TIME * 8.0));
	vec3 color = owner_color.rgb;
	float alpha = edge_alpha;
	if (band > 0.0) {
		color = mix(vec3(0.08), capture_color.rgb, filled);
		color = mix(color, vec3(1.0, 0.25, 0.2), pulse * 0.8);
		alpha = max(alpha, band * mix(0.35, 0.9, filled));
	}
	// a faint tint over the whole zone
	alpha = max(alpha, (1.0 - smoothstep(0.88, 0.92, r)) * 0.07);
	ALBEDO = color;
	ALPHA = alpha;
}
"""
	return shader
