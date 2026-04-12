extends Node2D

const TILE_SIZE := 48
const GRID_SIZE := Vector2i(10, 7)
const PLAYER_SPEED := 3
const HAND_LIMIT := 5
const CARDINAL_DIRECTIONS: Array[Vector2i] = [
	Vector2i.UP,
	Vector2i.RIGHT,
	Vector2i.DOWN,
	Vector2i.LEFT
]
const DIRECTIONAL_PROJECTILE_TARGETING := "directional_projectile"
const PROJECTILE_PREVIEW_FILL_COLOR := Color(0.886275, 0.729412, 0.262745, 0.22)
const PROJECTILE_PREVIEW_BORDER_COLOR := Color(1.0, 0.827451, 0.27451, 0.9)

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

const NEXT_MANUAL_MOVE_MODIFIER_DEFS := {
	"dash": {
		"id": "dash",
		"bonus_distance": 1,
		"ignore_intermediate_hazards": true,
		"check_detection_only_on_final_tile": true
	}
}

const DeckManagerScript := preload("res://scripts/DeckManager.gd")
const CardDatabaseScript := preload("res://scripts/CardDatabase.gd")
const CrateObjectScene := preload("res://scenes/CrateObject.tscn")
const DrawPickupScene := preload("res://scenes/DrawPickup.tscn")
const RewardPickupScene := preload("res://scenes/RewardPickup.tscn")
const ReplayTileScene := preload("res://scenes/ReplayTile.tscn")
const RewardChoiceUIScene := preload("res://scenes/RewardChoiceUI.tscn")
const ENEMY_COMBAT_PLAN_HOLD: StringName = &"hold"
const ENEMY_COMBAT_PLAN_PLAYER: StringName = &"player"
const ENEMY_COMBAT_PLAN_DESTRUCTIBLE_OBJECT: StringName = &"destructible_object"
const REPLAY_TILE_GRID_POSITION := Vector2i(9, 3)

enum GameMode {
	EXPLORATION,
	POST_COMBAT_REWARD,
	COMBAT_TRANSITION,
	COMBAT,
	REWARD_CHOICE,
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
@export_range(0.0, 1.0, 0.01) var combat_transition_prompt_delay: float = 0.7

@onready var player = $Player

@onready var mode_label: Label = $CanvasLayer/HUD/Root/TopBar/ModeLabel
@onready var stats_label: Label = $CanvasLayer/HUD/Root/TopBar/StatsLabel
@onready var combat_banner: Label = $CanvasLayer/HUD/Root/CombatBanner
@onready var center_message: Label = $CanvasLayer/HUD/Root/CenterMessage
@onready var hand_box: HBoxContainer = $CanvasLayer/HUD/Root/HandPanel/HandMargin/HandBox
@onready var controls_label: Label = $CanvasLayer/HUD/Root/ControlsLabel

var deck_manager = DeckManagerScript.new()
var mode: int = GameMode.EXPLORATION
var combat_turn: int = 0
var current_energy: int = 0
var max_energy: int = 3
var movement_left: int = PLAYER_SPEED
var must_resolve_overflow: bool = false
var message: String = "Move with arrow keys or WASD."
var enemies: Array[Enemy] = []
@export var targets: Array[Node2D] = []
var threatened_tiles: Dictionary = {}
@export var current_target: Node2D = null
var terrain_layer: Dictionary = {}
var hazard_layer: Dictionary = {}
var object_layer: Dictionary = {}
var pending_environment_messages: Array[String] = []
var enemy_turn_in_progress: bool = false
var player_move_in_progress: bool = false
var exploration_state: int = ExplorationState.WAITING_FOR_PLAYER_INPUT
var exploration_reserved_tiles: Dictionary = {}
var exploration_enemy_timers: Dictionary = {}
var exploration_active_presentations: int = 0
var exploration_pending_combat: bool = false
var exploration_combat_trigger_enemy: Enemy = null
var exploration_combat_trigger_reason: String = ""
var combat_transition_running: bool = false
var combat_transition_can_start: bool = false
var suppress_next_move_input: bool = false
var next_manual_move_modifiers: Array[Dictionary] = []
var pending_directional_card_index: int = -1
var pending_directional_card: Dictionary = {}
var directional_projectile_preview: Dictionary = {}
var resolving_player_card: bool = false
var active_reward_pickup: RewardPickup = null
var active_reward_options: Array[Dictionary] = []
var reward_choice_ui: RewardChoiceUI = null
var reward_choice_return_mode: int = GameMode.EXPLORATION
var initial_level_snapshot: Dictionary = {}
var active_replay_tile: ReplayTile = null
var replay_reset_in_progress := false
var replay_reset_completed_this_step := false
var interrupt_player_path_after_step := false


func mark_threat_tile(tile: Vector2i) -> void:
	threatened_tiles[tile] = true


func clear_threat_tiles() -> void:
	threatened_tiles.clear()


func _request_player_path_interrupt() -> void:
	interrupt_player_path_after_step = true


func _consume_player_path_interrupt() -> bool:
	var should_interrupt := interrupt_player_path_after_step
	interrupt_player_path_after_step = false
	return should_interrupt


func is_tile_threatened(tile: Vector2i) -> bool:
	return threatened_tiles.has(tile)


func is_player_in_threat() -> bool:
	return is_tile_threatened(player.grid_position)


func _has_next_manual_move_modifier() -> bool:
	return not next_manual_move_modifiers.is_empty()


func _get_next_manual_move_effect_preview() -> Dictionary:
	var aggregated: Dictionary = {
		"armed": false,
		"bonus_distance": 0,
		"ignore_intermediate_hazards": false,
		"check_detection_only_on_final_tile": false
	}

	for modifier in next_manual_move_modifiers:
		aggregated["armed"] = true
		aggregated["bonus_distance"] = int(aggregated["bonus_distance"]) + int(modifier.get("bonus_distance", 0))
		aggregated["ignore_intermediate_hazards"] = bool(aggregated["ignore_intermediate_hazards"]) or bool(modifier.get("ignore_intermediate_hazards", false))
		aggregated["check_detection_only_on_final_tile"] = bool(aggregated["check_detection_only_on_final_tile"]) or bool(modifier.get("check_detection_only_on_final_tile", false))

	return aggregated


func _consume_next_manual_move_effect() -> Dictionary:
	var effect := _get_next_manual_move_effect_preview()
	if _has_next_manual_move_modifier():
		_clear_next_manual_move_modifiers()
	return effect


func _clear_next_manual_move_modifiers() -> void:
	if next_manual_move_modifiers.is_empty():
		return
	next_manual_move_modifiers.clear()
	queue_redraw()


func _arm_next_manual_move_modifier(modifier_id: String) -> bool:
	var modifier_def: Dictionary = NEXT_MANUAL_MOVE_MODIFIER_DEFS.get(modifier_id, {})
	if modifier_def.is_empty():
		return false

	next_manual_move_modifiers.append(modifier_def.duplicate(true))
	queue_redraw()
	return true


func _set_exploration_state(next_state: int) -> void:
	exploration_state = next_state


func _is_world_movement_mode() -> bool:
	return mode == GameMode.EXPLORATION or mode == GameMode.POST_COMBAT_REWARD


func _rebuild_enemy_threat_map() -> void:
	_build_threat_map(enemies)


func _refresh_exploration_state() -> void:
	if not _is_world_movement_mode():
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
	_setup_reward_choice_ui()
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
	capture_initial_level_state()
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


func _setup_reward_choice_ui() -> void:
	reward_choice_ui = RewardChoiceUIScene.instantiate() as RewardChoiceUI
	reward_choice_ui.reward_confirmed.connect(_on_reward_confirmed)
	$CanvasLayer.add_child(reward_choice_ui)


func _setup_environment_layers() -> void:
	terrain_layer.clear()
	hazard_layer.clear()

	for tile in object_layer.keys():
		remove_object_at(tile)
	object_layer.clear()

	_set_terrain(Vector2i(4, 2), "wall")
	_set_terrain(Vector2i(4, 3), "wall")
	_set_terrain(Vector2i(4, 4), "wall")
	_set_terrain(Vector2i(7, 1), "wall")
	_set_terrain(Vector2i(5, 1), "wall")
	_set_terrain(Vector2i(6, 2), "wall")
	_set_terrain(Vector2i(7, 0), "wall")
	#_set_terrain(Vector2i(5, 0), "wall")

	_set_hazard(Vector2i(2, 1), "fire")
	_set_hazard(Vector2i(7, 5), "fire")

	var crate := CrateObjectScene.instantiate()
	crate = CrateObjectScene.instantiate()
	add_object(crate, Vector2i(6, 0))
	crate = CrateObjectScene.instantiate()
	add_object(crate, Vector2i(5, 0))

	var draw_pickup := DrawPickupScene.instantiate()
	add_object(draw_pickup, Vector2i(2, 3))


func capture_initial_level_state() -> void:
	initial_level_snapshot = {
		"player_start_tile": player.grid_position,
		"terrain_layer": _duplicate_grid_data_dictionary(terrain_layer),
		"hazard_layer": _duplicate_grid_data_dictionary(hazard_layer),
		"enemy_spawns": _capture_enemy_snapshots(),
		"environment_objects": _capture_environment_object_snapshots()
	}


func reset_level_to_initial_state() -> void:
	if initial_level_snapshot.is_empty():
		push_warning("Cannot replay level before an initial level snapshot has been captured.")
		return

	replay_reset_in_progress = true
	_close_reward_choice()
	_remove_active_replay_tile()
	_clear_pending_directional_card(false)
	_clear_next_manual_move_modifiers()
	_clear_combat_runtime_state()
	_clear_exploration_runtime_state()
	_clear_current_level_entities()
	_restore_environment_from_snapshot()

	var player_start_tile: Vector2i = initial_level_snapshot.get("player_start_tile", player.grid_position)
	player.set_grid_position(player_start_tile)
	_clear_player_level_local_state()

