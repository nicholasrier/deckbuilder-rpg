extends Node2D

const TILE_SIZE := 48
const GRID_SIZE := Vector2i(10, 7)
const PLAYER_SPEED := 3

const TERRAIN_DEFS := {
	"floor": {
		"blocks_movement": false,
		"blocks_vision": false
	},
	"wall": {
		"blocks_movement": true,
		"blocks_vision": true
	}
}

const HAZARD_DEFS := {
	"fire": {
		"enter_damage": 2,
		"end_turn_damage": 1
	}
}

const DeckManagerScript := preload("res://scripts/DeckManager.gd")
const CardDatabaseScript := preload("res://scripts/CardDatabase.gd")
const CrateObjectScene := preload("res://scenes/CrateObject.tscn")

enum GameMode {
	EXPLORATION,
	COMBAT,
	VICTORY,
	DEFEAT
}

@export var EnemyScene: PackedScene

@onready var player = $Player

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
var enemies: Array[Enemy] = []
@export var targets: Array[Node2D] = []
var threatened_tiles := {}
@export var current_target: Node2D = null
var terrain_layer: Dictionary = {}
var hazard_layer: Dictionary = {}
var object_layer: Dictionary = {}
var pending_environment_messages: Array[String] = []


func mark_threat_tile(tile: Vector2i) -> void:
	threatened_tiles[tile] = true


func clear_threat_tiles() -> void:
	threatened_tiles.clear()


func is_tile_threatened(tile: Vector2i) -> bool:
	return threatened_tiles.has(tile)


func is_player_in_threat() -> bool:
	return is_tile_threatened(player.grid_position)


func _get_nearest_enemy() -> Enemy:
	var nearest: Enemy = null
	var best_distance := INF

	for e in enemies:
		if e == null or not is_instance_valid(e):
			continue

		var dist: float = abs(e.grid_position.x - player.grid_position.x) + abs(e.grid_position.y - player.grid_position.y)
		if dist < best_distance:
			best_distance = dist
			nearest = e

	return nearest


func _on_enemy_died(the_enemy: Enemy) -> void:
	_handle_destroyed_target(the_enemy)

	enemies.erase(the_enemy)
	the_enemy.hide()
	the_enemy.queue_free()
	_build_threat_map(enemies)
	_check_end_of_combat()


func _on_enemy_moved(the_enemy: Enemy) -> void:
	_build_threat_map(enemies)
	queue_redraw()


func _on_enemy_intent_changed(_enemy: Enemy, _new_intent: String) -> void:
	queue_redraw()


func _on_environment_object_destroyed(obj) -> void:
	if obj == null:
		return

	_handle_destroyed_target(obj)

	var object_tile: Vector2i = obj.grid_position
	if object_layer.get(object_tile) == obj:
		object_layer.erase(object_tile)

	pending_environment_messages.append("%s was destroyed." % _object_display_name(obj))
	obj.hide()
	obj.queue_free()
	queue_redraw()


func _ready() -> void:
	_setup_input_map()
	_setup_environment_layers()
	_spawn_enemy(EnemyScene, Vector2i(6, 3))
	_spawn_enemy(EnemyScene, Vector2i(6, 1))
	player.set_grid_position(Vector2i(1, 3))
	_build_threat_map(enemies)
	_update_all_enemy_intent()
	deck_manager.setup(CardDatabaseScript.make_starter_deck())
	deck_manager.draw_cards(5)
	current_energy = max_energy
	
	
	_update_message()
	_refresh_ui()
	queue_redraw()


