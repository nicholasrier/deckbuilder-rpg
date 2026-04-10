extends Control
class_name RewardChoiceUI

signal reward_confirmed(reward: Dictionary)

const CARD_MIN_SIZE := Vector2(190, 190)
const GOLD := Color(1.0, 0.78, 0.22, 1.0)

var reward_options: Array[Dictionary] = []
var selected_index := -1
var confirmation_locked := false

var _card_buttons: Array[Button] = []
var _cards_box: HBoxContainer
var _prompt_label: Label


func _ready() -> void:
	_build_layout()
	_refresh_selection()


func open(options: Array[Dictionary]) -> void:
	reward_options = options.duplicate(true)
	selected_index = -1
	confirmation_locked = false
	_build_cards()
	_refresh_selection()
	show()


func _build_layout() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visibility_changed.connect(func() -> void: set_process_unhandled_input(visible))

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.62)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(_on_background_gui_input)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.gui_input.connect(_on_background_gui_input)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 20)
	panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 16)
	margin.add_child(stack)

	var title := Label.new()
	title.text = "Choose a Reward"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	stack.add_child(title)

	_cards_box = HBoxContainer.new()
	_cards_box.add_theme_constant_override("separation", 14)
	_cards_box.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_child(_cards_box)

	_prompt_label = Label.new()
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_color_override("font_color", GOLD)
	stack.add_child(_prompt_label)


func _build_cards() -> void:
	for child in _cards_box.get_children():
		child.queue_free()
	_card_buttons.clear()

	for i in range(reward_options.size()):
		var card_index := i
		var card := reward_options[i]
		var button := Button.new()
		button.custom_minimum_size = CARD_MIN_SIZE
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.text = _reward_text(card)
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.pressed.connect(func() -> void: _on_card_pressed(card_index))
		_cards_box.add_child(button)
		_card_buttons.append(button)


func _reward_text(reward: Dictionary) -> String:
	var lines: Array[String] = [
		String(reward.get("name", "Reward"))
	]
	if reward.has("cost"):
		lines.append("Cost %d" % int(reward.get("cost", 0)))
	if reward.has("damage"):
		lines.append("Damage %d" % int(reward.get("damage", 0)))
	var rules_text := String(reward.get("text", ""))
	if not rules_text.is_empty():
		lines.append("")
		lines.append(rules_text)
	return "\n".join(lines)


func _on_card_pressed(card_index: int) -> void:
	if confirmation_locked:
		return
	if selected_index == -1:
		selected_index = card_index
		_refresh_selection()
		return
	if selected_index == card_index:
		_confirm_selected_reward()
		return
	_clear_selection()


func _on_background_gui_input(event: InputEvent) -> void:
	if confirmation_locked:
		return
	if event is InputEventMouseButton \
	and event.button_index == MOUSE_BUTTON_LEFT \
	and event.pressed:
		_clear_selection()
		accept_event()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or confirmation_locked:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_Y:
			_confirm_selected_reward()
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_N:
			_clear_selection()
			get_viewport().set_input_as_handled()


func _confirm_selected_reward() -> void:
	if selected_index < 0 or selected_index >= reward_options.size():
		return
	confirmation_locked = true
	for button in _card_buttons:
		button.disabled = true
	reward_confirmed.emit(reward_options[selected_index].duplicate(true))


func _clear_selection() -> void:
	if selected_index == -1:
		return
	selected_index = -1
	_refresh_selection()


func _refresh_selection() -> void:
	for i in range(_card_buttons.size()):
		_apply_card_style(_card_buttons[i], i == selected_index)
	if _prompt_label == null:
		return
	if selected_index >= 0 and selected_index < reward_options.size():
		_prompt_label.text = "Choose %s? Y/N" % String(reward_options[selected_index].get("name", "this reward"))
	else:
		_prompt_label.text = ""


func _apply_card_style(button: Button, selected: bool) -> void:
	var style := _make_card_style(selected)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_stylebox_override("hover", style)
	button.add_theme_stylebox_override("pressed", style)
	button.add_theme_stylebox_override("focus", style)


func _make_card_style(selected: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.105882, 0.117647, 0.14902, 1.0)
	style.border_color = GOLD if selected else Color(0.352941, 0.380392, 0.443137, 1.0)
	var border_width := 4 if selected else 1
	style.border_width_left = border_width
	style.border_width_top = border_width
	style.border_width_right = border_width
	style.border_width_bottom = border_width
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_right = 6
	style.corner_radius_bottom_left = 6
	style.content_margin_left = 12
	style.content_margin_top = 12
	style.content_margin_right = 12
	style.content_margin_bottom = 12
	return style
