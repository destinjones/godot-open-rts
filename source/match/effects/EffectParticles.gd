extends RefCounted

# GPUParticles3D building blocks for the heavier combat effects: fire balls, smoke, sparks,
# dust and debris of explosions, and the steady smoke and flames of burning wrecks and
# damaged buildings.
#
# Every kind is described by one entry of KINDS. Process materials, meshes and draw
# materials are built once per kind and size step and shared by every emitter of that kind,
# so a new explosion is only a few nodes. Everything sticks to features that the
# Compatibility renderer (GLES3) supports too: ParticleProcessMaterial, billboarded quads
# with a StandardMaterial3D and a generated gradient texture, no collisions, no sub-emitters,
# no trails.

# amount/lifetime per emitter; velocities, sizes and radii are in metres for size 1.0 and
# grow with the size given; colours run over the particle's life
const KINDS = {
	"fire":
	{
		"amount": 14,
		"lifetime": 0.6,
		"explosiveness": 0.95,
		"velocity": [1.0, 3.2],
		"spread": 180.0,
		"gravity": Vector3(0, 2.0, 0),
		"damping": [3.0, 5.0],
		"quad": 1.0,
		"scale": [0.6, 1.25],
		"grow": [1.0, 0.35],
		"radius": 0.25,
		"material": "glow",
		"colors":
		[
			Color(1.0, 0.98, 0.85, 1.0),
			Color(1.0, 0.72, 0.2, 1.0),
			Color(0.95, 0.33, 0.06, 0.9),
			Color(0.35, 0.1, 0.04, 0.0),
		],
	},
	"smoke":
	{
		"amount": 10,
		"lifetime": 2.4,
		"explosiveness": 0.85,
		"velocity": [0.5, 1.6],
		"spread": 70.0,
		"gravity": Vector3(0.25, 0.9, 0.0),
		"damping": [1.2, 2.0],
		"quad": 1.1,
		"scale": [0.7, 1.3],
		"grow": [0.45, 1.7],
		"radius": 0.35,
		"material": "smoke",
		"colors":
		[
			Color(0.2, 0.18, 0.16, 0.0),
			Color(0.16, 0.15, 0.14, 0.8),
			Color(0.3, 0.29, 0.28, 0.45),
			Color(0.45, 0.44, 0.42, 0.0),
		],
	},
	"sparks":
	{
		"amount": 18,
		"lifetime": 0.8,
		"explosiveness": 1.0,
		"velocity": [3.5, 8.0],
		"spread": 75.0,
		"gravity": Vector3(0, -12.0, 0),
		"damping": [0.5, 1.5],
		"quad": 0.0,  # sparks use the streak mesh
		"scale": [0.6, 1.2],
		"grow": [1.0, 0.4],
		"radius": 0.15,
		"material": "spark",
		"colors":
		[
			Color(1.0, 0.95, 0.7, 1.0),
			Color(1.0, 0.6, 0.15, 1.0),
			Color(0.8, 0.25, 0.05, 0.0),
		],
	},
	"dust":
	{
		"amount": 26,
		"lifetime": 3.0,
		"explosiveness": 0.9,
		"velocity": [1.5, 3.8],
		"spread": 85.0,
		"direction": Vector3(0, 0.25, 0),
		"gravity": Vector3(0.2, 0.35, 0.0),
		"damping": [1.8, 2.6],
		"quad": 1.6,
		"scale": [0.7, 1.3],
		"grow": [0.5, 2.0],
		"radius": 0.8,
		"flat": true,
		"material": "smoke",
		"colors":
		[
			Color(0.55, 0.47, 0.37, 0.0),
			Color(0.52, 0.45, 0.36, 0.75),
			Color(0.58, 0.52, 0.44, 0.4),
			Color(0.62, 0.57, 0.5, 0.0),
		],
	},
	"debris":
	{
		"amount": 14,
		"lifetime": 1.5,
		"explosiveness": 1.0,
		"velocity": [2.5, 5.0],
		"spread": 50.0,
		"gravity": Vector3(0, -16.0, 0),
		"damping": [0.0, 0.3],
		"quad": 0.0,  # debris uses the chunk mesh
		"scale": [0.3, 1.0],
		"grow": [1.0, 0.6],
		"radius": 0.5,
		"spin": 540.0,
		"material": "debris",
		"colors": [Color(1, 1, 1, 1), Color(1, 1, 1, 1)],
	},
	# steady emitters, for burning wrecks and damaged buildings
	"smoke_column":
	{
		"amount": 22,
		"lifetime": 4.5,
		"explosiveness": 0.0,
		"randomness": 0.4,
		"one_shot": false,
		"velocity": [0.9, 1.5],
		"spread": 10.0,
		"gravity": Vector3(0.35, 0.25, 0.1),
		"damping": [0.1, 0.3],
		"quad": 0.9,
		"scale": [0.7, 1.2],
		"grow": [0.4, 2.4],
		"radius": 0.2,
		"material": "smoke",
		"colors":
		[
			Color(0.12, 0.11, 0.1, 0.0),
			Color(0.1, 0.09, 0.09, 0.75),
			Color(0.24, 0.23, 0.22, 0.4),
			Color(0.4, 0.39, 0.38, 0.0),
		],
	},
	"flames":
	{
		"amount": 16,
		"lifetime": 0.75,
		"explosiveness": 0.0,
		"randomness": 0.5,
		"one_shot": false,
		"velocity": [0.4, 1.0],
		"spread": 15.0,
		"gravity": Vector3(0, 2.2, 0),
		"damping": [0.5, 1.0],
		"quad": 0.55,
		"scale": [0.6, 1.2],
		"grow": [1.0, 0.25],
		"radius": 0.25,
		"material": "glow",
		"colors":
		[
			Color(1.0, 0.85, 0.4, 0.0),
			Color(1.0, 0.65, 0.18, 1.0),
			Color(0.95, 0.3, 0.05, 0.8),
			Color(0.3, 0.1, 0.05, 0.0),
		],
	},
	"embers":
	{
		"amount": 6,
		"lifetime": 1.1,
		"explosiveness": 0.6,
		"randomness": 0.8,
		"one_shot": false,
		"velocity": [1.5, 3.5],
		"spread": 40.0,
		"gravity": Vector3(0, -6.0, 0),
		"damping": [0.2, 0.6],
		"quad": 0.0,
		"scale": [0.4, 0.9],
		"grow": [1.0, 0.4],
		"radius": 0.3,
		"material": "spark",
		"colors":
		[
			Color(1.0, 0.92, 0.6, 1.0),
			Color(1.0, 0.5, 0.1, 1.0),
			Color(0.7, 0.2, 0.05, 0.0),
		],
	},
}
# sizes are rounded to these steps so that a handful of materials serve every explosion
const SIZE_STEPS = [0.5, 0.75, 1.0, 1.4, 2.0, 2.8, 3.6]