func _setup_environment_layers() -> void:
	terrain_layer.clear()
	hazard_layer.clear()

	for tile in object_layer.keys():
		remove_object_at(tile)
	object_layer.clear()

	_set_terrain(Vector2i(4, 2), "wall")
	_set_terrain(Vector2i(4, 3), "wall")
	_set_terrain(Vector2i(4, 4), "wall")

	_set_hazard(Vector2i(2, 1), "fire")
	_set_hazard(Vector2i(7, 5), "fire")

	var crate := CrateObjectScene.instantiate()
	add_object(crate, Vector2i(3, 5))


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(GRID_SIZE * TILE_SIZE)), Color(0.109804, 0.117647, 0.14902, 1), true)

	for x in range(GRID_SIZE.x):
		for y in range(GRID_SIZE.y):
			var tile := Vector2i(x, y)
			var tile_pos := Vector2(x, y) * TILE_SIZE
			var tint := get_tile_tint(tile)

			draw_rect(
				Rect2(tile_pos + Vector2.ONE * 2, Vector2.ONE * (TILE_SIZE - 4)),
				tint,
				true
			)
			_draw_tile_overlay(tile, tile_pos)

	for t in targets:
		if t == null or not is_instance_valid(t):
			continue

		if t == current_target:
			var top_left := Vector2(t.grid_position * TILE_SIZE)
			draw_rect(Rect2(top_left, Vector2(TILE_SIZE, TILE_SIZE)), Color(1, 1, 0, 0.25), false, 2.0)


func _draw_tile_overlay(tile: Vector2i, tile_pos: Vector2) -> void:
	if get_terrain_type(tile) == "wall":
		draw_rect(
			Rect2(tile_pos + Vector2.ONE * 8, Vector2.ONE * (TILE_SIZE - 16)),
			Color(0.458824, 0.47451, 0.545098, 1),
			true
		)
		draw_line(tile_pos + Vector2(10, 10), tile_pos + Vector2(TILE_SIZE - 10, TILE_SIZE - 10), Color(0.831373, 0.85098, 0.898039, 0.75), 3.0)
		draw_line(tile_pos + Vector2(TILE_SIZE - 10, 10), tile_pos + Vector2(10, TILE_SIZE - 10), Color(0.831373, 0.85098, 0.898039, 0.75), 3.0)

	var hazard := get_hazard_at(tile)
	if String(hazard.get("type", "")) == "fire":
		draw_rect(
			Rect2(tile_pos + Vector2(14, 18), Vector2(20, 16)),
			Color(0.917647, 0.384314, 0.180392, 0.95),
			true
		)
		draw_rect(
			Rect2(tile_pos + Vector2(18, 10), Vector2(12, 14)),
			Color(1, 0.729412, 0.270588, 0.95),
			true
		)


func _spawn_enemy(scene: PackedScene, pos: Vector2i) -> void:
	var e := scene.instantiate() as Enemy
	e.set_grid_position(pos)
	e.died.connect(_on_enemy_died)
	e.moved.connect(_on_enemy_moved)
	e.intent_changed.connect(_on_enemy_intent_changed)
	add_child(e)
	enemies.append(e)
	targets.append(e)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton \
	and event.button_index == MOUSE_BUTTON_LEFT \
	and event.pressed:
		if _is_pointer_over_card_ui():
			return

		var world_pos := get_global_mouse_position()
		var clicked_tile := _world_to_grid(world_pos)
		if not _is_in_bounds(clicked_tile):
			return

		var clicked_targetable: Node2D = _get_targetable_at_world_pos(world_pos)
		_set_current_target(clicked_targetable)


func _is_pointer_over_card_ui() -> bool:
	var mouse_pos := get_viewport().get_mouse_position()
	if hand_box.get_global_rect().has_point(mouse_pos):
		return true

	for child in hand_box.get_children():
		if child is Control and child.get_global_rect().has_point(mouse_pos):
			return true

	return false


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


func _world_to_grid(world_pos: Vector2) -> Vector2i:
	return Vector2i(world_pos / TILE_SIZE)


func _get_targetable_at_world_pos(world_pos: Vector2):
	var grid_pos := _world_to_grid(world_pos)
	return get_targetable_at(grid_pos)


