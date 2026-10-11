extends RefCounted

# Tutorials are data: data/tutorial/<name>.json lists the steps the Guide (Guide.gd) walks
# a player through, each ticked off by something the player does. Every match plays
# "standard" unless its MatchSettings name another script; the Tutorial button on the
# main menu starts "first_match", a short scripted match with its own map, rival and help
# rules. A script uses the play harness's format (tools/harness/scenarios/, see
# docs/testing/play-harness.md) for its match and for orders a step runs when it starts:
#
# {
#   "map": "plain_and_simple",                  map id, as in data/maps/
#   "players": [{"type": "human"}, {"type": "ai", "personality": "balanced",
#               "difficulty": "very_easy"}],
#   "rules": {"tutorial": true, "ai_assist": false, "auto_build": false},  see MatchRules
#   "start_pick_seconds": 600,                  time to place the city on the start screen
#   "steps": [
#     {"id": "BUILD_FACTORY",                   text: GUIDE_STEP_<id>_TITLE, GUIDE_STEP_<id>
#      "done_when": "factory_built",            see Guide.CONDITIONS
#      "topic": "COMBAT",                       the manual topic "Explain more" opens
#      "panel": "CityHud",                      (optional) a HUD panel to unfold
#      "on_start": [{"do": "give", "resources": {"iron": 60}}]}  harness orders
#   ]
# }
#
# Only "steps" is needed: the standard script has no match of its own.

const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const MatchRules = preload("res://source/data-model/MatchRules.gd")

const DIR = "res://data/tutorial/"
const STANDARD = "standard"
const FIRST_MATCH = "first_match"


static func load_script(script_name):
	"""the script's dictionary, or {} when there is no such file or it is broken"""
	var path = DIR + (script_name if script_name != "" else STANDARD) + ".json"
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func steps_of(script_name):
	"""the steps of a script, falling back to the standard ones"""
	var steps = load_script(script_name).get("steps", [])
	if steps.is_empty() and script_name != STANDARD:
		steps = load_script(STANDARD).get("steps", [])
	return steps


static func map_path_of(script):
	var map_id = script.get("map", "plain_and_simple")
	for scene_path in Constants.Match.MAPS:
		if Constants.Match.MAPS[scene_path].get("id") == map_id or scene_path == map_id:
			return scene_path
	return null


static func match_settings(script_name):
	"""MatchSettings for a script that brings its own match, or null"""
	var script = load_script(script_name)
	var map_path = map_path_of(script)
	if script.is_empty() or map_path == null:
		return null
	var settings = MatchSettings.new()
	settings.tutorial_script = script_name
	settings.start_pick_seconds = float(script.get("start_pick_seconds", 0.0))
	MatchRules.apply_preset(settings, MatchRules.PRESET_GUIDED)
	var rules = script.get("rules", {})
	for rule in MatchRules.RULES:
		settings.set(rule, bool(rules.get(rule, settings.get(rule))))
	var entries = script.get("players", [{"type": "human"}, {"type": "ai"}])
	for index in range(entries.size()):
		var entry = entries[index]
		var player_settings = PlayerSettings.new()
		if entry.get("type", "ai") == "human":
			player_settings.controller = Constants.PlayerType.HUMAN
			settings.visible_player = index
		else:
			player_settings.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
			player_settings.ai_personality = entry.get("personality", "balanced")
			player_settings.ai_difficulty = entry.get("difficulty", "normal")
		player_settings.color = Constants.Player.COLORS[index % Constants.Player.COLORS.size()]
		player_settings.faction = str(entry.get("faction", ""))
		settings.players.append(player_settings)
	return settings
