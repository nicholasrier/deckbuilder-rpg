extends Node2D

const TILE_SIZE := 48
const GRID_SIZE := Vector2i(10, 7)
const PLAYER_SPEED := 3

const DeckManagerScript := preload("res://scripts/DeckManager.gd")
const CardDatabaseScript := preload("res://scripts/CardDatabase.gd")

enum GameMode {
	EXPLORATION,
	COMBAT,
	VICTORY,
	DEFEAT
}

@onready var player = $Player
@onready var enemy = $Enemy
@onready var mode_label: Label = $CanvasLayer/HUD/Root/TopBar/ModeLabel
@onready var stats_label: Label = $CanvasLayer/HUD/Root/TopBar/StatsLabel
@onready var center_message: Label = $CanvasLayer/HUD/Root/CenterMessage
@onready var hand_box: HBoxContainer = $CanvasLayer/HUD/Root/HandPanel/HandMargin/HandBox
@onready var controls_label: Label = $CanvasLayer/HUD/Root/ControlsLabel

var deck_manager = DeckManagerScript.new()
var mode := GameMode.EXPLORATION
var combat_turn := 0
var current_energy := 0
var max_energy := 3
var movement_left := PLAYER_SPEED
var must_resolve_overflow := false
var message := "Move with arrow keys or WASD."
var enemies := []

func _on_enemy_died(theEnemy) -> void:
	enemies.erase(theEnemy)
	enemy.hide()
	enemy.queue_free()

func _ready() -> void:
	_setup_input_map()
	enemies.append(enemy)
	player.set_grid_position(Vector2i(1, 3))
	enemy.set_grid_position(Vector2i(6, 3))
	enemy.died.connect(_on_enemy_died)
	deck_manager.setup(CardDatabaseScript.make_starter_deck())
	deck_manager.draw_cards(5)
	current_energy = max_energy
	enemy.set_intent_text("Patrol")
	_update_message()
	_refresh_ui()
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(GRID_SIZE * TILE_SIZE)), Color(0.109804, 0.117647, 0.14902, 1), true)
	for x in range(GRID_SIZE.x):
		for y in range(GRID_SIZE.y):
			var tile_pos := Vector2(x, y) * TILE_SIZE
			var tint := Color(0.160784, 0.184314, 0.231373, 1)
			if mode == GameMode.COMBAT and Vector2i(x, y) == enemy.grid_position:
				tint = Color(0.239216, 0.133333, 0.14902, 1)
			elif Vector2i(x, y) == player.grid_position and mode == GameMode.COMBAT:
				tint = Color(0.105882, 0.231373, 0.184314, 1)
			draw_rect(Rect2(tile_pos + Vector2.ONE * 2, Vector2.ONE * (TILE_SIZE - 4)), tint, true)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("end_turn"):
		if mode == GameMode.COMBAT and not must_resolve_overflow:
			_end_player_turn()
		return
	if event.is_action_pressed("card_1"):
		_handle_card_shortcut(0)
	elif event.is_action_pressed("card_2"):
		_handle_card_shortcut(1)
	elif event.is_action_pressed("card_3"):
		_handle_card_shortcut(2)
	elif event.is_action_pressed("card_4"):
		_handle_card_shortcut(3)
	elif event.is_action_pressed("card_5"):
		_handle_card_shortcut(4)


func _process(_delta: float) -> void:

	var move_dir := _read_move_input()
	if move_dir == Vector2i.ZERO:
		return

	if mode == GameMode.EXPLORATION:
		_try_exploration_move(move_dir)
	elif mode == GameMode.COMBAT:
		_try_combat_move(move_dir)


func _setup_input_map() -> void:
	_ensure_action("move_up", KEY_W, KEY_UP)
	_ensure_action("move_down", KEY_S, KEY_DOWN)
	_ensure_action("move_left", KEY_A, KEY_LEFT)
	_ensure_action("move_right", KEY_D, KEY_RIGHT)
	_ensure_action("end_turn", KEY_SPACE)
	_ensure_action("card_1", KEY_1)
	_ensure_action("card_2", KEY_2)
	_ensure_action("card_3", KEY_3)
	_ensure_action("card_4", KEY_4)
	_ensure_action("card_5", KEY_5)


func _ensure_action(action: StringName, primary_key: Key, secondary_key: Key = KEY_NONE) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	if not _action_has_key(action, primary_key):
		var primary := InputEventKey.new()
		primary.physical_keycode = primary_key
		InputMap.action_add_event(action, primary)
	if secondary_key != KEY_NONE and not _action_has_key(action, secondary_key):
		var secondary := InputEventKey.new()
		secondary.physical_keycode = secondary_key
		InputMap.action_add_event(action, secondary)


func _action_has_key(action: StringName, keycode: Key) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey and event.physical_keycode == keycode:
			return true
	return false