func get_enemy_at(tile: Vector2i) -> Enemy:
	for e in enemies:
		if e == null or not is_instance_valid(e):
			continue
		if e.grid_position == tile:
			return e
	return null

func get_targetable_at(tile: Vector2i):
	var enemy = get_enemy_at(tile)
	if enemy != null:
		return enemy
	
	var obj = get_object_at(tile)
	if obj != null and obj.is_targetable:
		return obj
	return null

func get_terrain_type(tile: Vector2i) -> String:
	var terrain_data: Dictionary = terrain_layer.get(tile, {})
	return String(terrain_data.get("type", "floor"))


func terrain_blocks_movement(tile: Vector2i) -> bool:
	var terrain_type := get_terrain_type(tile)
	var terrain_def: Dictionary = TERRAIN_DEFS.get(terrain_type, TERRAIN_DEFS["floor"])
	return bool(terrain_def.get("blocks_movement", false))


func terrain_blocks_vision(tile: Vector2i) -> bool:
	var terrain_type := get_terrain_type(tile)
	var terrain_def: Dictionary = TERRAIN_DEFS.get(terrain_type, TERRAIN_DEFS["floor"])
	return bool(terrain_def.get("blocks_vision", false))


func _set_terrain(tile: Vector2i, terrain_type: String) -> void:
	if terrain_type == "floor":
		terrain_layer.erase(tile)
		return
	terrain_layer[tile] = {"type": terrain_type}


func _set_hazard(tile: Vector2i, hazard_type: String, duration: int = -1) -> void:
	var hazard_data := {"type": hazard_type}
	if duration > 0:
		hazard_data["duration"] = duration
	hazard_layer[tile] = hazard_data


func get_hazard_at(tile: Vector2i) -> Dictionary:
	return hazard_layer.get(tile, {})


func get_object_at(tile: Vector2i):
	var obj = object_layer.get(tile, null)
	if obj == null:
		return null
	if not is_instance_valid(obj):
		object_layer.erase(tile)
		return null
	return obj


func add_object(obj, tile: Vector2i) -> void:
	if obj == null:
		return

	var existing = get_object_at(tile)
	if existing != null and existing != obj:
		remove_object_at(tile)

	if obj.has_signal("destroyed") and not obj.destroyed.is_connected(_on_environment_object_destroyed):
		obj.destroyed.connect(_on_environment_object_destroyed)

	if obj.get_parent() != self:
		add_child(obj)

	obj.set_grid_position(tile)
	object_layer[tile] = obj
	if obj.is_targetable:
		targets.append(obj)
	queue_redraw()

func _set_current_target(target: Node2D) -> void:
	current_target = target if target != null and is_instance_valid(target) else null
	queue_redraw()


func _remove_target_reference(target: Node2D) -> void:
	targets.erase(target)


func _get_fallback_target_after_destroy(destroyed_target: Node2D) -> Node2D:
	if mode == GameMode.COMBAT:
		if destroyed_target is Enemy:
			return _get_nearest_enemy_excluding(destroyed_target)
		return _get_nearest_enemy()
	return null


func _handle_destroyed_target(destroyed_target: Node2D) -> void:
	if destroyed_target == null:
		return

	_remove_target_reference(destroyed_target)
	_set_current_target(_get_fallback_target_after_destroy(destroyed_target))


func _get_nearest_enemy_excluding(excluded_enemy: Enemy) -> Enemy:
	var nearest: Enemy = null
	var best_distance := INF

	for e in enemies:
		if e == null or not is_instance_valid(e) or e == excluded_enemy:
			continue

		var dist: float = abs(e.grid_position.x - player.grid_position.x) + abs(e.grid_position.y - player.grid_position.y)
		if dist < best_distance:
			best_distance = dist
			nearest = e

	return nearest