	mode = GameMode.EXPLORATION
	_spawn_enemies_from_snapshot()
	_rebuild_enemy_threat_map()
	_update_all_enemy_intent()
	_start_exploration_enemy_schedules()
	_refresh_hand_overflow_state()
	_refresh_exploration_state()
	message = "The room resets. Your deck, hand, piles, and health persist."
	replay_reset_completed_this_step = true
	replay_reset_in_progress = false
	_refresh_ui()
	queue_redraw()


func _duplicate_grid_data_dictionary(source: Dictionary) -> Dictionary:
	var copy: Dictionary = {}
	for tile in source.keys():
		var value: Variant = source[tile]
		copy[tile] = value.duplicate(true) if value is Dictionary or value is Array else value
	return copy


func _capture_enemy_snapshots() -> Array[Dictionary]:
	var snapshots: Array[Dictionary] = []
	for enemy in enemies:
		if enemy == null or not is_instance_valid(enemy):
			continue
		snapshots.append(_capture_enemy_snapshot(enemy))
	return snapshots


func _capture_enemy_snapshot(enemy: Enemy) -> Dictionary:
	return {
		"scene_path": _get_scene_path_for_node(enemy, EnemyScene),
		"tile": enemy.grid_position,
		"facing_dir": enemy.facing_dir,
		"hp": enemy.hp,
		"max_hp": enemy.max_hp,
		"damage": enemy.damage,
		"max_energy": enemy.max_energy,
		"movement_energy_cost": enemy.movement_energy_cost,
		"attack_energy_cost": enemy.attack_energy_cost,
		"special_action_energy_cost": enemy.special_action_energy_cost,
		"movement_per_turn": enemy.movement_per_turn,
		"exploration_cadence": enemy.exploration_cadence,
		"exploration_detection_range": enemy.exploration_detection_range,
		"exploration_side_vision": enemy.exploration_side_vision,
		"patrol_mode": enemy.patrol_mode,
		"patrol_points": enemy.patrol_points.duplicate(),
		"patrol_index": enemy.patrol_index,
		"patrol_forward": enemy.patrol_forward,
		"look_directions": enemy.look_directions.duplicate(),
		"look_direction_index": enemy.look_direction_index
	}


func _capture_environment_object_snapshots() -> Array[Dictionary]:
	var snapshots: Array[Dictionary] = []
	for raw_obj in object_layer.values():
		var obj: EnvironmentObject = raw_obj as EnvironmentObject
		if obj == null or not is_instance_valid(obj):
			continue
		if obj is RewardPickup or obj is ReplayTile:
			continue
		snapshots.append(_capture_environment_object_snapshot(obj))
	return snapshots


func _capture_environment_object_snapshot(obj: EnvironmentObject) -> Dictionary:
	var snapshot := {
		"scene_path": _get_environment_object_scene_path(obj),
		"tile": obj.grid_position,
		"hp": obj.hp,
		"max_hp": obj.max_hp,
		"object_type": obj.object_type,
		"blocks_movement": obj.blocks_movement,
		"is_destructible": obj.is_destructible,
		"is_targetable": obj.is_targetable,
		"is_movable": obj.is_movable,
		"facing_dir": obj.facing_dir
	}
	if obj is MapPickup:
		var pickup := obj as MapPickup
		snapshot["consumed"] = pickup.consumed
	return snapshot


func _get_scene_path_for_node(node: Node, fallback_scene: PackedScene = null) -> String:
	var scene_path := String(node.scene_file_path)
	if scene_path.is_empty() and fallback_scene != null:
		scene_path = String(fallback_scene.resource_path)
	return scene_path


func _get_environment_object_scene_path(obj: EnvironmentObject) -> String:
	var scene_path := _get_scene_path_for_node(obj)
	if not scene_path.is_empty():
		return scene_path
	if obj is CrateObject:
		return String(CrateObjectScene.resource_path)
	if obj is DrawPickup:
		return String(DrawPickupScene.resource_path)
	if obj is RewardPickup:
		return String(RewardPickupScene.resource_path)
	if obj is ReplayTile:
		return String(ReplayTileScene.resource_path)
	return ""


func _load_packed_scene(scene_path: String, fallback_scene: PackedScene = null) -> PackedScene:
	if not scene_path.is_empty():
		var loaded := load(scene_path)
		if loaded is PackedScene:
			return loaded as PackedScene
	return fallback_scene


func _clear_combat_runtime_state() -> void:
	combat_turn = 0
	current_energy = max_energy
	movement_left = PLAYER_SPEED
	enemy_turn_in_progress = false
	resolving_player_card = false
	current_target = null
	threatened_tiles.clear()


func _clear_exploration_runtime_state() -> void:
	player_move_in_progress = false
	exploration_reserved_tiles.clear()
	exploration_active_presentations = 0
	exploration_pending_combat = false
	exploration_combat_trigger_enemy = null
	exploration_combat_trigger_reason = ""
	combat_transition_running = false
	combat_transition_can_start = false
	suppress_next_move_input = false
	interrupt_player_path_after_step = false
	pending_environment_messages.clear()
	_set_exploration_state(ExplorationState.WAITING_FOR_PLAYER_INPUT)


func _clear_player_level_local_state() -> void:
	player.reset_turn_state()
	if player.hiding:
		player.become_hidden_or_revealed()


func _clear_current_level_entities() -> void:
	_clear_all_exploration_enemy_timers()
	for enemy in enemies:
		if enemy == null or not is_instance_valid(enemy):
			continue
		enemy.hide()
		enemy.queue_free()
	enemies.clear()
	targets.clear()
	current_target = null
	_clear_all_environment_objects()


func _clear_all_exploration_enemy_timers() -> void:
	for raw_timer in exploration_enemy_timers.values():
		var timer := raw_timer as Timer
		if timer == null or not is_instance_valid(timer):
			continue
		timer.stop()
		timer.queue_free()
	exploration_enemy_timers.clear()


func _clear_all_environment_objects() -> void:
	for raw_obj in object_layer.values():
		var obj := raw_obj as Node
		if obj == null or not is_instance_valid(obj):
			continue
		obj.hide()
		obj.queue_free()
	object_layer.clear()
	active_reward_pickup = null


func _restore_environment_from_snapshot() -> void:
	terrain_layer = _duplicate_grid_data_dictionary(initial_level_snapshot.get("terrain_layer", {}))
	hazard_layer = _duplicate_grid_data_dictionary(initial_level_snapshot.get("hazard_layer", {}))
	_restore_environment_objects_from_snapshot()


func _restore_environment_objects_from_snapshot() -> void:
	var object_snapshots: Array = initial_level_snapshot.get("environment_objects", [])
	for raw_snapshot in object_snapshots:
		var snapshot: Dictionary = raw_snapshot
		var scene := _load_packed_scene(String(snapshot.get("scene_path", "")))
		if scene == null:
			push_warning("Skipping environment object replay snapshot with no scene path.")
			continue
		var obj := scene.instantiate() as EnvironmentObject
		if obj == null:
			push_warning("Skipping environment object replay snapshot that is not an EnvironmentObject.")
			continue
		var tile: Vector2i = snapshot.get("tile", Vector2i.ZERO)
		add_object(obj, tile)
		_apply_environment_object_snapshot(obj, snapshot)


func _apply_environment_object_snapshot(obj: EnvironmentObject, snapshot: Dictionary) -> void:
	obj.hp = int(snapshot.get("hp", obj.hp))
	obj.max_hp = int(snapshot.get("max_hp", obj.max_hp))
	obj.object_type = String(snapshot.get("object_type", obj.object_type))
	obj.blocks_movement = bool(snapshot.get("blocks_movement", obj.blocks_movement))
	obj.is_destructible = bool(snapshot.get("is_destructible", obj.is_destructible))
	obj.is_targetable = bool(snapshot.get("is_targetable", obj.is_targetable))
	obj.is_movable = bool(snapshot.get("is_movable", obj.is_movable))
	obj.facing_dir = snapshot.get("facing_dir", obj.facing_dir)
	if obj is MapPickup:
		var pickup := obj as MapPickup
		pickup.consumed = bool(snapshot.get("consumed", false))
	obj.set_grid_position(snapshot.get("tile", obj.grid_position))
	if obj.is_targetable and not targets.has(obj):
		targets.append(obj)


func _spawn_enemies_from_snapshot() -> void:
	var enemy_snapshots: Array = initial_level_snapshot.get("enemy_spawns", [])
	for raw_snapshot in enemy_snapshots:
		var snapshot: Dictionary = raw_snapshot
		var scene := _load_packed_scene(String(snapshot.get("scene_path", "")), EnemyScene)
		if scene == null:
			push_warning("Skipping enemy replay snapshot with no scene.")
			continue
		var enemy := _spawn_enemy(scene, snapshot.get("tile", Vector2i.ZERO))
		_apply_enemy_snapshot(enemy, snapshot)


func _apply_enemy_snapshot(enemy: Enemy, snapshot: Dictionary) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	enemy.max_hp = int(snapshot.get("max_hp", enemy.max_hp))
	enemy.hp = int(snapshot.get("hp", enemy.max_hp))
	enemy.damage = int(snapshot.get("damage", enemy.damage))
	enemy.max_energy = int(snapshot.get("max_energy", enemy.max_energy))
	enemy.current_energy = enemy.max_energy
	enemy.movement_energy_cost = int(snapshot.get("movement_energy_cost", enemy.movement_energy_cost))
	enemy.attack_energy_cost = int(snapshot.get("attack_energy_cost", enemy.attack_energy_cost))
	enemy.special_action_energy_cost = int(snapshot.get("special_action_energy_cost", enemy.special_action_energy_cost))
	enemy.movement_per_turn = int(snapshot.get("movement_per_turn", enemy.movement_per_turn))
	enemy.exploration_cadence = float(snapshot.get("exploration_cadence", enemy.exploration_cadence))
	enemy.exploration_detection_range = int(snapshot.get("exploration_detection_range", enemy.exploration_detection_range))
	enemy.exploration_side_vision = int(snapshot.get("exploration_side_vision", enemy.exploration_side_vision))
	enemy.patrol_mode = int(snapshot.get("patrol_mode", enemy.patrol_mode))
	enemy.patrol_points = _copy_vector2i_array(snapshot.get("patrol_points", []))
	enemy.patrol_index = int(snapshot.get("patrol_index", 0))
	enemy.patrol_forward = bool(snapshot.get("patrol_forward", true))
	enemy.look_directions = _copy_vector2i_array(snapshot.get("look_directions", []))
	enemy.look_direction_index = int(snapshot.get("look_direction_index", 0))
	enemy.facing_dir = snapshot.get("facing_dir", enemy.facing_dir)
	enemy.state = Enemy.State.ALIVE
	enemy.awareness_state = Enemy.AwarenessState.IDLE
	enemy.exploration_action_in_progress = false
	enemy.set_health_bar_visible(false)
	enemy.set_grid_position(snapshot.get("tile", enemy.grid_position))
	_ensure_enemy_exploration_timer(enemy)


func _copy_vector2i_array(source: Array) -> Array[Vector2i]:
	var copy: Array[Vector2i] = []
	for value in source:
		copy.append(value)
	return copy


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
			_draw_directional_projectile_preview_tile(tile, tile_pos)
			if tile == player.grid_position and _has_next_manual_move_modifier():
				draw_rect(
					Rect2(tile_pos + Vector2.ONE * 3, Vector2.ONE * (TILE_SIZE - 6)),
					Color(0.886275, 0.729412, 0.262745, 0.95),
					false,
					3.0
				)

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


func _draw_directional_projectile_preview_tile(tile: Vector2i, tile_pos: Vector2) -> void:
	if not _is_tile_in_directional_projectile_preview(tile):
		return

