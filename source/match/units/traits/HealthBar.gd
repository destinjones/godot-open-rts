@tool
extends Node3D

const BAR_AUTO_VISIBILITY_DURATION = 2.0
# hp just lost stays on the bar as a pale chunk that drains away, so a hit reads at a glance
const DAMAGE_CHUNK_COLOR = Color(1.0, 0.95, 0.7)
const DAMAGE_CHUNK_HOLD_S = 0.25
const DAMAGE_CHUNK_DRAIN_PER_S = 0.9  # of the full bar

@export var size = Vector2(200, 20):
	set(value):
		size = value
		find_child("ActualBar").texture.width = size.x
		find_child("ActualBar").texture.height = size.y

var _bar_value_initialized = false
var _value = 1.1
var _chunk_end = 1.1
var _chunk_hold = 0.0
var _health_color = Color.GREEN
var _empty_color = Color.DIM_GRAY

@onready var _unit = get_parent()
@onready var _actual_bar = find_child("ActualBar")
@onready var _visibility_timer = find_child("Timer")


func _ready():
	if Engine.is_editor_hint():
		return
	hide()
	var colors = _actual_bar.texture.gradient.colors
	_health_color = colors[0]
	_empty_color = colors[colors.size() - 1]
	set_process(false)
	_recalulate_bar_value()
	_unit.selected.connect(_on_unit_selected)
	_unit.deselected.connect(_on_unit_deselected)
	_unit.hp_changed.connect(_on_hp_changed)
	_visibility_timer.timeout.connect(_on_visibility_timer_timeout)


func _process(delta):
	if _chunk_hold > 0.0:
		_chunk_hold -= delta
		return
	_chunk_end = max(_value, _chunk_end - DAMAGE_CHUNK_DRAIN_PER_S * delta)
	_apply_offsets()
	if _chunk_end <= _value:
		set_process(false)


func _recalulate_bar_value():
	if _unit.hp == null or _unit.hp_max == null:
		return
	var old_value = _value
	var new_value = float(_unit.hp) / _unit.hp_max
	new_value = new_value if not is_equal_approx(new_value, 1.0) else 1.1  # fixing 1px gap
	_value = new_value
	if _bar_value_initialized and new_value < old_value and _unit.visible:
		_chunk_end = max(_chunk_end, old_value)
		_chunk_hold = DAMAGE_CHUNK_HOLD_S
		set_process(true)
	else:
		_chunk_end = max(_chunk_end, new_value) if is_processing() else new_value
	_apply_offsets()
	if _bar_value_initialized and old_value != new_value:
		_show_for_a_while()
	_bar_value_initialized = true


func _apply_offsets():
	# constant interpolation: health colour from 0, the lost-hp chunk from _value, then empty
	var gradient = _actual_bar.texture.gradient
	if _chunk_end > _value:
		gradient.offsets = PackedFloat32Array([0.0, _value, _chunk_end])
		gradient.colors = PackedColorArray([_health_color, DAMAGE_CHUNK_COLOR, _empty_color])
	else:
		gradient.offsets = PackedFloat32Array([0.0, _value])
		gradient.colors = PackedColorArray([_health_color, _empty_color])


func _show_for_a_while():
	if visible and _visibility_timer.is_stopped():
		return  # shown because the unit is selected
	show()
	# restart on every hit: a unit under steady fire keeps its bar up
	_visibility_timer.start(BAR_AUTO_VISIBILITY_DURATION)


func _on_unit_selected():
	_visibility_timer.stop()
	show()


func _on_unit_deselected():
	hide()


func _on_hp_changed():
	_recalulate_bar_value()


func _on_visibility_timer_timeout():
	hide()