func _read_move_input() -> Vector2i:
	if Input.is_action_just_pressed("move_up"):
		return Vector2i.UP
	if Input.is_action_just_pressed("move_down"):
		return Vector2i.DOWN
	if Input.is_action_just_pressed("move_left"):
		return Vector2i.LEFT
	if Input.is_action_just_pressed("move_right"):
		return Vector2i.RIGHT
	return Vector2i.ZERO


func _try_exploration_move(direction: Vector2i) -> void:
	var target: Vector2i = player.grid_position + direction
	if not _is_in_bounds(target):
		return
	player.set_grid_position(target)
	if !enemies.is_empty():
		if player.grid_position.distance_to(enemy.grid_position) <= 1.0:
			_start_combat()
		else:
			message = "Exploration: close the gap to trigger combat."
	
	_update_message()
	queue_redraw()


func _try_combat_move(direction: Vector2i) -> void:
	if must_resolve_overflow:
		message = "Hand overflow: play or discard a card first."
		_update_message()
		return
	if current_energy <= 0 or movement_left <= 0:
		message = "No movement left this turn."
		_update_message()
		return
	var target: Vector2i = player.grid_position + direction
	if not _is_in_bounds(target) or target == enemy.grid_position:
		return
	player.set_grid_position(target)
	current_energy -= 1
	movement_left -= 1
	message = "Moved to %s." % [str(player.grid_position)]
	_update_enemy_intent()
	_refresh_ui()
	queue_redraw()


func _start_combat() -> void:
	mode = GameMode.COMBAT
	combat_turn = 1
	message = "Combat started. Draw 1 each turn, but your hand persists."
	_begin_player_turn(false)


func _begin_player_turn(draw_card: bool = true) -> void:
	player.reset_turn_state()
	current_energy = max_energy
	movement_left = PLAYER_SPEED
	if draw_card:
		deck_manager.draw_cards(1)
	must_resolve_overflow = deck_manager.hand.size() > 5
	if must_resolve_overflow:
		message = "Hand overflow. Play or discard one card."
	
	_update_enemy_intent()
	_refresh_ui()
	queue_redraw()


func _end_player_turn() -> void:
	message = "Enemy turn."
	_enemy_take_turn()
	if mode != GameMode.COMBAT:
		_refresh_ui()
		queue_redraw()
		return
	combat_turn += 1
	_begin_player_turn(true)
	if not must_resolve_overflow:
		message = "Turn %d. Spend energy on movement or cards." % combat_turn
	_update_message()


func _enemy_take_turn() -> void:
	if enemy.hp <= 0:
		return
	if _is_adjacent(player.grid_position, enemy.grid_position):
		player.take_damage(enemy.damage)
		message = "Enemy attacks for %d." % enemy.damage
	else:
		var direction := _step_toward(enemy.grid_position, player.grid_position)
		if direction != Vector2i.ZERO:
			enemy.facing_dir = direction
			enemy.set_grid_position(enemy.grid_position + direction)
			message = "Enemy advances."
		if _is_adjacent(player.grid_position, enemy.grid_position):
			player.take_damage(enemy.damage)
			message += " Then hits for %d." % enemy.damage
	if player.hp <= 0:
		mode = GameMode.DEFEAT
		message = "You were overwhelmed."
	enemy.set_intent_text("Attack %d" % enemy.damage)
	_refresh_ui()
	queue_redraw()


func _handle_card_shortcut(index: int) -> void:
	if index >= deck_manager.hand.size():
		return
	if must_resolve_overflow:
		var discarded := deck_manager.discard_from_hand(index)
		message = "Discarded %s to stay at 5 cards." % discarded.get("name", "card")
		must_resolve_overflow = deck_manager.hand.size() > 5
		_refresh_ui()
		_update_message()
		return
	_play_card(index)


func _play_card(index: int) -> void:
	if index < 0 or index >= deck_manager.hand.size():
		return
	var card: Dictionary = deck_manager.hand[index]
	if card.get("combat_only", false) and mode != GameMode.COMBAT:
		message = "%s can only be used in combat." % card["name"]
		_update_message()
		return
	if current_energy < int(card["cost"]):
		message = "Not enough energy for %s." % card["name"]
		_update_message()
		return
	var result := _resolve_card(card)
	if not result["success"]:
		message = result["message"]
		_update_message()
		return
	current_energy -= int(card["cost"])
	var played := deck_manager.play_from_hand(index)
	message = "Played %s. %s" % [played["name"], result["message"]]
	_update_enemy_intent()
	_check_end_of_combat()
	_refresh_ui()
	queue_redraw()


