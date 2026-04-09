extends Node2D

const TILE_SIZE := 48
const GRID_SIZE := Vector2i(10, 7)
const PLAYER_SPEED := 3
const CARDINAL_DIRECTIONS: Array[Vector2i] = [
	Vector2i.UP,
	Vector2i.RIGHT,
	Vector2i.DOWN,
	Vector2i.LEFT
]

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
const DrawPickupScene := preload("res://scenes/DrawPickup.tscn")

enum GameMode {
	EXPLORATION,
	COMBAT,
	VICTORY,
	DEFEAT
}

enum ExplorationState {
	WAITING_FOR_PLAYER_INPUT,
	PLAYER_ACTION_RESOLVING,
	ENEMY_ACTION_RESOLVING,
	TRANSITIONING_TO_COMBAT
}

@export var EnemyScene: PackedScene
@export var debug_enemy_pathfinding := false
@export_range(0.0, 0.5, 0.01) var enemy_step_duration := 0.18
@export var debug_enemy_step_logging := false
@export_range(0.0, 0.5, 0.01) var player_step_duration := 0.12
@export var debug_player_step_logging := false
@export_range(0.0, 0.5, 0.01) var enemy_rotation_duration := 0.08

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
var enemy_turn_in_progress := false
var player_move_in_progress := false
var exploration_state := ExplorationState.WAITING_FOR_PLAYER_INPUT
var exploration_reserved_tiles: Dictionary = {}
var exploration_enemy_timers: Dictionary = {}
var exploration_active_presentations := 0
var exploration_pending_combat := false
var exploration_combat_trigger_enemy: Enemy = null
var exploration_combat_trigger_reason := ""


func mark_threat_tile(tile: Vector2i) -> void:
	threatened_tiles[tile] = true


func clear_threat_tiles() -> void:
	threatened_tiles.clear()


func is_tile_threatened(tile: Vector2i) -> bool:
	return threatened_tiles.has(tile)


func is_player_in_threat() -> bool:
	return is_tile_threatened(player.grid_position)


func _set_exploration_state(next_state: int) -> void:
	exploration_state = next_state


func _rebuild_enemy_threat_map() -> void:
	_build_threat_map(enemies)


func _refresh_exploration_state() -> void:
	if mode != GameMode.EXPLORATION:
		return
	if exploration_pending_combat:
		_set_exploration_state(ExplorationState.TRANSITIONING_TO_COMBAT)
	elif player_move_in_progress:
		_set_exploration_state(ExplorationState.PLAYER_ACTION_RESOLVING)
	elif exploration_active_presentations > 0:
		_set_exploration_state(ExplorationState.ENEMY_ACTION_RESOLVING)
	else:
		_set_exploration_state(ExplorationState.WAITING_FOR_PLAYER_INPUT)


func _pause_exploration_enemy_schedules(paused: bool) -> void:
	for timer in exploration_enemy_timers.values():
		if timer == null or not is_instance_valid(timer):
			continue
		timer.paused = paused
		if not paused and timer.is_stopped():
			timer.start()


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
	_clear_exploration_reservations_for(the_enemy)
	_remove_enemy_exploration_timer(the_enemy)

	enemies.erase(the_enemy)
	the_enemy.hide()
	the_enemy.queue_free()
	_rebuild_enemy_threat_map()
	_update_all_enemy_intent()
	_check_end_of_combat()


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
	var patrol_enemy := _spawn_enemy(EnemyScene, Vector2i(6, 3))
	patrol_enemy.exploration_cadence = 0.85
	setup_enemy_patrol(patrol_enemy, patrol_enemy.grid_position, Vector2i.RIGHT, 3, Enemy.Patrol_Mode.LOOP)

	var sentry_enemy := _spawn_enemy(EnemyScene, Vector2i(6, 1))
	sentry_enemy.exploration_cadence = 1.15
	setup_enemy_rotation_sentry(
		sentry_enemy,
		[
			Vector2i.LEFT,
			Vector2i.UP,
			Vector2i.RIGHT,
			Vector2i.DOWN
		]
	)
	player.set_grid_position(Vector2i(1, 3))
	_rebuild_enemy_threat_map()
	_update_all_enemy_intent()
	_start_exploration_enemy_schedules()
	deck_manager.setup(CardDatabaseScript.make_starter_deck())
	_draw_cards_with_shared_rules(5)
	current_energy = max_energy
	_refresh_exploration_state()

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

	var draw_pickup := DrawPickupScene.instantiate()
	add_object(draw_pickup, Vector2i(2, 3))


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


