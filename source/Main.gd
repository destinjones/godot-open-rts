extends Control

@onready var _logos = find_child("Logos")


func _ready():
	FeatureFlags.remember_seen_hints = true  # see Guide.show_hint
	_logos.tree_exited.connect(
		get_tree().change_scene_to_file.bind("res://source/main-menu/Main.tscn")
	)
