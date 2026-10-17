extends Node

# One match moment under every weather and hour asked for, to review the atmosphere.
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --resolution 1600x900 \
#     res://tests/screenshots/WeatherShots.tscn -- --out=/tmp/weather \
#     --weathers=clear,rain,sandstorm --hours=7,13,18.8,23 --size=22 --hide_hud
# Saves <weather>_<hour>.png. --settle=<frames> lets particles fill the view before each shot.

var _args = {}


func _ready():
	for arg in OS.get_cmdline_user_args():
		var parts = arg.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else ""
	var out_dir = _args.get("out", "user://weather")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var match_node = load(_args.get("scene", "res://tests/manual/TestDesert.tscn")).instantiate()
	match_node.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(match_node)
	Engine.time_scale = 4.0
	Engine.max_physics_steps_per_frame = 32
	await _frames(int(_args.get("warmup", "200")))
	Engine.time_scale = 1.0
	Engine.max_physics_steps_per_frame = 8
	get_tree().paused = true  # the units hold still; the sky and particles keep going
	var atmosphere = match_node.find_child("Atmosphere", true, false)
	atmosphere.process_mode = Node.PROCESS_MODE_ALWAYS
	atmosphere.random_weather = false
	var clock = atmosphere.get_time_of_day()
	clock.running = false  # each shot holds its hour
	if _args.has("hide_hud"):
		for layer in match_node.find_children("*", "CanvasLayer", true, false):
			if layer.name != "LookGrade":
				layer.visible = false
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(float(_args.get("size", "22")))
	var player = get_tree().get_nodes_in_group("players")[0]
	var depots = player.get_node("Logistics").get_depots()
	if not depots.is_empty():
		camera.set_position_safely(depots[0].global_position)
	for weather in _args.get("weathers", "clear").split(","):
		atmosphere.set_weather_immediately(weather)
		for hour_text in _args.get("hours", "13").split(","):
			clock.set_hour(float(hour_text))
			await _frames(int(_args.get("settle", "40")))
			var path = "{0}/{1}_{2}.png".format([out_dir, weather, hour_text])
			get_viewport().get_texture().get_image().save_png(path)
			print("saved ", path)
	get_tree().quit()


func _frames(count):
	for i in range(count):
		await get_tree().process_frame
