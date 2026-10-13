extends Node

# Checks the ambient bed (source/match/environment/AmbientBed.gd): every loop loads, the bed
# follows the city tier, the threat layers follow the music's state machine on a simulated
# clock (calm, a stray hit, a sustained fight, quiet again), low oil brings a quiet tension
# layer, and the layers really fade and start playing. Usage:
#   godot --headless --path . res://tests/audio/AmbientBedCheck.tscn
# Exits with 1 on a failure.

const AmbientBed = preload("res://source/match/environment/AmbientBed.gd")

var _failures = []


func _ready():
	var bed = AmbientBed.new()
	add_child(bed)
	bed.set_process(false)  # the check drives it
	for layer in ["tier_1", "tier_2", "tier_3", "tension", "battle"]:
		_expect(layer in bed._players, layer + " loads")
		_expect(
			bed._players.get(layer) != null and bed._players[layer].bus == &"Ambience",
			layer + " is on the Ambience bus"
		)

	# the tier bed follows the city
	bed.update_targets("CALM", 0.0, 1, 100)
	_expect(
		bed.targets["tier_1"] > 0.0 and bed.targets["tier_2"] == 0.0,
		"a frontier city hears the frontier bed"
	)
	_expect(
		bed.targets["tension"] == 0.0 and bed.targets["battle"] == 0.0, "calm has no threat layers"
	)
	bed.update_targets("CALM", 0.0, 2, 100)
	_expect(
		bed.targets["tier_2"] > 0.0 and bed.targets["tier_1"] == 0.0,
		"an industrial city hears the industrial bed"
	)
	bed.update_targets("CALM", 0.0, 5, 100)
	_expect(bed.targets["tier_3"] > 0.0, "a tier past the last bed keeps the highest bed")

	# the threat layers follow MusicPlayer's own state machine
	var music = MusicPlayer
	var t = 5000.0
	music._start_match(self, t)
	_follow(bed, music, t, 2)
	var calm_bed = bed.targets["tier_2"]
	music.register_combat(music.HEAT_HIT, t + 1.0)
	_follow(bed, music, t + 1.0, 2)
	_expect(
		bed.music_state == "TENSION" and bed.targets["tension"] > 0.0,
		"a hit brings the tension layer"
	)
	_expect(bed.targets["tier_2"] < calm_bed, "the tier bed steps back under tension")
	for i in range(20):
		music.register_combat(music.HEAT_HIT, t + 2.0 + i * 0.5)
	_follow(bed, music, t + 12.0, 2)
	_expect(
		bed.music_state == "BATTLE" and bed.targets["battle"] > 0.0,
		"a sustained fight brings the battle layer"
	)
	var hot = bed.targets["battle"]
	music._update_state(t + 17.0)
	_follow(bed, music, t + 17.0, 2)
	_expect(bed.targets["battle"] < hot, "the battle layer eases as the fighting cools")
	music._update_state(t + 40.0)
	_follow(bed, music, t + 40.0, 2)
	_expect(
		bed.music_state == "CALM" and bed.targets["battle"] == 0.0, "quiet brings the calm bed back"
	)
	_expect(is_equal_approx(bed.targets["tier_2"], calm_bed), "at its calm level")
	music._leave_match()

	# low oil
	bed.update_targets("CALM", 0.0, 2, 3)
	_expect(bed.targets["tension"] > 0.0, "low oil brings a quiet tension layer")
	_expect(bed.targets["tension"] < bed._full_gains["tension"] * 0.5, "quieter than a real threat")
	bed.update_targets("CALM", 0.0, 1, 3)
	_expect(bed.targets["tension"] == 0.0, "not on the frontier, where oil does not matter yet")

	# zoomed out the bed carries more of the mix
	bed.update_targets("CALM", 0.0, 1, 100, 0.0)
	var close = bed.targets["tier_1"]
	bed.update_targets("CALM", 0.0, 1, 100, 1.0)
	_expect(bed.targets["tier_1"] > close, "the bed is louder zoomed out")

	# fading: a layer starts playing as it fades in and stops once faded out
	bed.update_targets("BATTLE", 1.0, 1, 100)
	for i in range(10):
		bed._fade(0.25)
	_expect(bed._players["battle"].playing, "the battle layer plays")
	_expect(is_equal_approx(bed._gains["battle"], bed.targets["battle"]), "and reaches its level")
	bed.update_targets("CALM", 0.0, 1, 100)
	bed._fade(0.25)
	_expect(bed._gains["battle"] > 0.0, "it fades out instead of cutting off")
	for i in range(40):
		bed._fade(0.25)
	_expect(not bed._players["battle"].playing, "and stops when silent")

	for failure in _failures:
		print("FAIL: ", failure)
	print("AmbientBedCheck: {0}".format(["ok" if _failures.is_empty() else "FAILED"]))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _follow(bed, music, at_s, a_tier):
	music._update_state(at_s)
	bed.update_targets(music.state_name(), music.intensity(at_s), a_tier, 100)


func _expect(condition, what):
	if not condition:
		_failures.append(what)