func _spawn_enemy(scene: PackedScene, pos: Vector2i) -> Enemy:
	var e := scene.instantiate() as Enemy
	e.set_grid_position(pos)
	e.died.connect(_on_enemy_died)
	e.intent_changed.connect(_on_enemy_intent_changed)
	add_child(e)
	enemies.append(e)
	targets.append(e)
	_ensure_enemy_exploration_timer(e)
	return e


func _is_input_locked() -> bool:
	if mode == GameMode.EXPLORATION:
		return exploration_pending_combat or player_move_in_progress
	return enemy_turn_in_progress or player_move_in_progress


func _is_movement_locked() -> bool:
	return _is_input_locked()


func _input(event: InputEvent) -> void:
	if _is_input_locked():
		return

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
	if _is_input_locked():
		return

	if mode == GameMode.EXPLORATION and event.is_action_pressed("wait"):
		_try_exploration_wait()
		return

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


func consume_map_pickup(pickup) -> void:
	if pickup == null:
		return

	var pickup_tile: Vector2i = pickup.grid_position
	if object_layer.get(pickup_tile) == pickup:
		object_layer.erase(pickup_tile)

	_remove_target_reference(pickup)
	pickup.hide()
	pickup.queue_free()
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
	if _is_movement_locked():
		return

	var move_dir := _read_move_input()
	if move_dir == Vector2i.ZERO:
		return
	
	if must_resolve_overflow:
		message = "Hand overflow: play or discard a card first."
		_update_message()
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
	_ensure_action("wait", KEY_PERIOD, KEY_X)
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
	if must_resolve_overflow:
		message = "Hand overflow: play or discard a card first."
		_update_message()
		return
	var target: Vector2i = player.grid_position + direction
	if not await _move_player_one_tile(target):
		return
	if mode != GameMode.EXPLORATION:
		return

	var resolved_message := _consume_environment_messages("Moved to %s." % [str(player.grid_position)])
	if not resolved_message.is_empty():
		message = resolved_message
	_refresh_ui()
	queue_redraw()


func _try_exploration_wait() -> void:
	if must_resolve_overflow:
		message = "Hand overflow: play or discard a card first."
		_update_message()
		return
	message = "You wait."
	_resolve_exploration_detection("player_wait")
	_flush_pending_exploration_transition_if_ready()
	if mode != GameMode.EXPLORATION:
		return
	_refresh_ui()
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


func _is_tile_walkable(
	tile: Vector2i,
	moving_entity = null,
	treat_player_as_blocked: bool = true,
	treat_other_enemies_as_blocked: bool = true
) -> bool:
	if not _is_in_bounds(tile):
		return false
	if terrain_blocks_movement(tile):
		return false

	var obj = get_object_at(tile)
	if obj != null and bool(obj.blocks_movement):
		return false

	if mode == GameMode.EXPLORATION and _is_tile_reserved_by_other(tile, moving_entity):
		return false

	if treat_player_as_blocked and player != moving_entity and player.grid_position == tile:
		return false

	if treat_other_enemies_as_blocked:
		for e in enemies:
			if e == null or not is_instance_valid(e) or e == moving_entity:
				continue
			if e.grid_position == tile:
				return false

	return true


func _can_move_to_tile(tile: Vector2i, moving_entity = null) -> bool:
	return _is_tile_walkable(tile, moving_entity, true, true)


func _get_attack_goal_tiles(target_tile: Vector2i, attack_offsets: Array[Vector2i]) -> Array[Vector2i]:
	var goal_tiles: Array[Vector2i] = []

	for offset in attack_offsets:
		var goal_tile := target_tile - offset
		if not _is_in_bounds(goal_tile):
			continue
		goal_tiles.append(goal_tile)

	return goal_tiles


func _find_bfs_path(
	start_tile: Vector2i,
	goal_tile: Vector2i,
	moving_entity = null,
	treat_player_as_blocked: bool = true,
	treat_other_enemies_as_blocked: bool = true
) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	if start_tile == goal_tile:
		return path
	if not _is_tile_walkable(goal_tile, moving_entity, treat_player_as_blocked, treat_other_enemies_as_blocked):
		return path

	var came_from: Dictionary = {start_tile: start_tile}
	var frontier: Array[Vector2i] = [start_tile]
	var frontier_index := 0

	while frontier_index < frontier.size():
		var current := frontier[frontier_index]
		frontier_index += 1

		if current == goal_tile:
			break

		for direction in CARDINAL_DIRECTIONS:
			var next_tile := current + direction
			if came_from.has(next_tile):
				continue
			if not _is_tile_walkable(next_tile, moving_entity, treat_player_as_blocked, treat_other_enemies_as_blocked):
				continue

			came_from[next_tile] = current
			frontier.append(next_tile)

	if not came_from.has(goal_tile):
		return path

	var step := goal_tile
	while step != start_tile:
		path.push_front(step)
		step = came_from[step]

	return path