	draw_rect(
		Rect2(tile_pos + Vector2.ONE * 4, Vector2.ONE * (TILE_SIZE - 8)),
		PROJECTILE_PREVIEW_FILL_COLOR,
		true
	)
	draw_rect(
		Rect2(tile_pos + Vector2.ONE * 5, Vector2.ONE * (TILE_SIZE - 10)),
		PROJECTILE_PREVIEW_BORDER_COLOR,
		false,
		2.0
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
	if replay_reset_in_progress:
		return true
	if mode == GameMode.COMBAT_TRANSITION or mode == GameMode.REWARD_CHOICE:
		return true
	if _is_world_movement_mode():
		return exploration_pending_combat or player_move_in_progress
	return enemy_turn_in_progress or player_move_in_progress


func _is_movement_locked() -> bool:
	return _is_input_locked()


func _input(event: InputEvent) -> void:
	if mode == GameMode.COMBAT_TRANSITION:
		_handle_combat_transition_input(event)
		return
	if _is_input_locked():
		return

	if _has_pending_directional_card() \
	and event is InputEventMouseButton \
	and event.button_index == MOUSE_BUTTON_RIGHT \
	and event.pressed:
		_cancel_pending_directional_card()
		get_viewport().set_input_as_handled()
		return

	if not _is_world_pointer_select_event(event):
		return

	var screen_pos := _get_world_pointer_screen_position(event)
	if _is_pointer_over_card_ui_at(screen_pos):
		return

	var world_pos := _screen_to_world(screen_pos)
	var clicked_tile := _world_to_grid(world_pos)
	if not _is_in_bounds(clicked_tile):
		return

	if _handle_world_tile_interaction(clicked_tile):
		get_viewport().set_input_as_handled()


func _is_pointer_over_card_ui() -> bool:
	return _is_pointer_over_card_ui_at(get_viewport().get_mouse_position())


func _is_pointer_over_card_ui_at(screen_pos: Vector2) -> bool:
	if hand_box.get_global_rect().has_point(screen_pos):
		return true

	for child in hand_box.get_children():
		if child is Control and child.get_global_rect().has_point(screen_pos):
			return true

	return false


func _unhandled_input(event: InputEvent) -> void:
	if mode == GameMode.COMBAT_TRANSITION:
		_handle_combat_transition_input(event)
		return
	if _is_input_locked():
		return

	if _has_pending_directional_card():
		if event.is_action_pressed("ui_cancel"):
			_cancel_pending_directional_card()
		elif event.is_action_pressed("end_turn") \
		or event.is_action_pressed("card_1") \
		or event.is_action_pressed("card_2") \
		or event.is_action_pressed("card_3") \
		or event.is_action_pressed("card_4") \
		or event.is_action_pressed("card_5"):
			message = "Choose a cardinal throw direction for %s." % pending_directional_card.get("name", "this card")
			_update_message()
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


func _handle_combat_transition_input(event: InputEvent) -> void:
	get_viewport().set_input_as_handled()
	if not combat_transition_can_start:
		return
	if not _is_combat_transition_confirm_event(event):
		return

	combat_transition_can_start = false
	suppress_next_move_input = true
	_start_combat(exploration_combat_trigger_enemy, exploration_combat_trigger_reason)


func _is_combat_transition_confirm_event(event: InputEvent) -> bool:
	if event is InputEventKey:
		return event.pressed and not event.echo
	if event is InputEventMouseButton:
		return event.pressed
	if event is InputEventScreenTouch:
		return event.pressed
	return false


func _world_to_grid(world_pos: Vector2) -> Vector2i:
	return Vector2i(world_pos / TILE_SIZE)


func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_pos


func _is_world_pointer_select_event(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		return event.button_index == MOUSE_BUTTON_LEFT and event.pressed
	if event is InputEventScreenTouch:
		return event.pressed
	return false


func _get_world_pointer_screen_position(event: InputEvent) -> Vector2:
	if event is InputEventMouseButton:
		return event.position
	if event is InputEventScreenTouch:
		return event.position
	return Vector2.ZERO


func _get_targetable_at_world_pos(world_pos: Vector2):
	var grid_pos := _world_to_grid(world_pos)
	return get_targetable_at(grid_pos)


func _handle_world_tile_interaction(clicked_tile: Vector2i) -> bool:
	if _has_pending_directional_card():
		_handle_directional_projectile_click(clicked_tile)
		return true

	var clicked_targetable := get_targetable_at(clicked_tile) as Node2D
	if clicked_targetable != null:
		_set_current_target(clicked_targetable)
		return true

	return _request_player_tile_move(clicked_tile)


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
	if obj.has_signal("reward_requested") and not obj.reward_requested.is_connected(_on_reward_pickup_requested):
		obj.reward_requested.connect(_on_reward_pickup_requested)
	if obj.has_signal("replay_requested") and not obj.replay_requested.is_connected(_on_replay_tile_entered):
		obj.replay_requested.connect(_on_replay_tile_entered)

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


func _make_post_combat_card_reward_options() -> Array[Dictionary]:
	return [
		CardDatabaseScript.make_card("dash"),
		CardDatabaseScript.make_card("throwing_dagger")
	]


func _spawn_post_combat_reward_pickup() -> String:
	var reward_options := _make_post_combat_card_reward_options()
	if reward_options.is_empty():
		return "No reward options were available."

	var spawn_tile := _find_reward_pickup_spawn_tile(player.grid_position)
	if not _is_in_bounds(spawn_tile):
		return "No free tile was available for a reward pickup."

	var reward_pickup := RewardPickupScene.instantiate() as RewardPickup
	reward_pickup.configure(reward_options)
	add_object(reward_pickup, spawn_tile)

	if _is_adjacent(player.grid_position, spawn_tile):
		return "A card reward appeared nearby."
	return "A card reward appeared at the nearest free tile."


func _spawn_replay_tile() -> String:
	_remove_active_replay_tile()
	if not _is_in_bounds(REPLAY_TILE_GRID_POSITION):
		return "Replay tile position is out of bounds."

	var replay_tile := ReplayTileScene.instantiate() as ReplayTile
	if replay_tile == null:
		return "Replay tile scene could not be created."

	add_object(replay_tile, REPLAY_TILE_GRID_POSITION)
	active_replay_tile = replay_tile
	return "A replay tile appeared."


func enter_post_combat_reward_state(recovered_exhausted_count: int = 0) -> void:
	mode = GameMode.POST_COMBAT_REWARD
	_pause_exploration_enemy_schedules(true)
	_refresh_exploration_state()

	message = _consume_environment_messages("")
	if recovered_exhausted_count > 0:
		var recovered_text := "Recovered %d exhausted card(s)." % recovered_exhausted_count
		message = recovered_text if message.is_empty() else "%s %s" % [message, recovered_text]

	var reward_text := _spawn_post_combat_reward_pickup()
	if not reward_text.is_empty():
		message = reward_text if message.is_empty() else "%s %s" % [message, reward_text]

	var replay_text := _spawn_replay_tile()
	if not replay_text.is_empty():
		message = replay_text if message.is_empty() else "%s %s" % [message, replay_text]

	_refresh_ui()
	queue_redraw()


func clear_post_combat_reward_state(remove_reward_pickup: bool = false) -> void:
	_remove_active_replay_tile()
	if remove_reward_pickup and active_reward_pickup != null and is_instance_valid(active_reward_pickup):
		consume_map_pickup(active_reward_pickup)
	active_reward_pickup = null
	if mode == GameMode.POST_COMBAT_REWARD:
		mode = GameMode.EXPLORATION


func _remove_active_replay_tile() -> void:
	if active_replay_tile == null:
		return
	if is_instance_valid(active_replay_tile):
		active_replay_tile.disable()
		consume_map_pickup(active_replay_tile)
	active_replay_tile = null


func _on_replay_tile_entered(_tile: Vector2i) -> void:
	if replay_reset_in_progress:
		return
	if mode != GameMode.POST_COMBAT_REWARD:
		return
	if active_replay_tile != null and is_instance_valid(active_replay_tile):
		active_replay_tile.disable()
	reset_level_to_initial_state()


func _find_reward_pickup_spawn_tile(origin: Vector2i) -> Vector2i:
	for direction in CARDINAL_DIRECTIONS:
		var candidate := origin + direction
		if _is_valid_reward_pickup_spawn_tile(candidate):
			return candidate

	return _find_nearest_reward_pickup_spawn_tile(origin)


func _find_nearest_reward_pickup_spawn_tile(origin: Vector2i) -> Vector2i:
	var max_radius := GRID_SIZE.x + GRID_SIZE.y
	for radius in range(2, max_radius + 1):
		for x in range(GRID_SIZE.x):
			for y in range(GRID_SIZE.y):
				var candidate := Vector2i(x, y)
				if abs(candidate.x - origin.x) + abs(candidate.y - origin.y) != radius:
					continue
				if _is_valid_reward_pickup_spawn_tile(candidate):
					return candidate
	return Vector2i(-1, -1)


func _is_valid_reward_pickup_spawn_tile(tile: Vector2i) -> bool:
	if get_object_at(tile) != null:
		return false
	if not get_hazard_at(tile).is_empty():
		return false
	return _is_tile_walkable(tile, null, true, true)


func _on_reward_pickup_requested(pickup: RewardPickup, reward_options: Array) -> void:
	var typed_options: Array[Dictionary] = []
	for reward in reward_options:
		if reward is Dictionary:
			var reward_dict: Dictionary = reward
			typed_options.append(reward_dict.duplicate(true))
	_open_reward_choice(typed_options, pickup)


func _open_reward_choice(options: Array[Dictionary], source_pickup: RewardPickup = null) -> void:
	if options.is_empty():
		return
	if not _is_world_movement_mode():
		return
	if replay_reset_in_progress:
		return

	reward_choice_return_mode = mode
	active_reward_pickup = source_pickup
	active_reward_options = options.duplicate(true)
	_clear_pending_directional_card(false)
	_pause_exploration_enemy_schedules(true)
	mode = GameMode.REWARD_CHOICE
	message = "Choose a reward."
	if reward_choice_ui != null:
		reward_choice_ui.open(active_reward_options)
	_refresh_ui()
	queue_redraw()


func _on_reward_confirmed(reward: Dictionary) -> void:
	if mode != GameMode.REWARD_CHOICE:
		return
	if replay_reset_in_progress:
		return

	var reward_name := String(reward.get("name", "reward"))
	var returned_from_post_combat := reward_choice_return_mode == GameMode.POST_COMBAT_REWARD
	if not _apply_reward(reward):
		message = "Could not apply %s." % reward_name
		_close_reward_choice()
		if returned_from_post_combat:
			_restore_post_combat_after_reward()
		else:
			_restore_exploration_after_reward()
		return

	_consume_active_reward_pickup()
	_close_reward_choice()
	if returned_from_post_combat:
		_restore_post_combat_after_reward()
	else:
		_restore_exploration_after_reward()

	if must_resolve_overflow:
		message = "Added %s to your deck and hand. Hand overflow: play or discard a card." % reward_name
	else:
		message = "Added %s to your deck and hand." % reward_name
	_refresh_ui()
	queue_redraw()


func _apply_reward(reward: Dictionary) -> bool:
	var reward_type := String(reward.get("type", "card"))
	match reward_type:
		"card":
			return _apply_card_reward(reward)
		_:
			return false


func _apply_card_reward(card: Dictionary) -> bool:
	if card.is_empty():
		return false
	deck_manager.add_card_to_deck(card)
	deck_manager.add_card_to_hand(card)
	_refresh_hand_overflow_state()
	return true


func _refresh_hand_overflow_state() -> void:
	must_resolve_overflow = deck_manager.hand.size() > HAND_LIMIT


func _consume_active_reward_pickup() -> void:
	if active_reward_pickup != null and is_instance_valid(active_reward_pickup):
		active_reward_pickup.mark_consumed()
		consume_map_pickup(active_reward_pickup)
	active_reward_pickup = null


func _close_reward_choice() -> void:
	if reward_choice_ui != null:
		reward_choice_ui.hide()
	active_reward_options.clear()
	reward_choice_return_mode = GameMode.EXPLORATION


func _restore_exploration_after_reward() -> void:
	mode = GameMode.EXPLORATION
	_pause_exploration_enemy_schedules(false)
	_refresh_exploration_state()


func _restore_post_combat_after_reward() -> void:
	mode = GameMode.POST_COMBAT_REWARD
	_pause_exploration_enemy_schedules(true)
	_refresh_exploration_state()


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
	if _has_pending_directional_card():
		_update_directional_projectile_preview_from_mouse()
		return

	if _is_movement_locked():
		return

	var move_dir := _read_move_input()
	if move_dir == Vector2i.ZERO:
		return
	
	if must_resolve_overflow:
		message = "Hand overflow: play or discard a card first."
		_update_message()
		return
	
	if _is_world_movement_mode():
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
	if suppress_next_move_input:
		suppress_next_move_input = false
		return Vector2i.ZERO
	if Input.is_action_just_pressed("move_up"):
		return Vector2i.UP
	if Input.is_action_just_pressed("move_down"):
		return Vector2i.DOWN
	if Input.is_action_just_pressed("move_left"):
		return Vector2i.LEFT
	if Input.is_action_just_pressed("move_right"):
		return Vector2i.RIGHT
	return Vector2i.ZERO


func _resolve_player_manual_move_action(direction: Vector2i) -> Dictionary:
	interrupt_player_path_after_step = false
	var step_direction := direction.sign()
	var move_effect := _consume_next_manual_move_effect()
	var attempted_distance := 1 + int(move_effect.get("bonus_distance", 0))
	# Keep the blocked tile in the result so an impact/bonk presentation can hook in later.
	var result: Dictionary = {
		"success": false,
		"attempted_distance": attempted_distance,
		"moved_distance": 0,
		"blocked": false,
		"blocked_tile": Vector2i.ZERO,
		"ended_tile": player.grid_position,
		"used_modifier": bool(move_effect.get("armed", false))
	}

	if abs(step_direction.x) + abs(step_direction.y) != 1:
		return result

	for step_index in range(attempted_distance):
		var next_tile: Vector2i = player.grid_position + step_direction
		if not _can_move_to_tile(next_tile, player):
			result["blocked"] = true
			result["blocked_tile"] = next_tile
			break

		var should_stop_after_step := step_index == attempted_distance - 1
		if not should_stop_after_step:
			var lookahead_tile: Vector2i = next_tile + step_direction
			should_stop_after_step = not _can_move_to_tile(lookahead_tile, player)

		var move_rules := {
			"apply_hazards": should_stop_after_step or not bool(move_effect.get("ignore_intermediate_hazards", false)),
			"apply_tile_triggers": true,
			"resolve_detection": should_stop_after_step or not bool(move_effect.get("check_detection_only_on_final_tile", false))
		}
		if not await _move_player_one_tile(next_tile, move_rules):
			result["blocked"] = true
			result["blocked_tile"] = next_tile
			break

		result["success"] = true
		result["moved_distance"] = int(result["moved_distance"]) + 1
		result["ended_tile"] = player.grid_position
		if replay_reset_completed_this_step:
			result["triggered_level_reset"] = true
			replay_reset_completed_this_step = false
			break
		if _consume_player_path_interrupt():
			result["interrupted"] = true
			break

		if player.hp <= 0 or mode == GameMode.DEFEAT:
			break
		if mode == GameMode.COMBAT_TRANSITION or mode == GameMode.REWARD_CHOICE:
			break

	return result


func _try_exploration_move(direction: Vector2i) -> void:
	if must_resolve_overflow:
		message = "Hand overflow: play or discard a card first."
		_update_message()
		return
	var move_result := await _resolve_player_manual_move_action(direction)
	if not bool(move_result.get("success", false)):
		return
	if bool(move_result.get("triggered_level_reset", false)):
		_refresh_ui()
		queue_redraw()
		return
	if not _is_world_movement_mode():
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
	treat_other_enemies_as_blocked: bool = true,
	ignored_blocker: Node2D = null,
	ignore_destructible_objects: bool = false
) -> bool:
	if not _is_in_bounds(tile):
		return false
	if terrain_blocks_movement(tile):
		return false

	var obj = get_object_at(tile)
	var ignore_object_blocking: bool = ignore_destructible_objects \
		and obj is EnvironmentObject \
		and obj.is_destructible
	if obj != null and obj != moving_entity and obj != ignored_blocker and bool(obj.blocks_movement) and not ignore_object_blocking:
		return false

	if _is_world_movement_mode() and _is_tile_reserved_by_other(tile, moving_entity):
		return false

	if treat_player_as_blocked and player != moving_entity and player != ignored_blocker and player.grid_position == tile:
		return false

	if treat_other_enemies_as_blocked:
		for e in enemies:
			if e == null or not is_instance_valid(e) or e == moving_entity or e == ignored_blocker:
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


func _get_path_step_hazard_cost(tile: Vector2i, goal_tile: Vector2i) -> int:
	if get_hazard_at(tile).is_empty():
		return 0
	if tile == goal_tile and not get_hazard_at(goal_tile).is_empty():
		return 0
	return 1


func _count_path_hazards(path: Array[Vector2i], goal_tile: Vector2i) -> int:
	var hazard_count := 0
	for step_tile in path:
		hazard_count += _get_path_step_hazard_cost(step_tile, goal_tile)
	return hazard_count


func _find_bfs_path(
	start_tile: Vector2i,
	goal_tile: Vector2i,
	moving_entity = null,
	treat_player_as_blocked: bool = true,
	treat_other_enemies_as_blocked: bool = true,
	ignore_destructible_objects: bool = false
) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	if start_tile == goal_tile:
		return path
	if not _is_tile_walkable(
		goal_tile,
		moving_entity,
		treat_player_as_blocked,
		treat_other_enemies_as_blocked,
		null,
		ignore_destructible_objects
	):
		return path

	var distances: Dictionary = {start_tile: 0}
	var frontier: Array[Vector2i] = [start_tile]
	var tiles_by_distance: Dictionary = {0: [start_tile]}
	var frontier_index := 0

	while frontier_index < frontier.size():
		var current: Vector2i = frontier[frontier_index]
		frontier_index += 1

		if current == goal_tile:
			break

		var current_distance: int = int(distances.get(current, 0))
		for direction in CARDINAL_DIRECTIONS:
			var next_tile := current + direction
			if distances.has(next_tile):
				continue
			if not _is_tile_walkable(
				next_tile,
				moving_entity,
				treat_player_as_blocked,
				treat_other_enemies_as_blocked,
				null,
				ignore_destructible_objects
			):
				continue

			var next_distance := current_distance + 1
			distances[next_tile] = next_distance
			frontier.append(next_tile)
			if not tiles_by_distance.has(next_distance):
				tiles_by_distance[next_distance] = []
			var layer: Array = tiles_by_distance[next_distance]
			layer.append(next_tile)
			tiles_by_distance[next_distance] = layer
			
	if not distances.has(goal_tile):
		return path

	var goal_distance: int = int(distances.get(goal_tile, 0))
	var came_from: Dictionary = {start_tile: start_tile}
	var best_hazard_counts: Dictionary = {start_tile: 0}

	for distance in range(goal_distance):
		var layer: Array = tiles_by_distance.get(distance, [])
		for raw_current in layer:
			var current: Vector2i = raw_current
			if not best_hazard_counts.has(current):
				continue
			var current_hazard_count: int = int(best_hazard_counts.get(current, 0))
			for direction in CARDINAL_DIRECTIONS:
				var next_tile := current + direction
				if int(distances.get(next_tile, -1)) != distance + 1:
					continue

				var next_hazard_count := current_hazard_count + _get_path_step_hazard_cost(next_tile, goal_tile)
				if not best_hazard_counts.has(next_tile) or next_hazard_count < int(best_hazard_counts.get(next_tile, 0)):
					best_hazard_counts[next_tile] = next_hazard_count
					came_from[next_tile] = current

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
	treat_other_enemies_as_blocked: bool = true,
	ignore_destructible_objects: bool = false
) -> Array[Vector2i]:
	var best_path: Array[Vector2i] = []
	var best_hazard_count := 0
	var found_path := false

