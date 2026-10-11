extends Node2D

# Pings on the minimap (StarCraft II style), drawn as rings that grow and fade:
# - red where one of the player's units or buildings is hit by an enemy, at most one per
#   spot every few seconds, so a fight reads as one ping, not a storm,
# - yellow where the player Alt + clicks the minimap, to mark a spot.
# Lives in the minimap's viewport (hud/Minimap.gd), in minimap pixels.

const ATTACK_COLOR = Color(1.0, 0.3, 0.2)
const MARK_COLOR = Color(1.0, 0.85, 0.3)
const LIFE_S = 3.0
const PULSES = 3
const RADIUS_PX = 16.0
const ATTACK_CELL_M = 12.0  # hits within one cell of this size share a ping
const ATTACK_QUIET_S = 6.0  # a cell pings again only after this long

var pixels_per_meter = 2
var pings = []  # [{"at": Vector2 px, "color", "age": s}]; for tests

var _last_attack_ping_ms = {}  # cell -> ticks msec


func _ready():
	z_index = 10  # over the unit markers, which are added after this node
	MatchSignals.unit_damaged.connect(_on_unit_damaged)


func _process(delta):
	if pings.is_empty():
		return
	for entry in pings:
		entry["age"] += delta / max(Engine.time_scale, 0.001)
	pings = pings.filter(func(entry): return entry["age"] < LIFE_S)
	queue_redraw()


func ping(world_position: Vector3, color):
	var at = Vector2(world_position.x, world_position.z) * pixels_per_meter
	pings.append({"at": at, "color": color, "age": 0.0})
	queue_redraw()


func _draw():
	for entry in pings:
		var life = entry["age"] / LIFE_S
		for pulse in range(PULSES):
			var t = entry["age"] / LIFE_S * PULSES - pulse * 0.6
			if t < 0.0 or t > 1.0:
				continue
			var radius = 3.0 + RADIUS_PX * t
			var alpha = 1.0 - t * t
			draw_arc(entry["at"], radius, 0, TAU, 32, Color(0, 0, 0, alpha * 0.6), 5.0, true)
			draw_arc(entry["at"], radius, 0, TAU, 32, Color(entry["color"], alpha), 3.0, true)
		var dot_alpha = clamp((1.0 - life) / 0.3, 0.0, 1.0)
		draw_circle(entry["at"], 4.0, Color(0, 0, 0, dot_alpha * 0.6))
		draw_circle(entry["at"], 3.0, Color(entry["color"], dot_alpha))


func _on_unit_damaged(unit):
	if not unit.is_in_group("controlled_units"):
		return
	var attacker = unit.last_attacker_player
	if attacker == null or attacker == unit.player:
		return
	var position = unit.global_position
	var cell = Vector2i(floor(position.x / ATTACK_CELL_M), floor(position.z / ATTACK_CELL_M))
	var now_ms = Time.get_ticks_msec()
	if now_ms - _last_attack_ping_ms.get(cell, -1e9) < ATTACK_QUIET_S * 1000.0:
		return
	_last_attack_ping_ms[cell] = now_ms
	ping(position, ATTACK_COLOR)