func _find_path_to_nearest_goal(
	start_tile: Vector2i,
	goal_tiles: Array[Vector2i],
	moving_entity = null,
	treat_player_as_blocked: bool = true,
	treat_other_enemies_as_blocked: bool = true
) -> Array[Vector2i]:
	var best_path: Array[Vector2i] = []
	var found_path := false

	for goal_tile in goal_tiles:
		var path := _find_bfs_path(
			start_tile,
			goal_tile,
			moving_entity,
			treat_player_as_blocked,
			treat_other_enemies_as_blocked
		)
		if path.is_empty():
			continue
		if not found_path or path.size() < best_path.size():
			best_path = path
			found_path = true

	return best_path


func _find_enemy_path_to_target(
	enemy: Enemy,
	target_tile: Vector2i,
	treat_other_enemies_as_blocked: bool = true,
	log_debug: bool = false
) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	if enemy == null or not is_instance_valid(enemy):
		return path

	var goal_tiles := _get_attack_goal_tiles(target_tile, enemy.get_attack_offsets())
	path = _find_path_to_nearest_goal(
		enemy.grid_position,
		goal_tiles,
		enemy,
		true,
		treat_other_enemies_as_blocked
	)

	var found_goal := not path.is_empty()
	var best_goal_tile := path[path.size() - 1] if found_goal else Vector2i.ZERO
	if log_debug:
		_debug_log_enemy_path(enemy, best_goal_tile, path, found_goal)
	return path


func _grid_to_world_center(tile: Vector2i) -> Vector2:
	@warning_ignore("integer_division")
	return Vector2(tile * TILE_SIZE) + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)


func _move_enemy_one_tile(enemy: Enemy, next_tile: Vector2i) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	if not _can_move_to_tile(next_tile, enemy):
		return false

	if debug_enemy_step_logging:
		var step_hazard := String(get_hazard_at(next_tile).get("type", ""))
		if step_hazard.is_empty():
			print("Enemy step ", enemy.name, ": ", enemy.grid_position, " -> ", next_tile)
		else:
			print("Enemy step ", enemy.name, ": ", enemy.grid_position, " -> ", next_tile, " through ", step_hazard)

	var target_position := _grid_to_world_center(next_tile)
	if enemy_step_duration > 0.0:
		var tween := create_tween()
		tween.tween_property(enemy, "position", target_position, enemy_step_duration)
		await tween.finished
		if enemy == null or not is_instance_valid(enemy):
			return false

	enemy.set_grid_position(next_tile)
	_rebuild_enemy_threat_map()
	_resolve_entity_tile_entry(enemy)
	if enemy == null or not is_instance_valid(enemy):
		return false

	return true


func _move_enemy_along_path(enemy: Enemy, path: Array[Vector2i], movement_allowance: int) -> int:
	if enemy == null or not is_instance_valid(enemy):
		return 0
	if movement_allowance <= 0 or path.is_empty():
		return 0

	var steps_taken := 0
	for next_tile in path:
		if steps_taken >= movement_allowance:
			break
		if not await _move_enemy_one_tile(enemy, next_tile):
			break

		steps_taken += 1
		if enemy == null or not is_instance_valid(enemy):
			break
		if enemy.state == Enemy.State.DEFEATED:
			break

	return steps_taken


func _debug_log_enemy_path(enemy: Enemy, goal_tile: Vector2i, path: Array[Vector2i], found_goal: bool) -> void:
	if not debug_enemy_pathfinding or enemy == null or not is_instance_valid(enemy):
		return

	if not found_goal:
		print("Enemy path ", enemy.name, ": no route")
		return

	var step_text: Array[String] = []
	for tile in path:
		step_text.append(str(tile))
	print("Enemy path ", enemy.name, " -> ", goal_tile, ": ", " -> ".join(step_text))


func _move_entity_to_tile(entity, target: Vector2i) -> bool:
	if not _can_move_to_tile(target, entity):
		return false
	entity.set_grid_position(target)
	if mode == GameMode.EXPLORATION:
		_rebuild_enemy_threat_map()
	return true