	for goal_tile in goal_tiles:
		var path := _find_bfs_path(
			start_tile,
			goal_tile,
			moving_entity,
			treat_player_as_blocked,
			treat_other_enemies_as_blocked,
			ignore_destructible_objects
		)
		if path.is_empty():
			continue
		var hazard_count := _count_path_hazards(path, goal_tile)
		if not found_path \
		or path.size() < best_path.size() \
		or (path.size() == best_path.size() and hazard_count < best_hazard_count):
			best_path = path
			best_hazard_count = hazard_count
			found_path = true

	return best_path


func _find_enemy_path_to_attack_tile(
	enemy: Enemy,
	target_tile: Vector2i,
	treat_other_enemies_as_blocked: bool = true,
	log_debug: bool = false,
	ignore_destructible_objects: bool = false
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
		treat_other_enemies_as_blocked,
		ignore_destructible_objects
	)

	var found_goal := not path.is_empty()
	var best_goal_tile := path[path.size() - 1] if found_goal else Vector2i.ZERO
	if log_debug:
		_debug_log_enemy_path(enemy, best_goal_tile, path, found_goal)
	return path


func _find_enemy_path_to_target(
	enemy: Enemy,
	target_tile: Vector2i,
	treat_other_enemies_as_blocked: bool = true,
	log_debug: bool = false,
	ignore_destructible_objects: bool = false
) -> Array[Vector2i]:
	return _find_enemy_path_to_attack_tile(
		enemy,
		target_tile,
		treat_other_enemies_as_blocked,
		log_debug,
		ignore_destructible_objects
	)


func _get_actor_movement_allowance(actor) -> int:
	if actor == player:
		return movement_left
	if actor is Enemy:
		return actor.get_movement_allowance()
	return 0


func _get_actor_available_energy(actor) -> int:
	if actor == player:
		return current_energy
	if actor is Enemy:
		return actor.current_energy
	return 0


func _get_actor_movement_energy_cost(actor, tiles: int = 1) -> int:
	var tile_count = max(tiles, 0)
	if actor == player:
		return tile_count
	if actor is Enemy:
		return actor.get_movement_energy_cost(tile_count)
	return -1


func _get_actor_affordable_movement_steps(actor, requested_steps: int = -1) -> int:
	if actor == null or not is_instance_valid(actor):
		return 0

