extends Node

# The match clock: dawn, day, dusk and night, read from data/time_of_day.json.
#
# Atmosphere.gd owns this node and asks it every frame for the light of the hour, which it
# multiplies into what the weather and the look (Look.gd) set:
#   time_of_day.get_hour() -> float                   # 0..24
#   time_of_day.get_phase() -> StringName             # &"dawn", &"day", &"dusk", &"night"
#   time_of_day.phase_changed                         # signal(phase: StringName)
#   time_of_day.get_light() -> Dictionary             # the blended key, see the json
#   time_of_day.set_hour(hour)                        # jump the clock (screenshots, missions)
#   time_of_day.running = false                       # hold the hour
# The keys are a loop over 24 hours; values between two keys blend linearly. The sun and the
# moon are the same light: they swap places in twilight, while the light is dim.
# Night hours pass faster ("night_speed") so a match spends most of its time in daylight.

signal phase_changed(phase)

const DATA_PATH = "res://data/time_of_day.json"
const BLENDED_KEYS = ["height", "energy", "ambient", "exposure", "vision"]
const BLENDED_COLORS = ["color", "ambient_tint", "haze_tint"]
const NEUTRAL_LIGHT = {
	"height": 1.0,
	"azimuth": 0.0,
	"energy": 1.0,
	"color": Color.WHITE,
	"ambient": 1.0,
	"exposure": 1.0,
	"ambient_tint": Color.WHITE,
	"haze_tint": Color.WHITE,
	"vision": 1.0,
}

var enabled = true  # false: no clock at all, the look's noon light stays (json "enabled")
var running = true  # false: the hour holds still
var _hour = 10.0
var _day_seconds_per_hour = 40.0
var _night_speed = 1.0
var _night_hours = Vector2(20.0, 5.0)
var _keys = []
var _light = NEUTRAL_LIGHT.duplicate()
var _phase = &"day"


func _ready():
	_load(DATA_PATH)
	_update_light()
	_phase = _phase_at(_hour)


func _process(delta):
	if not enabled or not running or _keys.is_empty():
		return
	var speed = _night_speed if is_night() else 1.0
	_hour = fposmod(_hour + delta * speed / _day_seconds_per_hour, 24.0)
	_update_light()
	var phase = _phase_at(_hour)
	if phase != _phase:
		_phase = phase
		phase_changed.emit(phase)


func get_hour():
	return _hour


func get_phase():
	return _phase


func is_night():
	return _in_range(_hour, _night_hours)


func get_light():
	return _light


func set_hour(hour):
	_hour = fposmod(float(hour), 24.0)
	_update_light()
	var phase = _phase_at(_hour)
	if phase != _phase:
		_phase = phase
		phase_changed.emit(phase)


func _load(path):
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		enabled = false
		return
	var data = JSON.parse_string(file.get_as_text())
	if not data is Dictionary or data.get("keys", []).size() < 2:
		push_warning("time_of_day.json: needs at least two keys, the clock is off")
		enabled = false
		return
	enabled = bool(data.get("enabled", true))
	_hour = fposmod(float(data.get("start_hour", 10.0)), 24.0)
	_night_speed = max(float(data.get("night_speed", 1.0)), 0.1)
	var night = data.get("night_hours", [20.0, 5.0])
	_night_hours = Vector2(float(night[0]), float(night[1]))
	var night_length = fposmod(_night_hours.y - _night_hours.x, 24.0)
	var day_equivalent_hours = (24.0 - night_length) + night_length / _night_speed
	_day_seconds_per_hour = max(float(data.get("day_length_s", 960.0)), 1.0) / day_equivalent_hours
	for key in data["keys"]:
		var parsed = NEUTRAL_LIGHT.duplicate()
		parsed["hour"] = float(key["hour"])
		parsed["light"] = StringName(key.get("light", "sun"))
		for name in BLENDED_KEYS + ["azimuth"]:
			parsed[name] = float(key.get(name, parsed[name]))
		for name in BLENDED_COLORS:
			var rgb = key.get(name, [1.0, 1.0, 1.0])
			parsed[name] = Color(rgb[0], rgb[1], rgb[2])
		_keys.append(parsed)
	_keys.sort_custom(func(a, b): return a["hour"] < b["hour"])
	if not enabled:
		_keys = []


func _update_light():
	if _keys.is_empty():
		_light = NEUTRAL_LIGHT.duplicate()
		return
	# the last key before the hour and the first after it, wrapping around midnight
	var next_index = 0
	while next_index < _keys.size() and _keys[next_index]["hour"] <= _hour:
		next_index += 1
	var after = _keys[next_index % _keys.size()]
	var before = _keys[(next_index - 1 + _keys.size()) % _keys.size()]
	var span = fposmod(after["hour"] - before["hour"], 24.0)
	var weight = 0.0 if span <= 0.0 else fposmod(_hour - before["hour"], 24.0) / span
	var light = {"light": before["light"] if weight < 0.5 else after["light"]}
	for name in BLENDED_KEYS:
		light[name] = lerp(before[name], after[name], weight)
	for name in BLENDED_COLORS:
		light[name] = before[name].lerp(after[name], weight)
	light["azimuth"] = rad_to_deg(
		lerp_angle(deg_to_rad(before["azimuth"]), deg_to_rad(after["azimuth"]), weight)
	)
	_light = light


func _phase_at(hour):
	if _in_range(hour, _night_hours):
		return &"night"
	if hour < 12.0:
		return &"dawn" if hour < _night_hours.y + 2.0 else &"day"
	return &"dusk" if hour >= _night_hours.x - 2.0 else &"day"


static func _in_range(hour, hours):
	"""true when the hour lies in [hours.x, hours.y), which may wrap past midnight"""
	if hours.x <= hours.y:
		return hour >= hours.x and hour < hours.y
	return hour >= hours.x or hour < hours.y
