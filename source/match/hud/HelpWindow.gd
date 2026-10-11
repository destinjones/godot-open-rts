extends PanelContainer

# The in-game manual (F1): a list of topics on the left, the explanation on the right.
# Texts are translation keys HELP_<TOPIC>_TITLE / HELP_<TOPIC>_BODY in guide.csv.
# The search box over the list (Ctrl+F) keeps the topics whose title or text holds every
# word typed, title matches first, and marks the words in the text. Hints and tutorial
# steps open a topic with show_topic (Guide.HINT_TOPICS, the "topic" of a tutorial step).

const TOPICS = [
	"BASICS",
	"CONSTRUCTORS",
	"AUTO_EXPAND",
	"HELPER",
	"RESOURCES",
	"SUPPLY_LINES",
	"DELIVERY_JOBS",
	"STORAGE",
	"TRAINS",
	"ROADS",
	"POWER",
	"CITY_TIERS",
	"TRADE",
	"COMBAT",
	"COMMANDS",
	"AIRCRAFT",
	"LIMITS",
	"CITY_CENTRES",
	"TESTING",
]

const MARK_COLOR = "#f2a93b55"

var search_box = LineEdit.new()
var _topics = ItemList.new()
var _body = RichTextLabel.new()
var _shown = TOPICS.duplicate()  # the topics in the list, in order: all, or the matches
var _words = []  # the search words, lower case
var _plain = {}  # topic -> its title and text without BBCode, lower case, for the search


func _ready():
	name = "HelpWindow"
	custom_minimum_size = Vector2(820, 520)
	var margin = MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)
	var box = VBoxContainer.new()
	margin.add_child(box)
	var header = HBoxContainer.new()
	box.add_child(header)
	var title = Label.new()
	title.text = tr("HELP_TITLE")
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close = Button.new()
	close.text = tr("HELP_CLOSE")
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(hide)
	header.add_child(close)
	var split = HBoxContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 12)
	box.add_child(split)
	var left = VBoxContainer.new()
	left.custom_minimum_size = Vector2(250, 0)
	split.add_child(left)
	search_box.name = "HelpSearch"
	search_box.placeholder_text = tr("HELP_SEARCH")
	search_box.tooltip_text = tr("HELP_SEARCH_TOOLTIP")
	search_box.clear_button_enabled = true
	search_box.text_changed.connect(search)
	left.add_child(search_box)
	_topics.name = "HelpTopics"
	_topics.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_topics.focus_mode = Control.FOCUS_NONE
	_topics.item_selected.connect(show_topic_at)
	left.add_child(_topics)
	_fill_list()
	_body.bbcode_enabled = true
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_font_size_override("normal_font_size", 16)
	_body.add_theme_font_size_override("bold_font_size", 16)
	split.add_child(_body)
	show_topic("BASICS")
	hide()


func _unhandled_key_input(event):
	if not visible or not event.pressed:
		return
	if event.keycode == KEY_ESCAPE:
		search_box.release_focus()
		hide()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_F and event.ctrl_pressed:
		search_box.grab_focus()
		search_box.select_all()
		get_viewport().set_input_as_handled()


func _input(event):
	# Esc while typing a search closes the manual, as it does anywhere else in it
	if visible and search_box.has_focus() and event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			search_box.release_focus()
			hide()
			get_viewport().set_input_as_handled()


func _process(_delta):
	if visible:
		position = ((get_viewport_rect().size - size) / 2.0).round()


func show_topic(topic):
	"""opens a topic; a search that would hide it is cleared"""
	if not topic in _shown:
		search_box.text = ""
		search("")
	show_topic_at(max(0, _shown.find(topic)))


func shown_topics():
	return _shown.duplicate()


func search(query):
	"""keeps the topics whose title or text holds every word of the query"""
	_words = Array(query.to_lower().split(" ", false))
	var current = _current_topic()
	if _words.is_empty():
		_shown = TOPICS.duplicate()
	else:
		var in_title = []
		var in_text = []
		for topic in TOPICS:
			var plain = _plain_text(topic)
			if not _words.all(func(word): return word in plain[1]):
				continue
			if _words.all(func(word): return word in plain[0]):
				in_title.append(topic)
			else:
				in_text.append(topic)
		_shown = in_title + in_text
	_fill_list()
	if _shown.is_empty():
		_body.text = tr("HELP_SEARCH_NONE").format([query.strip_edges()])
		return
	show_topic_at(max(0, _shown.find(current)) if _words.is_empty() else 0)


func show_topic_at(index):
	if index < 0 or index >= _shown.size():
		return
	_topics.select(index)
	var topic = _shown[index]
	_body.text = "[b]{0}[/b]\n\n{1}".format(
		[_marked(tr("HELP_%s_TITLE" % topic)), _marked(tr("HELP_%s_BODY" % topic))]
	)
	_body.scroll_to_line(0)


func _current_topic():
	var selected = _topics.get_selected_items()
	return _shown[selected[0]] if not selected.is_empty() and selected[0] < _shown.size() else ""


func _fill_list():
	_topics.clear()
	for topic in _shown:
		_topics.add_item(tr("HELP_%s_TITLE" % topic))


func _plain_text(topic):
	"""[title, title + text] without BBCode, lower case"""
	if not topic in _plain:
		var tags = RegEx.create_from_string("\\[[^\\]]*\\]")
		var title = tags.sub(tr("HELP_%s_TITLE" % topic), "", true).to_lower()
		var body = tags.sub(tr("HELP_%s_BODY" % topic), "", true).to_lower()
		_plain[topic] = [title, title + "\n" + body]
	return _plain[topic]


func _marked(text):
	"""the search words marked in BBCode text, leaving its tags alone"""
	if _words.is_empty():
		return text
	var escaped = _words.map(func(word): return _regex_escape(word))
	var words = RegEx.create_from_string("(?i)(" + "|".join(escaped) + ")")
	var tags = RegEx.create_from_string("\\[[^\\]]*\\]")
	var result = ""
	var from = 0
	for tag in tags.search_all(text):
		result += _mark_words(words, text.substr(from, tag.get_start() - from))
		result += tag.get_string()
		from = tag.get_end()
	return result + _mark_words(words, text.substr(from))


func _mark_words(words, plain):
	return words.sub(plain, "[bgcolor=%s]$1[/bgcolor]" % MARK_COLOR, true)


static func _regex_escape(word):
	var escaped = ""
	for character in word:
		escaped += ("\\" + character) if character in "\\.^$|?*+()[]{}" else character
	return escaped