	var move_cost := _get_actor_movement_energy_cost(actor)
	if move_cost <= 0:
		return 0

	var affordable_steps := int(floor(float(_get_actor_available_energy(actor)) / float(move_cost)))
	var allowed_steps = min(_get_actor_movement_allowance(actor), affordable_steps)
	if requested_steps >= 0:
		allowed_steps = min(allowed_steps, requested_steps)
	return max(allowed_steps, 0)


func _spend_actor_movement_cost(actor, tiles: int) -> bool:
	var tile_count = max(tiles, 0)
	if tile_count <= 0:
		return true

	if actor == player:
		if current_energy < tile_count or movement_left < tile_count:
			return false
		current_energy -= tile_count
		movement_left -= tile_count
		return true

	if actor is Enemy:
		return actor.spend_energy(_get_actor_movement_energy_cost(actor, tile_count))

	return false


func _build_player_tile_move_request(destination: Vector2i) -> Dictionary:
	var request: Dictionary = {
		"legal": false,
		"path": [],
		"destination": destination,
		"mode": mode
	}
	if player == null or not is_instance_valid(player):
		return request
	if player_move_in_progress or destination == player.grid_position:
		return request
	if must_resolve_overflow:
		return request

	var path := _find_bfs_path(player.grid_position, destination, player, true, true)
	if path.is_empty():
		return request
	request["path"] = path

	if mode == GameMode.COMBAT:
		var path_length := path.size()
		request["legal"] = _get_actor_affordable_movement_steps(player, path_length) >= path_length
		return request

	request["legal"] = _is_world_movement_mode()
	return request


func _request_player_tile_move(destination: Vector2i) -> bool:
	if mode != GameMode.COMBAT and not _is_world_movement_mode():
		return false

	var move_request := _build_player_tile_move_request(destination)
	if not bool(move_request.get("legal", false)):
		return false

	_resolve_player_tile_move_request(move_request)
	return true


func _resolve_player_tile_move_request(move_request: Dictionary) -> void:
	var path := _copy_vector2i_array(move_request.get("path", []))
	if path.is_empty():
		return

	var in_combat := int(move_request.get("mode", mode)) == GameMode.COMBAT
	var move_result := await _execute_player_path(path, in_combat)
	if int(move_result.get("moved_steps", 0)) <= 0:
		return
	if bool(move_result.get("triggered_level_reset", false)):
		_refresh_ui()
		queue_redraw()
		return

	if in_combat:
		if mode != GameMode.COMBAT:
			_refresh_ui()
			queue_redraw()
			return
		message = _consume_environment_messages("Moved to %s." % [str(player.grid_position)])
		_update_all_enemy_intent()
		_refresh_ui()
		queue_redraw()
		return

	if not _is_world_movement_mode():
		return

	var resolved_message := _consume_environment_messages("Moved to %s." % [str(player.grid_position)])
	if not resolved_message.is_empty():
		message = resolved_message
	_refresh_ui()
	queue_redraw()


func _execute_player_path(path: Array[Vector2i], spend_combat_resources: bool = false) -> Dictionary:
	var result: Dictionary = {
		"moved_steps": 0,
		"triggered_level_reset": false,
		"interrupted": false
	}
	if path.is_empty():
		return result
	interrupt_player_path_after_step = false

	for next_tile in path:
		if spend_combat_resources and _get_actor_affordable_movement_steps(player, 1) <= 0:
			result["interrupted"] = true
			break
		if not await _move_player_one_tile(next_tile):
			result["interrupted"] = true
			break

		result["moved_steps"] = int(result["moved_steps"]) + 1
		if spend_combat_resources and not _spend_actor_movement_cost(player, 1):
			result["interrupted"] = true
			break

		if replay_reset_completed_this_step:
			result["triggered_level_reset"] = true
			replay_reset_completed_this_step = false
			break
		if _consume_player_path_interrupt():
			result["interrupted"] = true
			break
		if player.hp <= 0 or mode == GameMode.DEFEAT:
			result["interrupted"] = true
			break
		if spend_combat_resources:
			if mode != GameMode.COMBAT:
				result["interrupted"] = true
				break
		elif not _is_world_movement_mode():
			result["interrupted"] = true
			break

	return result


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


func _is_enemy_attack_target_valid(target: Node2D) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if target == player:
		return player.hp > 0
	if target is Enemy:
		return target.state == Enemy.State.ALIVE
	if target is EnvironmentObject:
		return target.hp > 0
	return false


func _enemy_can_attack_target(enemy: Enemy, target: Node2D) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	if enemy.state != Enemy.State.ALIVE:
		return false
	if not _is_enemy_attack_target_valid(target):
		return false
	return _get_grid_target_position(target) in enemy.get_threatened_tiles()


func _enemy_can_attack_player(enemy: Enemy) -> bool:
	return _enemy_can_attack_target(enemy, player)


func _enemy_try_attack_target(enemy: Enemy, target: Node2D) -> bool:
	if not _enemy_can_attack_target(enemy, target):
		return false
	if not enemy.spend_energy(enemy.get_attack_energy_cost()):
		return false

	_damage_entity(target, enemy.damage)
	if target == player and player.hiding:
		player.become_hidden_or_revealed()
	return true


func _enemy_try_attack_player(enemy: Enemy) -> bool:
	return _enemy_try_attack_target(enemy, player)


func _enemy_can_use_special_action(_enemy: Enemy) -> bool:
	if _enemy == null or not is_instance_valid(_enemy):
		return false
	return false


func _try_enemy_special_action(_enemy: Enemy) -> Dictionary:
	if not _enemy_can_use_special_action(_enemy):
		return {"performed": false, "message": ""}
	return {"performed": false, "message": ""}


func _move_enemy_with_energy_budget(enemy: Enemy, path: Array[Vector2i], movement_allowance: int) -> int:
	if enemy == null or not is_instance_valid(enemy):
		return 0
	if movement_allowance <= 0 or path.is_empty():
		return 0

	var allowed_steps := _get_actor_affordable_movement_steps(enemy, movement_allowance)
	if allowed_steps <= 0:
		return 0

	var moved_steps := await _move_enemy_along_path(enemy, path, allowed_steps)
	if moved_steps <= 0:
		return 0

	_spend_actor_movement_cost(enemy, moved_steps)
	return moved_steps


func _make_enemy_combat_plan(
	kind: StringName,
	target: Node2D = null,
	path: Array[Vector2i] = []
) -> Dictionary:
	return {
		"kind": kind,
		"target": target,
		"path": path
	}


func _make_enemy_action_result(
	acted: bool,
	message: String = "",
	attacked: bool = false,
	moved: bool = false
) -> Dictionary:
	return {
		"acted": acted,
		"message": message,
		"attacked": attacked,
		"moved": moved
	}


func _get_enemy_plan_kind(plan: Dictionary) -> StringName:
	return StringName(plan.get("kind", ENEMY_COMBAT_PLAN_HOLD))


func _get_enemy_plan_path(plan: Dictionary) -> Array[Vector2i]:
	var resolved_path: Array[Vector2i] = []
	var raw_path: Variant = plan.get("path", [])
	if raw_path is Array:
		for raw_tile in raw_path:
			var tile: Vector2i = raw_tile
			resolved_path.append(tile)
	return resolved_path


func _is_enemy_fallback_object_target(target: EnvironmentObject) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	return target.is_destructible and target.blocks_movement and target.hp > 0


func _build_enemy_player_plan(enemy: Enemy) -> Dictionary:
	if _enemy_can_attack_player(enemy):
		return _make_enemy_combat_plan(ENEMY_COMBAT_PLAN_PLAYER, player)