func _move_player_one_tile(target: Vector2i) -> bool:
	if player_move_in_progress:
		return false
	if not _can_move_to_tile(target, player):
		return false

	player_move_in_progress = true
	if debug_player_step_logging:
		var step_hazard := String(get_hazard_at(target).get("type", ""))
		if step_hazard.is_empty():
			print("Player step: ", player.grid_position, " -> ", target)
		else:
			print("Player step: ", player.grid_position, " -> ", target, " through ", step_hazard)

	var start_tile: Vector2i= player.grid_position
	var target_position := _grid_to_world_center(target)
	_reserve_exploration_motion(player, start_tile, target)
	player.set_grid_position(target, false)
	exploration_active_presentations += 1
	_refresh_exploration_state()
	if player_step_duration > 0.0:
		var tween := create_tween()
		tween.tween_property(player, "position", target_position, player_step_duration)
		await tween.finished

	player.position = target_position
	exploration_active_presentations = max(exploration_active_presentations - 1, 0)
	_clear_exploration_reservations_for(player)
	_resolve_entity_tile_entry(player)
	if player.hp <= 0:
		player_move_in_progress = false
		_refresh_exploration_state()
		_finish_environment_message("You were overwhelmed.")
		mode = GameMode.DEFEAT
		_refresh_ui()
		queue_redraw()
		return true
	_rebuild_enemy_threat_map()
	_resolve_exploration_detection("player_move")
	player_move_in_progress = false
	_flush_pending_exploration_transition_if_ready()
	_refresh_exploration_state()
	return true


func _try_combat_move(direction: Vector2i) -> void:
	if current_energy <= 0 or movement_left <= 0:
		message = "No movement left this turn."
		_update_message()
		return

	var target: Vector2i = player.grid_position + direction
	if not await _move_player_one_tile(target):
		return

	current_energy -= 1
	movement_left -= 1
	message = _consume_environment_messages("Moved to %s." % [str(player.grid_position)])
	_update_all_enemy_intent()
	_refresh_ui()
	queue_redraw()


func _start_combat(trigger_enemy: Enemy = null, trigger_reason: String = "") -> void:
	exploration_pending_combat = false
	exploration_combat_trigger_enemy = trigger_enemy
	exploration_combat_trigger_reason = trigger_reason
	exploration_reserved_tiles.clear()
	_pause_exploration_enemy_schedules(true)
	mode = GameMode.COMBAT
	_rebuild_enemy_threat_map()
	combat_turn = 1
	message = _consume_environment_messages("Combat started. Draw 1 each turn, but your hand persists.")
	_begin_player_turn(false)


func _begin_player_turn(draw_card: bool = true) -> void:
	enemy_turn_in_progress = false
	player_move_in_progress = false
	exploration_reserved_tiles.clear()
	player.reset_turn_state()
	current_energy = max_energy
	movement_left = PLAYER_SPEED
	
	if draw_card:
		_draw_cards_with_shared_rules(1)
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
	enemy_turn_in_progress = true
	_refresh_ui()
	queue_redraw()
	await _enemy_take_turn()
	enemy_turn_in_progress = false
	if mode != GameMode.COMBAT:
		_refresh_ui()
		queue_redraw()
		return

	combat_turn += 1
	_begin_player_turn(true)
	if not must_resolve_overflow:
		message = "Turn %d. Spend energy on movement or cards." % combat_turn
	_update_message()


func _get_enemy_combat_turn_order() -> Array[Enemy]:
	var ordered_enemies: Array[Enemy] = []

	for enemy in enemies:
		if enemy == null or not is_instance_valid(enemy):
			continue

		var enemy_distance : float = abs(enemy.grid_position.x - player.grid_position.x) + abs(enemy.grid_position.y - player.grid_position.y)
		var insert_at := ordered_enemies.size()

		for index in range(ordered_enemies.size()):
			var other_enemy := ordered_enemies[index]
			var other_distance :float = abs(other_enemy.grid_position.x - player.grid_position.x) + abs(other_enemy.grid_position.y - player.grid_position.y)
			if enemy_distance < other_distance:
				insert_at = index
				break

		ordered_enemies.insert(insert_at, enemy)

	return ordered_enemies


func _enemy_take_turn() -> void:
	for e in _get_enemy_combat_turn_order():
		if e == null or not is_instance_valid(e):
			continue

		if player.grid_position in e.get_threatened_tiles():
			player.take_damage(e.damage)
			if player.hiding:
				player.become_hidden_or_revealed()
			message = "Enemy attacks for %d." % e.damage
		else:
			var path := _find_enemy_path_to_target(e, player.grid_position, true, true)
			if not path.is_empty():
				message = "Enemy advances."
				_update_message()
			var moved_steps := await _move_enemy_along_path(e, path, e.get_movement_allowance())
			if moved_steps > 0:
				message = _consume_environment_messages(message)
			elif path.is_empty():
				message = _consume_environment_messages("Enemy holds position.")
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
	if _is_input_locked():
		return
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
	var target_enemy := current_target as Enemy
	var damage := _modify_attack_damage(6)
	current_target.take_damage(damage)
	if mode == GameMode.EXPLORATION and target_enemy != null and is_instance_valid(target_enemy):
		_try_player_initiated_exploration_combat(target_enemy, "player_strike")
	return {"success": true, "message": "Dealt %d damage." % damage}