func remove_object_at(tile: Vector2i) -> void:
	var obj = get_object_at(tile)
	_handle_destroyed_target(obj)
	if obj == null:
		object_layer.erase(tile)
		return
	
	object_layer.erase(tile)
	obj.hide()
	obj.queue_free()
	queue_redraw()


func damage_object_at(tile: Vector2i, amount: int) -> void:
	var obj = get_object_at(tile)
	if obj == null:
		return
	if obj.has_method("take_damage"):
		obj.take_damage(amount)


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
	if not _move_entity_to_tile(player, target):
		return

	_apply_on_enter_tile_effects(player, target)
	if player.hp <= 0:
		_finish_environment_message("You were overwhelmed.")
		mode = GameMode.DEFEAT
		_refresh_ui()
		queue_redraw()
		return

	if not enemies.is_empty():
		if is_player_in_threat():
			_finish_environment_message("")
			_start_combat()
			return
		message = _consume_environment_messages("Exploration: close the gap to trigger combat.")

	_update_message()
	queue_redraw()


func _is_entity_occupied(tile: Vector2i, ignore_entity = null) -> bool:
	if player != ignore_entity and player.grid_position == tile:
		return true

	for e in enemies:
		if e == null or not is_instance_valid(e) or e == ignore_entity:
			continue
		if e.grid_position == tile:
			return true

	return false


func _can_move_to_tile(tile: Vector2i, moving_entity = null) -> bool:
	if not _is_in_bounds(tile):
		return false
	if terrain_blocks_movement(tile):
		return false

	var obj = get_object_at(tile)
	if obj != null and bool(obj.blocks_movement):
		return false

	return not _is_entity_occupied(tile, moving_entity)


func _move_entity_to_tile(entity, target: Vector2i) -> bool:
	if not _can_move_to_tile(target, entity):
		return false
	entity.set_grid_position(target)
	return true


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
	if not _move_entity_to_tile(player, target):
		return

	current_energy -= 1
	movement_left -= 1
	_apply_on_enter_tile_effects(player, target)
	message = _consume_environment_messages("Moved to %s." % [str(player.grid_position)])
	_update_all_enemy_intent()
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
	_set_current_target(_get_nearest_enemy())
	if draw_card:
		deck_manager.draw_cards(1)
	must_resolve_overflow = deck_manager.hand.size() > 5
	if must_resolve_overflow:
		message = "Hand overflow. Play or discard one card."

	_update_all_enemy_intent()
	_refresh_ui()
	queue_redraw()


func _end_player_turn() -> void:
	_apply_end_turn_tile_effects(player)
	if player.hp <= 0:
		mode = GameMode.DEFEAT
		message = _consume_environment_messages("You were overwhelmed.")
		_refresh_ui()
		queue_redraw()
		return

	message = _consume_environment_messages("Enemy turn.")
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
	for e in enemies.duplicate():
		if e == null or not is_instance_valid(e):
			continue

		if player.grid_position in e.get_threatened_tiles():
			player.take_damage(e.damage)
			if player.hiding:
				player.become_hidden_or_revealed()
			message = "Enemy attacks for %d." % e.damage
		else:
			var direction := _step_toward(e.grid_position, player.grid_position)
			if direction != Vector2i.ZERO and _move_entity_to_tile(e, e.grid_position + direction):
				message = "Enemy advances."
				_apply_on_enter_tile_effects(e, e.grid_position)
				message = _consume_environment_messages(message)
			if e != null and is_instance_valid(e) and player.grid_position in e.get_threatened_tiles():
				player.take_damage(e.damage)
				message += " Then hits for %d." % e.damage

		if e == null or not is_instance_valid(e):
			_refresh_ui()
			queue_redraw()
			continue

		_apply_end_turn_tile_effects(e)
		message = _consume_environment_messages(message)

		if player.hp <= 0:
			mode = GameMode.DEFEAT
			message = "You were overwhelmed."
		if mode != GameMode.COMBAT:
			_refresh_ui()
			queue_redraw()
			return

		if e != null and is_instance_valid(e):
			_update_enemy_intent(e)
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

	_update_all_enemy_intent()
	_check_end_of_combat()
	_refresh_ui()
	queue_redraw()