	var player_path: Array[Vector2i] = _find_enemy_path_to_attack_tile(enemy, player.grid_position, true, true)
	if player_path.is_empty():
		return {}
	return _make_enemy_combat_plan(ENEMY_COMBAT_PLAN_PLAYER, player, player_path)


func _build_enemy_destructible_object_fallback_plan(enemy: Enemy) -> Dictionary:
	var can_move_this_turn: bool = enemy.can_afford_action(enemy.get_movement_energy_cost())
	var can_attack_this_turn: bool = enemy.can_afford_action(enemy.get_attack_energy_cost())
	if not can_move_this_turn and not can_attack_this_turn:
		return {}

	var unobstructed_player_path: Array[Vector2i] = _find_enemy_path_to_attack_tile(
		enemy,
		player.grid_position,
		true,
		false,
		true
	)
	if unobstructed_player_path.is_empty():
		return {}

	var best_target: EnvironmentObject = null
	var best_path: Array[Vector2i] = []
	var best_is_adjacent_attack: bool = false
	var best_path_length: int = 0
	var best_player_distance: int = 0

	for raw_target in object_layer.values():
		var target: EnvironmentObject = raw_target as EnvironmentObject
		if not _is_enemy_fallback_object_target(target):
			continue

		var target_tile: Vector2i = target.grid_position
		var target_player_distance: int = abs(target_tile.x - player.grid_position.x) + abs(target_tile.y - player.grid_position.y)
		var can_attack_target_now: bool = _enemy_can_attack_target(enemy, target)
		if can_attack_target_now:
			if not can_attack_this_turn:
				continue
			if best_target == null or not best_is_adjacent_attack or target_player_distance < best_player_distance:
				best_target = target
				best_path = []
				best_is_adjacent_attack = true
				best_path_length = 0
				best_player_distance = target_player_distance
			continue

		if not can_move_this_turn:
			continue

		var target_path: Array[Vector2i] = _find_enemy_path_to_attack_tile(enemy, target_tile, true)
		if target_path.is_empty():
			continue

		var path_length: int = target_path.size()
		if best_target == null \
		or (not best_is_adjacent_attack and path_length < best_path_length) \
		or (not best_is_adjacent_attack and path_length == best_path_length and target_player_distance < best_player_distance):
			best_target = target
			best_path = target_path
			best_is_adjacent_attack = false
			best_path_length = path_length
			best_player_distance = target_player_distance

	if best_target == null:
		return {}
	return _make_enemy_combat_plan(ENEMY_COMBAT_PLAN_DESTRUCTIBLE_OBJECT, best_target, best_path)


func _choose_enemy_combat_plan(enemy: Enemy, player_attack_locked: bool = false) -> Dictionary:
	var player_plan: Dictionary = _build_enemy_player_plan(enemy)
	if not player_plan.is_empty():
		return player_plan

	if player_attack_locked:
		return _make_enemy_combat_plan(ENEMY_COMBAT_PLAN_HOLD)

	var fallback_plan: Dictionary = _build_enemy_destructible_object_fallback_plan(enemy)
	if not fallback_plan.is_empty():
		return fallback_plan

	return _make_enemy_combat_plan(ENEMY_COMBAT_PLAN_HOLD)


func _execute_enemy_engagement_plan(
	enemy: Enemy,
	target: Node2D,
	path: Array[Vector2i],
	attack_message: String,
	move_message: String,
	move_attack_message: String,
	allow_attack: bool = true
) -> Dictionary:
	if allow_attack and _enemy_try_attack_target(enemy, target):
		return _make_enemy_action_result(true, _consume_environment_messages(attack_message), true, false)

	var moved_steps: int = await _move_enemy_with_energy_budget(enemy, path, enemy.get_movement_allowance())
	if moved_steps <= 0:
		return _make_enemy_action_result(false)

	if allow_attack and _enemy_try_attack_target(enemy, target):
		return _make_enemy_action_result(true, _consume_environment_messages(move_attack_message), true, true)
	return _make_enemy_action_result(true, _consume_environment_messages(move_message), false, true)


func _execute_enemy_obstacle_plan(enemy: Enemy, plan: Dictionary) -> Dictionary:
	var target: EnvironmentObject = plan.get("target", null) as EnvironmentObject
	var path: Array[Vector2i] = _get_enemy_plan_path(plan)
	if target == null or not is_instance_valid(target):
		return _make_enemy_action_result(false)

	var object_name: String = _object_display_name(target)
	return await _execute_enemy_engagement_plan(
		enemy,
		target,
		path,
		"Enemy attacks the %s for %d." % [object_name, enemy.damage],
		"Enemy advances on the %s." % object_name,
		"Enemy advances on the %s. Then hits it for %d." % [object_name, enemy.damage]
	)


func _resolve_enemy_combat_turn(enemy: Enemy) -> String:
	if enemy == null or not is_instance_valid(enemy):
		return ""

	enemy.reset_combat_energy()
	var special_result := _try_enemy_special_action(enemy)
	if bool(special_result.get("performed", false)):
		return String(special_result.get("message", "Enemy uses a special action."))

	var action_messages: Array[String] = []
	var player_attack_locked: bool = false
	var safety_counter: int = 0

	while enemy.current_energy > 0 and safety_counter < 4:
		safety_counter += 1
		var combat_plan: Dictionary = _choose_enemy_combat_plan(enemy, player_attack_locked)
		var plan_kind: StringName = _get_enemy_plan_kind(combat_plan)
		var action_result: Dictionary = _make_enemy_action_result(false)

		match plan_kind:
			ENEMY_COMBAT_PLAN_PLAYER:
				var player_path: Array[Vector2i] = _get_enemy_plan_path(combat_plan)
				action_result = await _execute_enemy_engagement_plan(
					enemy,
					player,
					player_path,
					"Enemy attacks for %d." % enemy.damage,
					"Enemy advances.",
					"Enemy advances. Then hits for %d." % enemy.damage,
					not player_attack_locked
				)
			ENEMY_COMBAT_PLAN_DESTRUCTIBLE_OBJECT:
				action_result = await _execute_enemy_obstacle_plan(enemy, combat_plan)
			_:
				break

		if not bool(action_result.get("acted", false)):
			break
		if plan_kind == ENEMY_COMBAT_PLAN_PLAYER and bool(action_result.get("attacked", false)):
			player_attack_locked = true

		var action_message: String = String(action_result.get("message", ""))
		if not action_message.is_empty():
			action_messages.append(action_message)

		if enemy == null or not is_instance_valid(enemy) or enemy.state != Enemy.State.ALIVE:
			break
		if mode != GameMode.COMBAT:
			break

	if action_messages.is_empty():
		return "Enemy holds position."
	return " ".join(action_messages)


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


func _is_displacement_target_movable(target: Node2D) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if target == player:
		return true
	if target is Enemy:
		return target.state == Enemy.State.ALIVE
	if target is EnvironmentObject:
		return target.is_movable
	return false


func _get_grid_target_position(target: Node2D) -> Vector2i:
	if target == null or not is_instance_valid(target):
		return Vector2i.ZERO
	if target == player:
		return player.grid_position
	if target is Enemy:
		return target.grid_position
	if target is EnvironmentObject:
		return target.grid_position
	return Vector2i.ZERO


func _can_move_grid_target_to_tile(target: Node2D, tile: Vector2i, ignored_blocker: Node2D = null) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	return _is_tile_walkable(tile, target, true, true, ignored_blocker)


func _move_grid_target_to_tile(target: Node2D, tile: Vector2i, ignored_blocker: Node2D = null) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if not _can_move_grid_target_to_tile(target, tile, ignored_blocker):
		return false

	var start_tile: Vector2i = _get_grid_target_position(target)
	if target is EnvironmentObject:
		if object_layer.get(start_tile) == target:
			object_layer.erase(start_tile)
		object_layer[tile] = target

	if target == player:
		player.set_grid_position(tile)
	elif target is Enemy:
		target.set_grid_position(tile)
	elif target is EnvironmentObject:
		target.set_grid_position(tile)
	else:
		return false

	_rebuild_enemy_threat_map()
	_resolve_entity_tile_entry(target)
	queue_redraw()
	return true


func apply_displacement(
	target: Node2D,
	direction: Vector2i,
	distance: int,
	ignored_blocker: Node2D = null
) -> Dictionary:
	var result: Dictionary = {
		"success": false,
		"destination": Vector2i.ZERO,
		"moved_distance": 0
	}
	if not _is_displacement_target_movable(target):
		return result

	var step_direction: Vector2i = direction.sign()
	if abs(step_direction.x) + abs(step_direction.y) != 1:
		return result
	if distance <= 0:
		return result

	var start_tile: Vector2i = _get_grid_target_position(target)
	var destination: Vector2i = start_tile
	for _step in range(distance):
		var next_tile: Vector2i = destination + step_direction
		if not _can_move_grid_target_to_tile(target, next_tile, ignored_blocker):
			return result
		destination = next_tile

	if destination == start_tile:
		return result
	if not _move_grid_target_to_tile(target, destination, ignored_blocker):
		return result

	result["success"] = true
	result["destination"] = destination
	result["moved_distance"] = distance
	return result


func _move_entity_to_tile(entity: Node2D, target: Vector2i) -> bool:
	return _move_grid_target_to_tile(entity, target)


func _move_player_one_tile(target: Vector2i, move_rules: Dictionary = {}) -> bool:
	if player_move_in_progress:
		return false
	if not _can_move_to_tile(target, player):
		return false

	var apply_hazards: bool = bool(move_rules.get("apply_hazards", true))
	var apply_tile_triggers: bool = bool(move_rules.get("apply_tile_triggers", true))
	var resolve_detection: bool = bool(move_rules.get("resolve_detection", true))

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
	_resolve_entity_tile_entry(player, apply_hazards, apply_tile_triggers)
	if replay_reset_completed_this_step:
		player_move_in_progress = false
		_refresh_exploration_state()
		return true
	if mode == GameMode.REWARD_CHOICE:
		player_move_in_progress = false
		_refresh_exploration_state()
		return true
	if player.hp <= 0:
		player_move_in_progress = false
		_refresh_exploration_state()
		_finish_environment_message("You were overwhelmed.")
		mode = GameMode.DEFEAT
		_refresh_ui()
		queue_redraw()
		return true
	_rebuild_enemy_threat_map()
	if resolve_detection:
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