func _play_block() -> Dictionary:
	player.gain_block(5)
	return {"success": true, "message": "Gained 5 block."}


func _play_lunge() -> Dictionary:
	if not _has_valid_target():
		return {"success": false, "message": "No target selected."}

	var player_moved := false
	var target_enemy := current_target as Enemy
	var direction := _step_toward(player.grid_position, current_target.grid_position)
	if direction != Vector2i.ZERO:
		var lunge_tile: Vector2i = player.grid_position + direction
		if lunge_tile != current_target.grid_position and _move_entity_to_tile(player, lunge_tile):
			_resolve_entity_tile_entry(player)
			_rebuild_enemy_threat_map()
			player_moved = true
	if _is_adjacent(player.grid_position, current_target.grid_position):
		var lunge_damage := _modify_attack_damage(6)
		current_target.take_damage(lunge_damage)
		if mode == GameMode.EXPLORATION and target_enemy != null and is_instance_valid(target_enemy):
			_try_player_initiated_exploration_combat(target_enemy, "player_lunge")
		return {"success": true, "message": _consume_environment_messages("Closed in and dealt %d damage." % lunge_damage)}
	if player_moved and mode == GameMode.EXPLORATION:
		_resolve_exploration_detection("player_lunge_move")
		_flush_pending_exploration_transition_if_ready()
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
	_resolve_entity_tile_entry(player)
	_resolve_entity_tile_entry(current_target)
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
	exploration_pending_combat = false
	exploration_combat_trigger_enemy = null
	exploration_combat_trigger_reason = ""
	exploration_reserved_tiles.clear()
	_pause_exploration_enemy_schedules(false)
	_set_current_target(null)
	_rebuild_enemy_threat_map()
	_refresh_exploration_state()
	message = _consume_environment_messages("")
	_update_message()


func _update_enemy_intent(e: Enemy) -> void:
	if e == null or not is_instance_valid(e):
		return
	if mode == GameMode.COMBAT:
		if _is_adjacent(player.grid_position, e.grid_position):
			e.set_intent_text("Attack %d" % e.damage)
		elif _find_enemy_path_to_target(e, player.grid_position, true).is_empty():
			e.set_intent_text("Hold")
		else:
			e.set_intent_text("Advance")
	else:
		match e.awareness_state:
			Enemy.AwarenessState.ALERT:
				e.set_intent_text("Alert")
			Enemy.AwarenessState.SUSPICIOUS:
				e.set_intent_text("Suspicious")
			_:
				if e.has_patrol_route():
					e.set_intent_text("Patrol")
				elif e.has_rotation_route():
					e.set_intent_text("Rotate")
				else:
					e.set_intent_text("Hold")


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
		button.disabled = mode == GameMode.DEFEAT or mode == GameMode.VICTORY or _is_input_locked()
		button.pressed.connect(func() -> void: _handle_card_shortcut(card_index))
		hand_box.add_child(button)


func _update_message() -> void:
	center_message.text = message


func _controls_text() -> String:
	match mode:
		GameMode.EXPLORATION:
			match exploration_state:
				ExplorationState.PLAYER_ACTION_RESOLVING:
					return "Resolving your exploration action."
				ExplorationState.ENEMY_ACTION_RESOLVING:
					return "Enemies are resolving their patrols."
				ExplorationState.TRANSITIONING_TO_COMBAT:
					return "Transitioning to combat."
				_:
					return "Explore with arrow keys/WASD. Press . or X to wait. Number keys can play any usable card."
		GameMode.COMBAT:
			if enemy_turn_in_progress:
				return "Enemy turn: movement resolves one tile at a time."
			if player_move_in_progress:
				return "Movement in progress."
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

		var tiles := f.get_threatened_tiles() if mode == GameMode.COMBAT else _get_enemy_detection_tiles(f)
		for tile in tiles:
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


func _draw_cards_with_shared_rules(count: int) -> Array[Dictionary]:
	var drawn := deck_manager.draw_cards(count)
	must_resolve_overflow = deck_manager.hand.size() > 5
	return drawn


func resolve_draw_pickup(draw_count: int) -> void:
	var drawn := _draw_cards_with_shared_rules(draw_count)
	if drawn.is_empty():
		pending_environment_messages.append("Draw %d pickup triggered, but there were no cards to draw." % draw_count)
	elif drawn.size() < draw_count:
		pending_environment_messages.append("Draw %d pickup triggered and drew %d card(s)." % [draw_count, drawn.size()])
	else:
		pending_environment_messages.append("Draw %d pickup triggered." % draw_count)

	if must_resolve_overflow:
		pending_environment_messages.append("Hand overflow: play or discard a card.")


