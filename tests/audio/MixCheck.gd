extends Node

# Checks the mix (default_bus_layout.tres, data/sounds/mix.json, WarSounds.gd): a limiter on
# the master, music and ambience ducking under the effects, effects ducking under voices, far
# sounds through the muffled EffectsFar bus (which still follows the Effects slider), and in a
# crowd of sounds the quiet, unimportant ones dropped while big explosions always get through.
# Usage:
#   godot --headless --path . res://tests/audio/MixCheck.tscn
# Exits with 1 on a failure.

const WarSounds = preload("res://source/match/environment/WarSounds.gd")

var _failures = []


func _ready():
	_expect(_effect(&"Master", "AudioEffectHardLimiter") != null, "the master bus has a limiter")
	var music_duck = _effect(&"Music", "AudioEffectCompressor")
	_expect(music_duck != null and music_duck.sidechain == &"Effects", "music ducks under battle")
	var ambience_duck = _effect(&"Ambience", "AudioEffectCompressor")
	_expect(
		ambience_duck != null and ambience_duck.sidechain == &"Effects",
		"ambience ducks under battle"
	)
	var effects_duck = _effect(&"Effects", "AudioEffectCompressor")
	_expect(
		effects_duck != null and effects_duck.sidechain == &"Voices", "effects duck under voices"
	)
	var far = AudioServer.get_bus_index(&"EffectsFar")
	_expect(far != -1, "there is a bus for far sounds")
	_expect(far == -1 or AudioServer.get_bus_send(far) == &"Effects", "it feeds the Effects bus")
	_expect(_effect(&"EffectsFar", "AudioEffectLowPassFilter") != null, "and muffles them")
	_expect(far > AudioServer.get_bus_index(&"Effects"), "after Effects, so sends work")

	var war_sounds = WarSounds.new()
	add_child(war_sounds)
	war_sounds.set_process(false)  # the listener stays at the origin
	war_sounds.play("cannon", Vector3(1, 0, 0))
	_expect(_bus_of(war_sounds, "cannon") == &"Effects", "a shot nearby is heard clearly")
	war_sounds.play("rocket", Vector3(28, 0, 0))
	_expect(_bus_of(war_sounds, "rocket") == &"EffectsFar", "a shot far off is muffled")
	war_sounds.play("mg", Vector3(2, 0, 0), 1.0, false)
	_expect(_bus_of(war_sounds, "mg") == &"EffectsFar", "a fight in the fog is muffled")

	# a crowd: a handful of loud sounds at once, then quiet ones
	war_sounds._recent.clear()
	for kind in ["heavy_cannon", "explosion_small", "missile", "impact_armor", "rifle", "impact"]:
		war_sounds.play(kind, Vector3(0.5, 0, 0))
	var masked = war_sounds.masked_count
	_expect(
		not war_sounds.play("impact_soft", Vector3(20, 0, 0)),
		"in a crowd a quiet impact far off is dropped"
	)
	_expect(war_sounds.masked_count == masked + 1, "and counted as masked")
	_expect(
		war_sounds.play("explosion_large", Vector3(20, 0, 0)), "a big explosion always gets through"
	)

	for failure in _failures:
		print("FAIL: ", failure)
	print("MixCheck: {0}".format(["ok" if _failures.is_empty() else "FAILED"]))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _effect(bus_name, type_name):
	var bus = AudioServer.get_bus_index(bus_name)
	if bus == -1:
		return null
	for i in range(AudioServer.get_bus_effect_count(bus)):
		var effect = AudioServer.get_bus_effect(bus, i)
		if effect.is_class(type_name):
			return effect
	return null


func _bus_of(war_sounds, kind):
	for voice in war_sounds._voices:
		if war_sounds._voice_kinds.get(voice) == kind:
			return voice.bus
	return &""


func _expect(condition, what):
	if not condition:
		_failures.append(what)