func _resolve_card(card: Dictionary) -> Dictionary:
	match card["id"]:
		"strike":
			return _play_strike()
		"block":
			return _play_block()
		"lunge":
			return _play_lunge()
		"backstab":
			return _play_backstab()
		"slip_past":
			return _play_slip_past()
		"unseen":
			return _play_unseen()
		_:
			return {"success": false, "message": "Card effect not implemented."}


func _play_strike() -> Dictionary:
	if not _has_valid_target():
		return {"success": false, "message": "No target selected."}
	if not _is_adjacent(player.grid_position, current_target.grid_position):
		return {"success": false, "message": "Strike needs an adjacent enemy."}
	var damage := _modify_attack_damage(6)
	current_target.take_damage(damage)
	return {"success": true, "message": "Dealt %d damage." % damage}


func _play_block() -> Dictionary:
	player.gain_block(5)
	return {"success": true, "message": "Gained 5 block."}


func _play_lunge() -> Dictionary:
	if not _has_valid_target():
		return {"success": false, "message": "No target selected."}

	var direction := _step_toward(player.grid_position, current_target.grid_position)
	if direction != Vector2i.ZERO:
		var lunge_tile: Vector2i = player.grid_position + direction
		if lunge_tile != current_target.grid_position and _move_entity_to_tile(player, lunge_tile):
			_apply_on_enter_tile_effects(player, lunge_tile)
	if _is_adjacent(player.grid_position, current_target.grid_position):
		var lunge_damage := _modify_attack_damage(6)
		current_target.take_damage(lunge_damage)
		return {"success": true, "message": _consume_environment_messages("Closed in and dealt %d damage." % lunge_damage)}
	return {"success": true, "message": _consume_environment_messages("Moved closer, but no hit.")}


func _play_backstab() -> Dictionary:
	if not _has_valid_target():
		return {"success": false, "message": "No target selected."}
	if not _is_adjacent(player.grid_position, current_target.grid_position):
		return {"success": false, "message": "Backstab needs an adjacent enemy."}
	var behind_tile: Vector2i = current_target.grid_position - current_target.facing_dir
	var base_damage := 9 if player.grid_position == behind_tile else 5
	var backstab_damage := _modify_attack_damage(base_damage)
	current_target.take_damage(backstab_damage)
	return {"success": true, "message": "Dealt %d damage." % backstab_damage}


func _play_slip_past() -> Dictionary:
	if not _has_valid_target():
		return {"success": false, "message": "No target selected."}
	if not _is_adjacent(player.grid_position, current_target.grid_position):
		return {"success": false, "message": "Slip Past needs an adjacent enemy."}
	var old_player_pos: Vector2i = player.grid_position
	player.set_grid_position(current_target.grid_position)
	current_target.set_grid_position(old_player_pos)
	_apply_on_enter_tile_effects(player, player.grid_position)
	_apply_on_enter_tile_effects(current_target, current_target.grid_position)
	return {"success": true, "message": _consume_environment_messages("Swapped positions.")}


func _play_unseen() -> Dictionary:
	player.become_hidden_or_revealed()
	return {"success": true, "message": "Your next attack is empowered."}


func _has_valid_target() -> bool:
	return current_target != null and is_instance_valid(current_target)


func _modify_attack_damage(base_damage: int) -> int:
	if player.hiding:
		player.become_hidden_or_revealed()
		return int(ceil(base_damage * 1.5))
	return base_damage


func _check_end_of_combat() -> void:
	if not enemies.is_empty():
		return
	mode = GameMode.EXPLORATION
	_set_current_target(null)
	message = _consume_environment_messages("")
	_update_message()