func _resolve_entity_tile_entry(entity) -> void:
	if entity == null or not is_instance_valid(entity):
		return

	_apply_on_enter_tile_effects(entity, entity.grid_position)
	if entity == player:
		_resolve_tile_triggers(player)


func _resolve_tile_triggers(entered_player) -> void:
	if entered_player == null or not is_instance_valid(entered_player):
		return

	var tile_triggers := _get_tile_triggers(entered_player.grid_position)
	for trigger in tile_triggers:
		if trigger == null or not is_instance_valid(trigger):
			continue
		trigger.on_player_enter(entered_player, self)


func _get_tile_triggers(tile: Vector2i) -> Array:
	var triggers: Array = []
	var obj = get_object_at(tile)
	if obj == null or not is_instance_valid(obj):
		return triggers
	if obj.triggers_on_player_enter():
		triggers.append(obj)
	return triggers


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

#Exploration Logic --------------------------
func build_linear_patrol_points(
	start: Vector2i,
	direction: Vector2i,
	distance: int
) -> Array[Vector2i]:
	var points: Array[Vector2i] = []
	var dir := direction.sign()

	if abs(dir.x) + abs(dir.y) != 1:
		push_error("Direction must be cardinal.")
		return points

	points.append(start)

	for i in range(1, distance + 1):
		var point: Vector2i = start + dir * i
		if not _is_tile_walkable(point, null, false, false):
			break
		points.append(point)

	return points


func setup_enemy_patrol(
	enemy: Enemy,
	start: Vector2i,
	direction: Vector2i,
	distance: int,
	patrol_mode: Enemy.Patrol_Mode
) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return

	var facing := direction.sign()
	if abs(facing.x) + abs(facing.y) != 1:
		facing = enemy.facing_dir

	enemy.clear_patrol()
	enemy.clear_rotation_route()
	enemy.patrol_mode = patrol_mode
	enemy.facing_dir = facing

	match patrol_mode:
		Enemy.Patrol_Mode.SENTRY:
			enemy.patrol_points = [start]
		Enemy.Patrol_Mode.PINGPONG, Enemy.Patrol_Mode.LOOP:
			enemy.patrol_points = build_linear_patrol_points(start, facing, distance)

	if enemy.patrol_points.is_empty():
		enemy.patrol_points = [start]

	enemy.patrol_index = 0
	enemy.patrol_forward = true


func setup_enemy_rotation_sentry(enemy: Enemy, directions: Array[Vector2i]) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return

	enemy.clear_patrol()
	enemy.patrol_mode = Enemy.Patrol_Mode.SENTRY
	enemy.set_rotation_route(directions)


func _start_exploration_enemy_schedules() -> void:
	for enemy in enemies:
		_ensure_enemy_exploration_timer(enemy)
	_pause_exploration_enemy_schedules(false)


func _ensure_enemy_exploration_timer(enemy: Enemy) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return

	var timer := exploration_enemy_timers.get(enemy, null) as Timer
	if timer == null or not is_instance_valid(timer):
		timer = Timer.new()
		timer.one_shot = false
		timer.autostart = false
		timer.timeout.connect(_on_enemy_exploration_timer_timeout.bind(enemy))
		add_child(timer)
		exploration_enemy_timers[enemy] = timer

	timer.wait_time = max(enemy.exploration_cadence, 0.05)
	if mode == GameMode.EXPLORATION and timer.is_stopped():
		timer.start()


func _remove_enemy_exploration_timer(enemy: Enemy) -> void:
	if not exploration_enemy_timers.has(enemy):
		return
	var timer := exploration_enemy_timers[enemy] as Timer
	exploration_enemy_timers.erase(enemy)
	if timer != null and is_instance_valid(timer):
		timer.stop()
		timer.queue_free()


func _on_enemy_exploration_timer_timeout(enemy: Enemy) -> void:
	if mode != GameMode.EXPLORATION or exploration_pending_combat:
		return
	if enemy == null or not is_instance_valid(enemy):
		return
	if enemy.exploration_action_in_progress or enemy.state != Enemy.State.ALIVE:
		return
	await _resolve_enemy_exploration_action(enemy)