static var _cache = {}  # [kind, size step] -> {process, mesh}
static var _shared = null


static func make(kind, size = 1.0, emitting = true):
	"""a new GPUParticles3D of a kind; one-shot kinds play once as soon as they enter the tree"""
	var spec = KINDS[kind]
	var step = _size_step(size)
	var parts = _parts(kind, step)
	var particles = GPUParticles3D.new()
	particles.amount = spec["amount"]
	particles.lifetime = spec["lifetime"]
	particles.one_shot = spec.get("one_shot", true)
	particles.explosiveness = spec["explosiveness"]
	particles.randomness = spec.get("randomness", 0.2)
	particles.local_coords = false  # smoke of a moving or falling wreck trails behind it
	particles.process_material = parts["process"]
	particles.draw_pass_1 = parts["mesh"]
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if spec["material"] == "spark":
		particles.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	# the default 8 m box would cull a tall smoke column whose base is off screen
	var reach = maxf(4.0, (spec["velocity"][1] * spec["lifetime"] + 2.0) * step)
	particles.visibility_aabb = AABB(Vector3(-reach, -reach, -reach), Vector3.ONE * 2.0 * reach)
	particles.emitting = emitting
	return particles


static func longest_lifetime(kinds):
	var longest = 0.0
	for kind in kinds:
		longest = maxf(longest, KINDS[kind]["lifetime"])
	return longest