func _resolve_card(card: Dictionary) -> Dictionary:
	match card["id"]:
		"strike":
			if not _is_adjacent(player.grid_position, enemy.grid_position):
				return {"success": false, "message": "Strike needs an adjacent enemy."}
			var damage := _modify_attack_damage(6)
			enemy.take_damage(damage)
			return {"success": true, "message": "Dealt %d damage." % damage}
		"block":
			player.gain_block(5)
			return {"success": true, "message": "Gained 5 block."}
		"lunge":
			var direction := _step_toward(player.grid_position, enemy.grid_position)
			if direction != Vector2i.ZERO and player.grid_position + direction != enemy.grid_position:
				player.set_grid_position(player.grid_position + direction)
			if _is_adjacent(player.grid_position, enemy.grid_position):
				var lunge_damage := _modify_attack_damage(6)
				enemy.take_damage(lunge_damage)
				return {"success": true, "message": "Closed in and dealt %d damage." % lunge_damage}
			return {"success": true, "message": "Moved closer, but no hit."}
		"backstab":
			if not _is_adjacent(player.grid_position, enemy.grid_position):
				return {"success": false, "message": "Backstab needs an adjacent enemy."}
			var behind_tile: Vector2i = enemy.grid_position - enemy.facing_dir
			var base_damage := 9 if player.grid_position == behind_tile else 5
			var backstab_damage := _modify_attack_damage(base_damage)
			enemy.take_damage(backstab_damage)
			return {"success": true, "message": "Dealt %d damage." % backstab_damage}
		"slip_past":
			if not _is_adjacent(player.grid_position, enemy.grid_position):
				return {"success": false, "message": "Slip Past needs an adjacent enemy."}
			var old_player_pos: Vector2i = player.grid_position
			player.set_grid_position(enemy.grid_position)
			enemy.set_grid_position(old_player_pos)
			return {"success": true, "message": "Swapped positions."}
		"unseen":
			player.become_hidden_or_revealed()
			return {"success": true, "message": "Your next attack is empowered."}
	return {"success": false, "message": "Card effect not implemented."}


func _modify_attack_damage(base_damage: int) -> int:
	if player.hiding:
		player.become_hidden_or_revealed()
		return int(ceil(base_damage * 1.5))
	return base_damage


func _check_end_of_combat() -> void:
	if !enemies.is_empty():
		return
	mode = GameMode.EXPLORATION
	message = " "
	_update_message()


func _update_enemy_intent() -> void:
	if mode == GameMode.COMBAT:
		if _is_adjacent(player.grid_position, enemy.grid_position):
			enemy.set_intent_text("Attack %d" % enemy.damage)
		else:
			enemy.set_intent_text("Advance")
	else:
		enemy.set_intent_text("Patrol")


func _refresh_ui() -> void:
	mode_label.text = "Mode: %s" % _mode_name()
	stats_label.text = "HP %d/%d  Block %d  Energy %d/%d" % [
		player.hp,
		player.max_hp,
		player.block,
		current_energy,
		max_energy
	]
	controls_label.text = _controls_text()
	_rebuild_hand()
	_update_message()


func _rebuild_hand() -> void:
	for child in hand_box.get_children():
		child.queue_free()
	for i in range(deck_manager.hand.size()):
		var card_index := i
		var card: Dictionary = deck_manager.hand[i]
		var button := Button.new()
		button.custom_minimum_size = Vector2(150, 96)
		button.text = "%d. %s\nCost %d\n%s" % [i + 1, card["name"], card["cost"], card["text"]]
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.disabled = mode == GameMode.DEFEAT or mode == GameMode.VICTORY
		button.pressed.connect(func() -> void: _handle_card_shortcut(card_index))
		hand_box.add_child(button)


func _update_message() -> void:
	center_message.text = message


func _controls_text() -> String:
	match mode:
		GameMode.EXPLORATION:
			return "Explore with arrow keys/WASD. Walk into the enemy to trigger combat. Number keys can play any usable card."
		GameMode.COMBAT:
			if must_resolve_overflow:
				return "Hand overflow: press 1-5 or click a card to discard it. Space is locked."
			return "Combat: arrow keys/WASD move for 1 energy, 1-5 play cards, Space ends turn."
		GameMode.VICTORY:
			return "Prototype win state reached."
		GameMode.DEFEAT:
			return "Prototype defeat state reached."
	return ""


func _mode_name() -> String:
	match mode:
		GameMode.EXPLORATION:
			return "Exploration"
		GameMode.COMBAT:
			return "Combat"
		GameMode.VICTORY:
			return "Victory"
		GameMode.DEFEAT:
			return "Defeat"
	return "Unknocwn"


func _is_in_bounds(tile: Vector2i) -> bool:
	return tile.x >= 0 and tile.y >= 0 and tile.x < GRID_SIZE.x and tile.y < GRID_SIZE.y


func _is_adjacent(a: Vector2i, b: Vector2i) -> bool:
	return abs(a.x - b.x) + abs(a.y - b.y) == 1


func _step_toward(from_tile: Vector2i, to_tile: Vector2i) -> Vector2i:
	var delta := to_tile - from_tile
	if abs(delta.x) > abs(delta.y):
		return Vector2i(int(sign(delta.x)), 0)
	if delta.y != 0:
		return Vector2i(0, int(sign(delta.y)))
	if delta.x != 0:
		return Vector2i(int(sign(delta.x)), 0)
	return Vector2i.ZERO
