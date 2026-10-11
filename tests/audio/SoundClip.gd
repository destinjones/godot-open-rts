extends Node

# Records a short clip of the game's sound for a pull request, so a change to the mix can be
# heard, not just described. It plays a scripted timeline on a test map and Godot's movie
# maker writes picture and sound to an AVI. Usage (needs a renderer, e.g. under xvfb-run):
#   godot --path . --write-movie clip.avi --fixed-fps 30 res://tests/audio/SoundClip.tscn \
#       -- --clip=ambient-bed [--without=AmbientBed]
#   ffmpeg -i clip.avi -c:v libx264 -c:a aac clip.mp4
# --without frees a node of the soundscape by name, for the "before" half of a comparison.
# The music bus is muted: the clips are about the world's sound.
#
# Clips:
#   ambient-bed: the tier beds (frontier, industrial, electric), then a fight brewing and
#                breaking out over the electric city, and the calm coming back.

const CLIPS = {
	# [game second, what happens]
	"ambient-bed":
	[
		[0.0, {"caption": "frontier, calm", "tier": 1, "state": "CALM", "intensity": 0.0}],
		[7.0, {"caption": "industrial, calm", "tier": 2}],
		[14.0, {"caption": "electric, calm", "tier": 3}],
		[21.0, {"caption": "a shot nearby: tension", "state": "TENSION", "intensity": 0.2}],
		[28.0, {"caption": "battle", "state": "BATTLE", "intensity": 0.7}],
		[32.0, {"intensity": 1.0}],
		[38.0, {"caption": "the fight cools", "intensity": 0.4}],
		[42.0, {"caption": "quiet again", "state": "CALM", "intensity": 0.0}],
		[52.0, {"end": true}],
	],
}

var _timeline = []
var _clock = 0.0
var _bed = null
var _bed_state = {"tier": 1, "state": "CALM", "intensity": 0.0}
var _caption = null


func _ready():
	set_process(false)  # until the match is set up
	var args = {}
	for arg in OS.get_cmdline_user_args():
		var parts = arg.trim_prefix("--").split("=", true, 1)
		args[parts[0]] = parts[1] if parts.size() > 1 else ""
	_timeline = CLIPS.get(args.get("clip", "ambient-bed"), []).duplicate()
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Music"), true)
	var match_node = load("res://tests/manual/TestDesert.tscn").instantiate()
	add_child(match_node)
	await get_tree().process_frame
	await get_tree().process_frame
	var without = args.get("without", "")
	if without != "":
		var node = match_node.find_child(without, true, false)
		if node != null:
			node.queue_free()
	_bed = match_node.find_child("AmbientBed", true, false)
	if _bed != null and without != "AmbientBed":
		_bed.set_process(false)  # the timeline drives it
	else:
		_bed = null
	var camera = get_viewport().get_camera_3d()
	var players = get_tree().get_nodes_in_group("players")
	var units = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == players[0]
	)
	if not units.is_empty():
		camera.set_position_safely(units[0].global_position)
	camera.set_size_safely(30.0)
	_caption = Label.new()
	_caption.position = Vector2(24, 24)
	_caption.add_theme_font_size_override("font_size", 28)
	var layer = CanvasLayer.new()
	layer.layer = 100
	layer.add_child(_caption)
	add_child(layer)
	set_process(true)


func _process(delta):
	if _timeline.is_empty() and _clock > 0.0:
		return
	_clock += delta
	while not _timeline.is_empty() and _timeline[0][0] <= _clock:
		var step = _timeline.pop_front()[1]
		if step.get("end", false):
			print("SoundClip: done at {0} s".format([snapped(_clock, 0.1)]))
			get_tree().quit()
			return
		if "caption" in step:
			_caption.text = step["caption"] + ("" if _bed != null else " (without the bed)")
		for key in ["tier", "state", "intensity"]:
			if key in step:
				_bed_state[key] = step[key]
	if _bed != null:
		_bed.update_targets(_bed_state["state"], _bed_state["intensity"], _bed_state["tier"], 100)
		_bed._fade(delta)