static func _size_step(size):
	var best = SIZE_STEPS[0]
	for step in SIZE_STEPS:
		if absf(step - size) < absf(best - size):
			best = step
	return best


static func _parts(kind, step):
	var key = [kind, step]
	if key in _cache:
		return _cache[key]
	var spec = KINDS[kind]
	var shared = _get_shared()
	var process = ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = spec["radius"] * step
	if spec.get("flat", false):  # dust rolls out over the ground
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		process.emission_box_extents = Vector3(1.0, 0.1, 1.0) * spec["radius"] * step
	process.direction = spec.get("direction", Vector3.UP)
	process.spread = spec["spread"]
	process.initial_velocity_min = spec["velocity"][0] * sqrt(step)
	process.initial_velocity_max = spec["velocity"][1] * sqrt(step)
	process.gravity = spec["gravity"]
	process.damping_min = spec["damping"][0]
	process.damping_max = spec["damping"][1]
	process.scale_min = spec["scale"][0]
	process.scale_max = spec["scale"][1]
	process.scale_curve = _curve_texture(spec["grow"][0], spec["grow"][1])
	process.color_ramp = _ramp_texture(spec["colors"])
	process.angle_min = -180.0
	process.angle_max = 180.0
	if spec.has("spin"):
		process.angular_velocity_min = -spec["spin"]
		process.angular_velocity_max = spec["spin"]
		process.particle_flag_rotate_y = true
	else:
		process.angular_velocity_min = -30.0
		process.angular_velocity_max = 30.0
	var mesh = null
	match spec["material"]:
		"spark":
			mesh = QuadMesh.new()
			mesh.size = Vector2(0.06, 0.4) * sqrt(step)
			mesh.material = shared["spark"]
		"debris":
			mesh = BoxMesh.new()
			mesh.size = Vector3(0.13, 0.07, 0.1) * sqrt(step)  # shrapnel, not bricks
			mesh.material = shared["debris"]
		_:
			mesh = QuadMesh.new()
			mesh.size = Vector2.ONE * spec["quad"] * step
			mesh.material = shared[spec["material"]]
	_cache[key] = {"process": process, "mesh": mesh}
	return _cache[key]


static func _curve_texture(from, to):
	var curve = Curve.new()
	curve.max_value = maxf(1.0, maxf(from, to))
	curve.add_point(Vector2(0.0, from))
	curve.add_point(Vector2(1.0, to))
	var texture = CurveTexture.new()
	texture.curve = curve
	return texture


static func _ramp_texture(colors):
	var gradient = Gradient.new()
	var offsets = PackedFloat32Array()
	for index in range(colors.size()):
		offsets.append(float(index) / float(colors.size() - 1))
	gradient.offsets = offsets
	gradient.colors = PackedColorArray(colors)
	var texture = GradientTexture1D.new()
	texture.gradient = gradient
	return texture


static func _get_shared():
	if _shared != null:
		return _shared
	_shared = {
		"glow": _billboard_material(_blob_texture(0.15)),
		"smoke": _billboard_material(_blob_texture(0.0)),
		"spark": _spark_material(),
		"debris": _debris_material(),
	}
	return _shared


static func _blob_texture(solid_core):
	"""a soft round white blob; the particle's colour tints it"""
	var gradient = Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, solid_core, 1.0])
	gradient.colors = PackedColorArray(
		[Color(1, 1, 1, 1), Color(1, 1, 1, 0.85 if solid_core > 0.0 else 0.6), Color(1, 1, 1, 0)]
	)
	var texture = GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.width = 64
	texture.height = 64
	return texture


static func _billboard_material(texture):
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = texture
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.disable_receive_shadows = true
	return material


static func _spark_material():
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = _blob_texture(0.3)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


static func _debris_material():
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0.3, 0.27, 0.24)  # scorched metal and concrete, lit
	material.roughness = 0.9
	return material
