extends Node3D

# One supply crate: it floats down under an orange parachute, lands in a puff of dust and
# then waits under a pulsing beacon until a unit picks it up (SupplyDrops.gd). Pure visuals
# and state; the rules live in SupplyDrops.gd.

signal landed

const EffectParticles = preload("res://source/match/effects/EffectParticles.gd")

const DROP_HEIGHT = 16.0
const BEACON_HEIGHT = 12.0
const CRATE_SIZE = Vector3(1.0, 0.72, 0.72)

var content = {}  # the entry of data/supply_drops.json "contents" this crate carries
var fall_s = 4.0
var has_landed = false
var age_s = 0.0  # since landing

var _body = null
var _chute = null
var _beacon_material = null
var _fall_time = 0.0
var _time = 0.0


func _ready():
	_build()
	_body.position.y = DROP_HEIGHT


func _process(delta):
	_time += delta
	if not has_landed:
		_fall_time += delta
		var t = clampf(_fall_time / fall_s, 0.0, 1.0)
		_body.position.y = lerpf(DROP_HEIGHT, 0.0, t)
		_body.rotation.z = sin(_time * 2.2) * 0.12 * (1.0 - t)
		_body.rotation.x = cos(_time * 1.7) * 0.08 * (1.0 - t)
		if t >= 1.0:
			_land()
		return
	age_s += delta
	var pulse = 0.5 + 0.5 * sin(_time * 3.0)
	_beacon_material.albedo_color.a = lerpf(0.4, 0.7, pulse)


func _land():
	has_landed = true
	_body.rotation = Vector3.ZERO
	var dust = EffectParticles.make("dust", 0.45)  # a puff, not a cloud
	add_child(dust)
	dust.position.y = 0.1
	var tween = _chute.create_tween().set_parallel()
	tween.tween_property(_chute, "scale", Vector3(1.4, 0.05, 1.4), 0.5)
	tween.tween_property(_chute, "position", _chute.position + Vector3(1.2, -2.6, 0), 0.5)
	tween.chain().tween_callback(_chute.queue_free)
	var beacon = get_node("Beacon")
	beacon.visible = true
	landed.emit()


func _build():
	var wood = StandardMaterial3D.new()
	wood.albedo_color = Color(0.36, 0.4, 0.24)  # olive drab
	wood.roughness = 0.85
	var strap = StandardMaterial3D.new()
	strap.albedo_color = Color(0.12, 0.12, 0.1)
	strap.roughness = 0.6
	var cloth = StandardMaterial3D.new()
	cloth.albedo_color = Color(1.0, 0.5, 0.12)
	cloth.roughness = 0.9
	cloth.cull_mode = BaseMaterial3D.CULL_DISABLED
	cloth.emission_enabled = true
	cloth.emission = Color(1.0, 0.5, 0.12)
	cloth.emission_energy_multiplier = 0.2
	var cord = StandardMaterial3D.new()
	cord.albedo_color = Color(0.85, 0.85, 0.8)

	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)
	var crate = MeshInstance3D.new()
	var crate_mesh = BoxMesh.new()
	crate_mesh.size = CRATE_SIZE
	crate.mesh = crate_mesh
	crate.material_override = wood
	crate.position.y = CRATE_SIZE.y / 2.0
	_body.add_child(crate)
	for x in [-0.28, 0.28]:  # two straps round the crate
		var band = MeshInstance3D.new()
		var band_mesh = BoxMesh.new()
		band_mesh.size = Vector3(0.09, CRATE_SIZE.y + 0.03, CRATE_SIZE.z + 0.03)
		band.mesh = band_mesh
		band.material_override = strap
		band.position = Vector3(x, CRATE_SIZE.y / 2.0, 0)
		_body.add_child(band)
	var stripe = MeshInstance3D.new()  # a bright band so it reads as a pickup from above
	var stripe_mesh = BoxMesh.new()
	stripe_mesh.size = Vector3(CRATE_SIZE.x + 0.02, 0.1, CRATE_SIZE.z + 0.02)
	stripe.mesh = stripe_mesh
	stripe.material_override = cloth
	stripe.position.y = CRATE_SIZE.y * 0.62
	_body.add_child(stripe)

	_chute = Node3D.new()
	_chute.name = "Parachute"
	_chute.position.y = 3.2
	_body.add_child(_chute)
	var canopy = MeshInstance3D.new()
	var canopy_mesh = SphereMesh.new()
	canopy_mesh.radius = 1.6
	canopy_mesh.height = 1.2
	canopy_mesh.is_hemisphere = true
	canopy_mesh.radial_segments = 12
	canopy_mesh.rings = 4
	canopy.mesh = canopy_mesh
	canopy.material_override = cloth
	_chute.add_child(canopy)
	for i in range(4):
		var angle = TAU * (i + 0.5) / 4.0
		var rim = Vector3(cos(angle), 0, sin(angle)) * 1.5
		var anchor = Vector3(0, -3.2 + CRATE_SIZE.y, 0)
		var line = MeshInstance3D.new()
		var line_mesh = CylinderMesh.new()
		line_mesh.top_radius = 0.015
		line_mesh.bottom_radius = 0.015
		line_mesh.height = rim.distance_to(anchor)
		line_mesh.radial_segments = 4
		line.mesh = line_mesh
		line.material_override = cord
		_chute.add_child(line)
		line.position = (rim + anchor) / 2.0
		line.basis = _basis_along(anchor - rim)

	var beacon = MeshInstance3D.new()
	beacon.name = "Beacon"
	var beacon_mesh = CylinderMesh.new()
	beacon_mesh.top_radius = 0.05
	beacon_mesh.bottom_radius = 0.3
	beacon_mesh.height = BEACON_HEIGHT
	beacon_mesh.radial_segments = 8
	beacon.mesh = beacon_mesh
	_beacon_material = StandardMaterial3D.new()
	_beacon_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beacon_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# mixed, not added: an additive beam washes out to white over pale sand
	_beacon_material.albedo_color = Color(1.0, 0.55, 0.1, 0.5)
	beacon.material_override = _beacon_material
	beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beacon.position.y = BEACON_HEIGHT / 2.0
	beacon.visible = false
	add_child(beacon)


static func _basis_along(direction):
	"""a basis whose y axis points along direction, for a cylinder from one point to another"""
	var y = direction.normalized()
	var x = y.cross(Vector3.FORWARD)
	if x.length() < 0.01:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	return Basis(x, y, x.cross(y))
