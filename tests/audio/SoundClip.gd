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
#   unit-presence: a few tanks, a squad and a helicopter idling, driving off, and stopping.
#   combat: two mixed armies meet: rifles, machine guns, cannon, artillery, rockets, impacts
#           on armour and infantry, and deaths of every size.

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
	"unit-presence":
	[
		[
			0.0,
			{
				"caption": "parked: diesels idle, rotor turns",
				"spawn": ["tank", "tank", "heavy_tank", "militia", "militia", "helicopter"]
			}
		],
		[8.0, {"caption": "moving off: engines, tracks, footsteps", "move": [26.0, 6.0]}],
		[17.0, {"caption": "stopped again", "stop": true}],
		[24.0, {"caption": "radio chatter", "chatter": true}],
		[30.0, {"end": true}],
	],
	"combat":
	[
		[0.0, {"caption": "two armies close in", "battle": true}],
		[45.0, {"end": true}],
	],
}
const ARMIES = [
	["tank", "heavy_tank", "militia", "militia", "raider", "artillery", "missile_truck"],
	["tank", "battle_tank", "militia", "militia", "raider", "helicopter", "scout_buggy"],
]

const GameData = preload("res://source/data-model/GameData.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")

var _timeline = []
var _clock = 0.0
var _bed = null
var _bed_state = {"tier": 1, "state": "CALM", "intensity": 0.0}
var _caption = null
var _units = []
var _spot = Vector3(60.0, 0.0, 60.0)
var _camera = null
var _soundscape = null


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
	_soundscape = match_node.find_child("Soundscape", true, false)
	_bed = match_node.find_child("AmbientBed", true, false)
	if _bed != null and without != "AmbientBed":
		_bed.set_process(false)  # the timeline drives it
	else:
		_bed = null
	var camera = get_viewport().get_camera_3d()
	_camera = camera
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
		if step.get("battle", false):
			_battle()
		if "spawn" in step:
			_spawn(step["spawn"])
		if "move" in step:
			for unit in _units:
				if is_instance_valid(unit):
					var to = Vector3(step["move"][0], 0.0, step["move"][1])
					unit.action = Moving.new(unit.global_position + to)
		if step.get("stop", false):
			for unit in _units:
				if is_instance_valid(unit):
					unit.action = null
		if step.get("chatter", false) and _soundscape != null:
			_soundscape._chatter_in = 0.0
	var alive = _units.filter(func(unit): return is_instance_valid(unit) and unit.is_inside_tree())
	if not alive.is_empty():  # the camera follows them
		var centre = Vector3.ZERO
		for unit in alive:
			centre += unit.global_position
		_camera.set_position_safely(centre / alive.size())
	if _bed != null:
		_bed.update_targets(_bed_state["state"], _bed_state["intensity"], _bed_state["tier"], 100)
		_bed._fade(delta)


func _spawn(ids):
	var human = get_tree().get_nodes_in_group("players")[0]
	for i in range(ids.size()):
		var unit = load(GameData.unit_by_id(ids[i])["scene"]).instantiate()
		var offset = Vector3((i % 3) * 3.0 - 3.0, 0.0, int(i / 3.0) * 3.5)
		MatchSignals.setup_and_spawn_unit.emit(unit, Transform3D(Basis(), _spot + offset), human)
		_units.append(unit)
	_camera.set_size_safely(16.0)


func _battle():
	var players = get_tree().get_nodes_in_group("players")
	for side in range(2):
		var ids = ARMIES[side]
		for i in range(ids.size()):
			var unit = load(GameData.unit_by_id(ids[i])["scene"]).instantiate()
			var offset = Vector3(
				(i % 4) * 2.5 - 4.0, 0.0, (side * 2 - 1) * (10.0 + int(i / 4.0) * 2.5)
			)
			MatchSignals.setup_and_spawn_unit.emit(
				unit, Transform3D(Basis(), _spot + offset), players[side]
			)
			_units.append(unit)
	var diplomacy = get_tree().current_scene.find_child("Diplomacy", true, false)
	if diplomacy != null:
		diplomacy.declare_war(players[0], players[1])
	for unit in _units:
		unit.action = Moving.new(_spot)
	_camera.set_size_safely(20.0)
