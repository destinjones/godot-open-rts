extends Button

# A button with a rich tooltip (Tooltips.panel), made when the tooltip opens so it says
# what is true right now. tip_maker returns the BBCode; tooltip_text must stay non-empty
# for Godot to open a tooltip at all, and is the plain text used when there is no maker.

const Tooltips = preload("res://source/match/hud/Tooltips.gd")

var tip_maker = null  # a Callable returning BBCode


func _make_custom_tooltip(for_text):
	var text = tip_maker.call() if tip_maker is Callable and tip_maker.is_valid() else for_text
	return Tooltips.panel(text)