	var move_result := await _resolve_player_manual_move_action(direction)
	if not bool(move_result.get("success", false)):
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
	combat_transition_running = false
	combat_transition_can_start = false
	exploration_reserved_tiles.clear()
	_pause_exploration_enemy_schedules(true)
	mode = GameMode.COMBAT
	Input.flush_buffered_events()
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
	_clear_next_manual_move_modifiers()
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

		message = await _resolve_enemy_combat_turn(e)

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
	if _has_pending_directional_card():
		message = "Choose a cardinal throw direction for %s." % pending_directional_card.get("name", "this card")
		_update_message()
		return
	if index >= deck_manager.hand.size():
		return
	if must_resolve_overflow:
		var discarded := deck_manager.discard_from_hand(index)
		message = "Discarded %s to stay at %d cards." % [discarded.get("name", "card"), HAND_LIMIT]
		_refresh_hand_overflow_state()
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

	if _is_directional_projectile_card(card):
		_select_directional_projectile_card(index, card)
		return

	resolving_player_card = true
	var result := _resolve_card(card)
	resolving_player_card = false
	if not result["success"]:
		message = result["message"]
		_update_message()
		return
	_finish_played_card(index, result)


func _finish_played_card(index: int, result: Dictionary) -> void:
	if index < 0 or index >= deck_manager.hand.size():
		return
	var card: Dictionary = deck_manager.hand[index]
	current_energy -= int(card["cost"])

	var played := deck_manager.play_from_hand(index, bool(card.get("exhaust", false)))
	message = "Played %s. %s" % [played["name"], result["message"]]

	_update_all_enemy_intent()
	if mode == GameMode.COMBAT or mode == GameMode.COMBAT_TRANSITION:
		_check_end_of_combat()
	_refresh_ui()
	queue_redraw()


func _resolve_card(card: Dictionary) -> Dictionary:
	match card["id"]:
		"strike":
			return _play_strike()
		"block":
			return _play_block()
		"dash":
			return _play_dash()
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


func _is_directional_projectile_card(card: Dictionary) -> bool:
	return String(card.get("targeting", "")) == DIRECTIONAL_PROJECTILE_TARGETING


func _has_pending_directional_card() -> bool:
	return pending_directional_card_index >= 0 and not pending_directional_card.is_empty()


func _select_directional_projectile_card(index: int, card: Dictionary) -> void:
	pending_directional_card_index = index
	pending_directional_card = card.duplicate(true)
	directional_projectile_preview.clear()
	_set_current_target(null)
	_update_directional_projectile_preview_from_mouse()
	message = "Choose a same-row or same-column tile to throw %s." % card.get("name", "this card")
	_refresh_ui()
	queue_redraw()


func _cancel_pending_directional_card() -> void:
	if not _has_pending_directional_card():
		return
	var card_name := String(pending_directional_card.get("name", "card"))
	_clear_pending_directional_card(false)
	message = "Canceled %s." % card_name
	controls_label.text = _controls_text()
	_update_hand_button_disabled_states()
	_update_message()
	queue_redraw()


func _clear_pending_directional_card(refresh: bool = true) -> void:
	pending_directional_card_index = -1
	pending_directional_card.clear()
	directional_projectile_preview.clear()
	if refresh:
		_refresh_ui()
		queue_redraw()


func _update_directional_projectile_preview_from_mouse() -> void:
	if not _has_pending_directional_card():
		return
	if _is_pointer_over_card_ui():
		directional_projectile_preview.clear()
		queue_redraw()
		return

	var hover_tile := _world_to_grid(get_global_mouse_position())
	if not _is_in_bounds(hover_tile):
		directional_projectile_preview.clear()
		queue_redraw()
		return

	directional_projectile_preview = _trace_directional_projectile_choice(player.grid_position, hover_tile, pending_directional_card)
	queue_redraw()


func _handle_directional_projectile_click(clicked_tile: Vector2i) -> void:
	if not _has_pending_directional_card():
		return

	var hand_index := pending_directional_card_index
	if hand_index < 0 or hand_index >= deck_manager.hand.size():
		_clear_pending_directional_card(false)
		message = "That card is no longer available."
		_refresh_ui()
		queue_redraw()
		return

	var card: Dictionary = deck_manager.hand[hand_index]
	if String(card.get("id", "")) != String(pending_directional_card.get("id", "")):
		_clear_pending_directional_card(false)
		message = "That card is no longer available."
		_refresh_ui()
		queue_redraw()
		return

	if current_energy < int(card.get("cost", 0)):
		message = "Not enough energy for %s." % card.get("name", "this card")
		_update_message()
		return

	var trace := _trace_directional_projectile_choice(player.grid_position, clicked_tile, card)
	directional_projectile_preview = trace
	if not bool(trace.get("valid_direction", false)):
		message = "%s needs a same-row or same-column tile." % card.get("name", "This card")
		_update_message()
		queue_redraw()
		return

	resolving_player_card = true
	var result := _resolve_directional_projectile_card(card, trace)
	resolving_player_card = false
	if not bool(result.get("success", false)):
		message = String(result.get("message", "Nothing happened."))
		_update_message()
		queue_redraw()
		return

	_clear_pending_directional_card(false)
	_finish_played_card(hand_index, result)


func _trace_directional_projectile_choice(origin: Vector2i, chosen_tile: Vector2i, card: Dictionary) -> Dictionary:
	var direction := _get_cardinal_direction_from_tile(origin, chosen_tile)
	var max_range := int(card.get("max_range", -1))
	return _trace_cardinal_projectile_line(origin, direction, max_range)


func _get_cardinal_direction_from_tile(origin: Vector2i, chosen_tile: Vector2i) -> Vector2i:
	if chosen_tile == origin:
		return Vector2i.ZERO
	if chosen_tile.x == origin.x:
		return Vector2i(0, int(sign(chosen_tile.y - origin.y)))
	if chosen_tile.y == origin.y:
		return Vector2i(int(sign(chosen_tile.x - origin.x)), 0)
	return Vector2i.ZERO


func _trace_cardinal_projectile_line(origin: Vector2i, direction: Vector2i, max_range: int = -1) -> Dictionary:
	var step_direction := direction.sign()
	var result: Dictionary = {
		"valid_direction": false,
		"direction": step_direction,
		"preview_tiles": [],
		"target": null,
		"target_tile": Vector2i.ZERO,
		"blocked": false,
		"blocked_tile": Vector2i.ZERO,
		"final_reachable_tile": origin
	}

	if abs(step_direction.x) + abs(step_direction.y) != 1:
		return result

	result["valid_direction"] = true
	var preview_tiles: Array[Vector2i] = []
	var distance := 1
	while max_range <= 0 or distance <= max_range:
		var tile := origin + step_direction * distance
		if not _is_in_bounds(tile):
			break

		var target := _get_projectile_target_at(tile)
		if target != null:
			preview_tiles.append(tile)
			result["target"] = target
			result["target_tile"] = tile
			result["final_reachable_tile"] = tile
			break

		if _projectile_tile_blocks_line(tile):
			result["blocked"] = true
			result["blocked_tile"] = tile
			break

		preview_tiles.append(tile)
		result["final_reachable_tile"] = tile
		distance += 1

	result["preview_tiles"] = preview_tiles
	return result


func _get_projectile_target_at(tile: Vector2i) -> Node2D:
	var enemy := get_enemy_at(tile)
	if _is_projectile_valid_target(enemy):
		return enemy

	var obj := get_object_at(tile) as Node2D
	if _is_projectile_valid_target(obj):
		return obj

	return null


func _is_projectile_valid_target(target: Node2D) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if target is Enemy:
		return target.state == Enemy.State.ALIVE
	if target is EnvironmentObject:
		if not target.is_targetable:
			return false
		if target.is_destructible:
			return target.hp > 0
		return true
	return false


func _projectile_tile_blocks_line(tile: Vector2i) -> bool:
	if terrain_blocks_movement(tile):
		return true

	var obj = get_object_at(tile)
	return obj != null and bool(obj.blocks_movement)


func _resolve_directional_projectile_card(card: Dictionary, trace: Dictionary) -> Dictionary:
	if not bool(trace.get("valid_direction", false)):
		return {"success": false, "message": "Choose a cardinal direction."}

	var target := trace.get("target", null) as Node2D
	if target == null or not is_instance_valid(target):
		if bool(card.get("breaks_stealth", false)):
			_break_player_stealth()
		if bool(trace.get("blocked", false)):
			return {"success": true, "message": "The dagger stopped short against a blocker."}
		return {"success": true, "message": "The dagger flew to the edge of the board."}

	var base_damage := int(card.get("damage", 0))
	var damage := _modify_attack_damage(base_damage) if bool(card.get("breaks_stealth", false)) else base_damage
	_apply_projectile_hit(target, damage)

	var target_enemy := target as Enemy
	if mode == GameMode.EXPLORATION and target_enemy != null and is_instance_valid(target_enemy):
		_try_player_initiated_exploration_combat(target_enemy, "player_throwing_dagger")

	return {
		"success": true,
		"message": "Dagger hit %s for %d damage." % [_projectile_target_display_name(target), damage]
	}


func _apply_projectile_hit(target: Node2D, damage: int) -> void:
	if target == null or not is_instance_valid(target):
		return
	# Future switches or interactables can implement this without changing line tracing.
	if target.has_method("on_projectile_hit"):
		target.on_projectile_hit(player, self, damage)
		return
	if target.has_method("take_damage"):
		_damage_entity(target, damage)


func _projectile_target_display_name(target: Node2D) -> String:
	if target is Enemy:
		return "enemy"
	if target is EnvironmentObject:
		return _object_display_name(target).to_lower()
	return "target"


func _is_tile_in_directional_projectile_preview(tile: Vector2i) -> bool:
	var preview_tiles: Array = directional_projectile_preview.get("preview_tiles", [])
	for preview_tile in preview_tiles:
		if preview_tile == tile:
			return true
	return false


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


func _play_dash() -> Dictionary:
	if not _arm_next_manual_move_modifier("dash"):
		return {"success": false, "message": "Dash could not be armed."}
	return {"success": true, "message": "Your next manual move gains +1 distance."}


func _play_lunge() -> Dictionary:
	if not _has_valid_target():
		return {"success": false, "message": "No target selected."}

