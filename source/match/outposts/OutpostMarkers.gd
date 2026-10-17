extends Node2D

# Outposts on the minimap: a ring in the owner's colour (grey while neutral) with a dot in
# the middle, filled in the capturer's colour while a capture is under way.

const Outpost = preload("res://source/match/outposts/Outpost.gd")
const REDRAW_S = 0.25

var outposts_system = null
var pixels_per_meter = 2.0

var _since_redraw = 0.0


func _process(delta):
	_since_redraw += delta
	if _since_redraw >= REDRAW_S:
		_since_redraw = 0.0
		queue_redraw()


func _draw():
	if outposts_system == null or not is_instance_valid(outposts_system):
		return
	for outpost in outposts_system.outposts:
		var at = Vector2(outpost.global_position.x, outpost.global_position.z) * pixels_per_meter
		var owner_color = (
			outpost.owner_player.color
			if outpost.owner_player != null and is_instance_valid(outpost.owner_player)
			else Outpost.NEUTRAL_COLOR.lightened(0.3)
		)
		draw_circle(at, 7.0, Color(0.05, 0.05, 0.05, 0.85))
		draw_arc(at, 5.5, 0.0, TAU, 20, owner_color, 2.5)
		if outpost.capturer != null and is_instance_valid(outpost.capturer):
			draw_arc(
				at,
				5.5,
				-PI / 2.0,
				-PI / 2.0 + TAU * outpost.progress,
				20,
				outpost.capturer.color,
				2.5
			)
		draw_circle(at, 2.2, owner_color)