func _update_enemy_intent(e: Enemy) -> void:
	if mode == GameMode.COMBAT:
		if _is_adjacent(player.grid_position, e.grid_position):
			e.set_intent_text("Attack %d" % e.damage)
		else:
			e.set_intent_text("Advance")
	else:
		e.set_intent_text("Patrol")


func _update_all_enemy_intent() -> void:
	for e in enemies:
		if e == null or not is_instance_valid(e):
			continue
		_update_enemy_intent(e)


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
	return "Unknown"


func _is_in_bounds(tile: Vector2i) -> bool:
	return tile.x >= 0 and tile.y >= 0 and tile.x < GRID_SIZE.x and tile.y < GRID_SIZE.y


func _build_threat_map(foes: Array[Enemy]) -> void:
	threatened_tiles.clear()

	for f in foes:
		if f == null or not is_instance_valid(f):
			continue

		for tile in f.get_threatened_tiles():
			threatened_tiles[tile] = true

	queue_redraw()


func get_tile_tint(tile: Vector2i) -> Color:
	if get_terrain_type(tile) == "wall":
		return Color(0.243137, 0.262745, 0.313726, 1)

	var tint := Color(0.160784, 0.184314, 0.231373, 1)

	if threatened_tiles.has(tile):
		tint = tint.lerp(Color(1, 0, 0, 1), 0.25)

	if tile == player.grid_position:
		tint = tint.lerp(Color(0.105882, 0.231373, 0.184314, 1), 0.55)

	for e in enemies:
		if e == null or not is_instance_valid(e):
			continue
		if tile == e.grid_position:
			return Color(0.239216, 0.133333, 0.14902, 1)

	return tint


func _apply_on_enter_tile_effects(entity, tile: Vector2i) -> void:
	var hazard := get_hazard_at(tile)
	if hazard.is_empty():
		return

	var hazard_type := String(hazard.get("type", ""))
	var hazard_def: Dictionary = HAZARD_DEFS.get(hazard_type, {})
	var enter_damage := int(hazard_def.get("enter_damage", 0))
	if enter_damage <= 0:
		return

	_damage_entity(entity, enter_damage)
	pending_environment_messages.append("%s takes %d %s damage." % [_entity_display_name(entity), enter_damage, hazard_type])


func _apply_end_turn_tile_effects(entity) -> void:
	if entity == null or not is_instance_valid(entity):
		return

	var hazard := get_hazard_at(entity.grid_position)
	if hazard.is_empty():
		return

	var hazard_type := String(hazard.get("type", ""))
	var hazard_def: Dictionary = HAZARD_DEFS.get(hazard_type, {})
	var end_turn_damage := int(hazard_def.get("end_turn_damage", 0))
	if end_turn_damage <= 0:
		return

	_damage_entity(entity, end_turn_damage)
	pending_environment_messages.append("%s takes %d %s damage at end of turn." % [_entity_display_name(entity), end_turn_damage, hazard_type])


func _damage_entity(entity, amount: int) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	if entity.has_method("take_damage"):
		entity.take_damage(amount)
	_refresh_ui()


func _entity_display_name(entity) -> String:
	if entity == player:
		return "Player"
	if entity is Enemy:
		return "Enemy"
	return "Entity"


func _object_display_name(obj) -> String:
	if obj == null:
		return "Object"
	var object_type = obj.get("object_type")
	if object_type != null and String(object_type) != "":
		return String(object_type).capitalize()
	return String(obj.name)


func _consume_environment_messages(base_message: String) -> String:
	if pending_environment_messages.is_empty():
		return base_message

	var environment_text := " ".join(pending_environment_messages)
	pending_environment_messages.clear()
	if base_message.is_empty():
		return environment_text
	return "%s %s" % [base_message, environment_text]


func _finish_environment_message(base_message: String) -> void:
	message = _consume_environment_messages(base_message)
	_update_message()


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