	var player_moved := false
	var target_enemy := current_target as Enemy
	var direction := _step_toward(player.grid_position, current_target.grid_position)
	if direction != Vector2i.ZERO:
		var lunge_tile: Vector2i = player.grid_position + direction
		if lunge_tile != current_target.grid_position and _move_entity_to_tile(player, lunge_tile):
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

	# need to check if target is an enemy before checking facing direction
	var behind_tile: Vector2i = current_target.grid_position - current_target.facing_dir
	var base_damage := 9 if player.grid_position == behind_tile else 5
	var backstab_damage := _modify_attack_damage(base_damage)
	current_target.take_damage(backstab_damage)
	return {"success": true, "message": "Dealt %d damage." % backstab_damage}


func _play_slip_past() -> Dictionary:
	if not _has_valid_target():
		return {"success": false, "message": "No target selected."}
	if not _is_adjacent(player.grid_position, current_target.grid_position):
		return {"success": false, "message": "Slip Past needs an adjacent target."}
	if not _is_displacement_target_movable(current_target):
		return {"success": false, "message": "That target cannot be displaced."}

	var player_origin: Vector2i = player.grid_position
	var target_origin: Vector2i = _get_grid_target_position(current_target)
	var swap_direction: Vector2i = _step_toward(target_origin, player_origin)
	var displacement_result: Dictionary = apply_displacement(current_target, swap_direction, 1, player)
	if not bool(displacement_result.get("success", false)):
		return {"success": false, "message": "No room to slip past."}
	if not _move_grid_target_to_tile(player, target_origin):
		return {"success": false, "message": "Slip Past failed to reposition you."}

	return {"success": true, "message": _consume_environment_messages("Swapped positions.")}


func _play_unseen() -> Dictionary:
	player.become_hidden_or_revealed()
	return {"success": true, "message": "Your next attack is empowered."}


func _has_valid_target() -> bool:
	return current_target != null and is_instance_valid(current_target)


func _modify_attack_damage(base_damage: int) -> int:
	if player.hiding:
		_break_player_stealth()
		return int(ceil(base_damage * 1.5))
	return base_damage


func _break_player_stealth() -> void:
	if player.hiding:
		player.become_hidden_or_revealed()


func _check_end_of_combat() -> void:
	if not enemies.is_empty():
		return
	if resolving_player_card:
		return
	if mode != GameMode.COMBAT and mode != GameMode.COMBAT_TRANSITION:
		return
	on_combat_won()


func on_combat_won() -> void:
	var recovered_exhausted_count := deck_manager.recover_exhausted_cards()
	_clear_pending_directional_card(false)
	_clear_combat_runtime_state()
	exploration_pending_combat = false
	exploration_combat_trigger_enemy = null
	exploration_combat_trigger_reason = ""
	combat_transition_running = false
	combat_transition_can_start = false
	suppress_next_move_input = false
	exploration_reserved_tiles.clear()
	_set_current_target(null)
	_rebuild_enemy_threat_map()
	enter_post_combat_reward_state(recovered_exhausted_count)


func _update_enemy_intent(e: Enemy) -> void:
	if e == null or not is_instance_valid(e):
		return
	if mode == GameMode.COMBAT:
		var combat_plan: Dictionary = _choose_enemy_combat_plan(e)
		var plan_kind: StringName = _get_enemy_plan_kind(combat_plan)
		match plan_kind:
			ENEMY_COMBAT_PLAN_PLAYER:
				if _enemy_can_attack_player(e):
					e.set_intent_text("Attack %d" % e.damage)
				else:
					e.set_intent_text("Advance")
			ENEMY_COMBAT_PLAN_DESTRUCTIBLE_OBJECT:
				var obstacle_target: EnvironmentObject = combat_plan.get("target", null) as EnvironmentObject
				var obstacle_name: String = _object_display_name(obstacle_target).to_lower()
				e.set_intent_text("Break %s" % obstacle_name)
			_:
				e.set_intent_text("Hold")
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


func _sync_enemy_health_bar_visibility() -> void:
	var show_bars: bool = mode == GameMode.COMBAT
	for enemy in enemies:
		if enemy == null or not is_instance_valid(enemy):
			continue
		enemy.set_health_bar_visible(show_bars)


func _refresh_ui() -> void:
	_sync_enemy_health_bar_visibility()
	mode_label.text = "Mode: %s" % _mode_name()
	stats_label.text = "HP %d/%d  Block %d  Energy %d/%d" % [
		player.hp,
		player.max_hp,
		player.block,
		current_energy,
		max_energy
	]
	combat_banner.visible = mode == GameMode.COMBAT_TRANSITION
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
		button.disabled = _should_disable_hand_buttons()
		button.pressed.connect(func() -> void: _handle_card_shortcut(card_index))
		hand_box.add_child(button)


func _should_disable_hand_buttons() -> bool:
	return mode == GameMode.DEFEAT \
		or mode == GameMode.VICTORY \
		or _is_input_locked() \
		or _has_pending_directional_card()


func _update_hand_button_disabled_states() -> void:
	var disabled := _should_disable_hand_buttons()
	for child in hand_box.get_children():
		if child is Button:
			child.disabled = disabled


func _update_message() -> void:
	if mode == GameMode.COMBAT_TRANSITION:
		center_message.text = _combat_transition_message()
		return
	center_message.text = message


func _combat_transition_message() -> String:
	var transition_message: String = "Exploration has ended. Combat rules are taking over."
	if exploration_combat_trigger_reason.begins_with("enemy_detection:"):
		transition_message = "You entered an enemy detection zone."
	elif exploration_combat_trigger_reason.begins_with("player_"):
		transition_message = "You engaged an enemy. Combat rules are taking over."

	if combat_transition_can_start:
		return "%s\nPress any key or click to begin." % transition_message
	return transition_message


func _controls_text() -> String:
	if _has_pending_directional_card():
		return "Choose a same-row or same-column tile. Esc cancels."

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
					return "Explore with arrow keys/WASD or click/tap a tile. Press . or X to wait. Number keys can play any usable card."
		GameMode.POST_COMBAT_REWARD:
			if player_move_in_progress:
				return "Resolving your movement."
			if active_reward_pickup != null and is_instance_valid(active_reward_pickup):
				return "Choose the card reward, or step onto the gold replay tile to reset the room."
			return "Step onto the gold replay tile to reset the room."
		GameMode.COMBAT_TRANSITION:
			if combat_transition_can_start:
				return "Combat is ready. Press any key or click to begin."
			return "Combat is starting. Input is locked until the prompt appears."
		GameMode.COMBAT:
			if enemy_turn_in_progress:
				return "Enemy turn: movement resolves one tile at a time."
			if player_move_in_progress:
				return "Movement in progress."
			if must_resolve_overflow:
				return "Hand overflow: press 1-5 or click a card to discard it. Space is locked."
			return "Combat: arrow keys/WASD or click/tap a legal tile to move, 1-5 play cards, Space ends turn."
		GameMode.REWARD_CHOICE:
			return "Choose a reward. Click a card, then click it again or press Y. Press N to cancel selection."
		GameMode.VICTORY:
			return "Prototype win state reached."
		GameMode.DEFEAT:
			return "Prototype defeat state reached."
	return ""


func _mode_name() -> String:
	match mode:
		GameMode.EXPLORATION:
			return "Exploration"
		GameMode.POST_COMBAT_REWARD:
			return "Post Combat Reward"
		GameMode.COMBAT_TRANSITION:
			return "Combat Transition"
		GameMode.COMBAT:
			return "Combat"
		GameMode.REWARD_CHOICE:
			return "Reward Choice"
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
	_refresh_hand_overflow_state()
	return drawn


func resolve_draw_pickup(draw_count: int) -> void:
	var drawn := _draw_cards_with_shared_rules(draw_count)
	if drawn.is_empty():
		pending_environment_messages.append("Draw %d pickup triggered, but there were no cards to draw." % draw_count)
	elif drawn.size() < draw_count:
		pending_environment_messages.append("Draw %d pickup triggered and drew %d card(s)." % [draw_count, drawn.size()])
	else:
		pending_environment_messages.append("Draw %d pickup triggered." % draw_count)

	_request_player_path_interrupt()
	if must_resolve_overflow:
		pending_environment_messages.append("Hand overflow: play or discard a card.")


func _resolve_entity_tile_entry(entity, apply_hazards: bool = true, apply_tile_triggers: bool = true) -> void:
	if entity == null or not is_instance_valid(entity):
		return

	if apply_hazards:
		_apply_on_enter_tile_effects(entity, entity.grid_position)
	if entity == player and apply_tile_triggers:
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

	var path := _find_bfs_path(enemy.grid_position, target, enemy, false, true)
	if path.is_empty():
		return action

	var next_tile: Vector2i = path[0]
	var move_direction: Vector2i = (next_tile - enemy.grid_position).sign()
	if abs(move_direction.x) + abs(move_direction.y) != 1:
		return action
	if move_direction != enemy.facing_dir:
		action["kind"] = "rotate"
		action["facing"] = move_direction
		return action
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
	_clear_pending_directional_card(false)
	exploration_pending_combat = true
	exploration_combat_trigger_enemy = trigger_enemy
	exploration_combat_trigger_reason = trigger_reason
	combat_transition_running = false
	combat_transition_can_start = false
	mode = GameMode.COMBAT_TRANSITION
	_pause_exploration_enemy_schedules(true)
	Input.flush_buffered_events()
	_rebuild_enemy_threat_map()
	_refresh_ui()
	queue_redraw()
	_flush_pending_exploration_transition_if_ready()


func _flush_pending_exploration_transition_if_ready() -> void:
	if not exploration_pending_combat:
		return
	if mode != GameMode.COMBAT_TRANSITION:
		return
	if exploration_active_presentations > 0 or player_move_in_progress:
		return
	if combat_transition_can_start:
		return
	if combat_transition_running:
		return

	combat_transition_running = true
	_run_combat_transition()


func _run_combat_transition() -> void:
	_refresh_ui()
	queue_redraw()

	if combat_transition_prompt_delay > 0.0:
		var prompt_timer: SceneTreeTimer = get_tree().create_timer(combat_transition_prompt_delay)
		await prompt_timer.timeout

	if not exploration_pending_combat or mode != GameMode.COMBAT_TRANSITION:
		combat_transition_running = false
		return

	combat_transition_can_start = true
	combat_transition_running = false
	_refresh_ui()
	queue_redraw()


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