func _resolve_enemy_exploration_action(enemy: Enemy) -> void:
	if mode != GameMode.EXPLORATION or exploration_pending_combat:
		return
	if enemy == null or not is_instance_valid(enemy):
		return
	if enemy.exploration_action_in_progress:
		return

	var action := _build_enemy_exploration_action(enemy)
	if action.is_empty():
		return

	enemy.exploration_action_in_progress = true
	match String(action.get("kind", "")):
		"move":
			await _move_enemy_exploration_one_tile(enemy, Vector2i(action["to"]))
			if enemy != null and is_instance_valid(enemy) and enemy.grid_position == action["target"]:
				enemy.advance_patrol_index()
		"rotate":
			await _rotate_enemy_in_place(enemy, Vector2i(action["facing"]))
	if enemy == null or not is_instance_valid(enemy):
		return
	enemy.exploration_action_in_progress = false
	_update_enemy_intent(enemy)


func _build_enemy_exploration_action(enemy: Enemy) -> Dictionary:
	var move_action := _build_enemy_patrol_action(enemy)
	if not move_action.is_empty():
		return move_action

	var rotate_action := _build_enemy_rotation_action(enemy)
	if not rotate_action.is_empty():
		return rotate_action

	return {}


func _build_enemy_patrol_action(enemy: Enemy) -> Dictionary:
	var action: Dictionary = {}
	if enemy == null or not is_instance_valid(enemy):
		return action
	if not enemy.can_patrol():
		return action

	var target := enemy.get_current_patrol_target()
	if enemy.grid_position == target:
		enemy.advance_patrol_index()
		target = enemy.get_current_patrol_target()
	if enemy.grid_position == target:
		return action

	var path := _find_bfs_path(enemy.grid_position, target, enemy, true, true)
	if path.is_empty():
		return action

	var next_tile: Vector2i = path[0]
	if not _can_move_to_tile(next_tile, enemy):
		return action

	action["kind"] = "move"
	action["to"] = next_tile
	action["target"] = target
	return action


func _build_enemy_rotation_action(enemy: Enemy) -> Dictionary:
	var action: Dictionary = {}
	if enemy == null or not is_instance_valid(enemy):
		return action
	if not enemy.can_rotate_in_place():
		return action

	enemy.advance_look_direction()
	var next_facing := enemy.get_current_look_direction()
	if next_facing == enemy.facing_dir:
		return action

	action["kind"] = "rotate"
	action["facing"] = next_facing
	return action


func _move_enemy_exploration_one_tile(enemy: Enemy, next_tile: Vector2i) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	if not _can_move_to_tile(next_tile, enemy):
		return false

	var start_tile := enemy.grid_position
	var delta := next_tile - start_tile
	if delta != Vector2i.ZERO:
		enemy.facing_dir = delta

	if debug_enemy_step_logging:
		var step_hazard := String(get_hazard_at(next_tile).get("type", ""))
		if step_hazard.is_empty():
			print("Enemy exploration step ", enemy.name, ": ", start_tile, " -> ", next_tile)
		else:
			print("Enemy exploration step ", enemy.name, ": ", start_tile, " -> ", next_tile, " through ", step_hazard)

	var target_position := _grid_to_world_center(next_tile)
	_reserve_exploration_motion(enemy, start_tile, next_tile)
	enemy.set_grid_position(next_tile, false)
	exploration_active_presentations += 1
	_refresh_exploration_state()

	if enemy_step_duration > 0.0:
		var tween := create_tween()
		tween.tween_property(enemy, "position", target_position, enemy_step_duration)
		await tween.finished

	exploration_active_presentations = max(exploration_active_presentations - 1, 0)
	_clear_exploration_reservations_for(enemy)
	if enemy == null or not is_instance_valid(enemy):
		_refresh_exploration_state()
		return false

	enemy.position = target_position
	_resolve_entity_tile_entry(enemy)
	_rebuild_enemy_threat_map()
	_resolve_exploration_detection("enemy_move", enemy)
	_flush_pending_exploration_transition_if_ready()
	_refresh_exploration_state()
	var resolved_message := _consume_environment_messages("")
	if not resolved_message.is_empty():
		message = resolved_message
	_update_message()
	_refresh_ui()
	queue_redraw()
	return true


func _rotate_enemy_in_place(enemy: Enemy, facing: Vector2i) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	if facing == enemy.facing_dir:
		return false

	exploration_active_presentations += 1
	_refresh_exploration_state()

	if enemy_rotation_duration > 0.0:
		var timer := get_tree().create_timer(enemy_rotation_duration)
		await timer.timeout

	exploration_active_presentations = max(exploration_active_presentations - 1, 0)
	if enemy == null or not is_instance_valid(enemy):
		_refresh_exploration_state()
		return false

	enemy.facing_dir = facing
	_rebuild_enemy_threat_map()
	_resolve_exploration_detection("enemy_rotate", enemy)
	_flush_pending_exploration_transition_if_ready()
	_refresh_exploration_state()
	_refresh_ui()
	queue_redraw()
	return true


