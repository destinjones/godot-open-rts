extends Node

@export_group("Game")
@export var show_logos_on_startup = true
@export var save_user_files_in_tmp = false

@export_group("Match")
@export var allow_resources_deficit_spending = false
@export var handle_match_end = true
@export var show_minimap = true
@export var allow_navigation_rebaking = true

@export_group("Match/Debug")
@export var frame_incrementer = false
@export var god_mode = false

# first-run state (hints seen, the intro card, the Play menu's last choices) is remembered
# in the options only in a real game, one started from its main scene (source/Main.gd sets
# this), so tests and the play harness never use it up
var remember_first_run = false