func _reserve_exploration_motion(actor, from_tile: Vector2i, to_tile: Vector2i) -> void:
	_clear_exploration_reservations_for(actor)
	exploration_reserved_tiles[from_tile] = actor
	exploration_reserved_tiles[to_tile] = actor


func _clear_exploration_reservations_for(actor) -> void:
	var reserved_tiles: Array[Vector2i] = []
	for tile in exploration_reserved_tiles.keys():
		if exploration_reserved_tiles[tile] == actor:
			reserved_tiles.append(tile)
	for tile in reserved_tiles:
		exploration_reserved_tiles.erase(tile)


func _is_tile_reserved_by_other(tile: Vector2i, actor = null) -> bool:
	if not exploration_reserved_tiles.has(tile):
		return false
	return exploration_reserved_tiles[tile] != actor


func _resolve_exploration_detection(trigger_kind: String, preferred_enemy: Enemy = null) -> bool:
	if mode != GameMode.EXPLORATION or exploration_pending_combat:
		return false

	var triggering_enemy: Enemy = null
	if preferred_enemy != null and is_instance_valid(preferred_enemy) and _enemy_detects_player(preferred_enemy):
		triggering_enemy = preferred_enemy
	else:
		for enemy in enemies:
			if enemy == null or not is_instance_valid(enemy):
				continue
			if _enemy_detects_player(enemy):
				triggering_enemy = enemy
				break

	if triggering_enemy == null:
		return false

	_queue_exploration_combat_transition(triggering_enemy, "enemy_detection:%s" % trigger_kind)
	return true


func _try_player_initiated_exploration_combat(target_enemy: Enemy, reason: String) -> bool:
	if mode != GameMode.EXPLORATION:
		return false
	if target_enemy == null or not is_instance_valid(target_enemy):
		return false
	if target_enemy.state != Enemy.State.ALIVE:
		return false

	_queue_exploration_combat_transition(target_enemy, reason)
	_flush_pending_exploration_transition_if_ready()
	return true


func _queue_exploration_combat_transition(trigger_enemy: Enemy, trigger_reason: String) -> void:
	if exploration_pending_combat:
		return
	exploration_pending_combat = true
	exploration_combat_trigger_enemy = trigger_enemy
	exploration_combat_trigger_reason = trigger_reason
	_refresh_exploration_state()


func _flush_pending_exploration_transition_if_ready() -> void:
	if not exploration_pending_combat:
		return
	if mode != GameMode.EXPLORATION:
		return
	if exploration_active_presentations > 0 or player_move_in_progress:
		return

	_start_combat(exploration_combat_trigger_enemy, exploration_combat_trigger_reason)


func _enemy_detects_player(enemy: Enemy) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	return player.grid_position in _get_enemy_detection_tiles(enemy)


func _is_detection_tile_visible(
	origin: Vector2i,
	forward: Vector2i,
	right: Vector2i,
	target_tile: Vector2i
) -> bool:
	if not _is_in_bounds(target_tile):
		return false

	var delta := target_tile - origin
	var forward_distance := delta.x * forward.x + delta.y * forward.y
	if forward_distance <= 0:
		return false

	var side_distance := delta.x * right.x + delta.y * right.y
	var side_sign := int(sign(side_distance))
	var side_steps : int = abs(side_distance)

	for step_forward in range(1, forward_distance + 1):
		var center_tile := origin + forward * step_forward
		if terrain_blocks_vision(center_tile):
			return false

		if side_steps <= 0:
			continue

		var side_lane_tile := center_tile + right * side_sign * side_steps
		if terrain_blocks_vision(side_lane_tile):
			return false

	return true


func _get_enemy_detection_tiles(enemy: Enemy) -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	if enemy == null or not is_instance_valid(enemy):
		return tiles

	var forward := enemy.facing_dir.sign()
	if abs(forward.x) + abs(forward.y) != 1:
		forward = Vector2i.LEFT
	var right := Vector2i(-forward.y, forward.x)

	for distance in range(1, enemy.exploration_detection_range + 1):
		var center := enemy.grid_position + forward * distance
		if not _is_detection_tile_visible(enemy.grid_position, forward, right, center):
			break

		tiles.append(center)

		var side_reach :int = min(enemy.exploration_side_vision, max(distance - 1, 0))
		for side_index in range(1, side_reach + 1):
			var left_tile := center - right * side_index
			if _is_detection_tile_visible(enemy.grid_position, forward, right, left_tile):
				tiles.append(left_tile)

			var right_tile := center + right * side_index
			if _is_detection_tile_visible(enemy.grid_position, forward, right, right_tile):
				tiles.append(right_tile)

	return tiles
