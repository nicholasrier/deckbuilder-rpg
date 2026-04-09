extends CharacterBody2D

class_name Enemy

const TILE_SIZE := 48
const HEALTH_BAR_SIZE: Vector2 = Vector2(28.0, 4.0)
const HEALTH_BAR_OFFSET: Vector2 = Vector2(-14.0, -28.0)
const HEALTH_BAR_BORDER_COLOR: Color = Color(0.05, 0.05, 0.08, 0.95)
const HEALTH_BAR_EMPTY_COLOR: Color = Color(0.22, 0.10, 0.12, 0.92)
const HEALTH_BAR_FILL_COLOR: Color = Color(0.36, 0.84, 0.42, 1.0)

@onready var _intent_label: Label = $IntentLabel

@export_range(0.1, 5.0, 0.05) var exploration_cadence := 0.85
@export_range(1, 6, 1) var exploration_detection_range := 3
@export_range(0, 2, 1) var exploration_side_vision := 1
@export_range(1, 10, 1) var max_energy := 3
@export_range(1, 10, 1) var movement_energy_cost := 1
@export_range(1, 10, 1) var attack_energy_cost := 1
@export_range(1, 10, 1) var special_action_energy_cost := 2

var grid_position := Vector2i.ZERO
var movement_per_turn := 3
var hp := 20
var max_hp := 20
var damage := 5
var current_energy := 0
var facing_dir := Vector2i.LEFT
var patrol_points: Array[Vector2i] = []
var look_directions: Array[Vector2i] = []

enum State {
	ALIVE,
	DEFEATED	
}

enum Patrol_Mode {
	PINGPONG,
	LOOP,
	SENTRY
}

enum AwarenessState {
	IDLE,
	SUSPICIOUS,
	ALERT
}

var state := State.ALIVE
var threat_offsets: Array[Vector2i] = []
var patrol_mode := Patrol_Mode.SENTRY	
var patrol_index := 0
var patrol_forward := true
var look_direction_index := 0
var awareness_state := AwarenessState.IDLE
var exploration_action_in_progress := false
var show_health_bar: bool = false

func _ready() -> void:
	threat_offsets = [
		Vector2i(0, 1),
		Vector2i(1, 0),
		Vector2i(0, -1),
		Vector2i(-1, 0)
	]
	if look_directions.is_empty():
		look_directions = [facing_dir]
	reset_combat_energy()


func _draw() -> void:
	if not show_health_bar:
		return
	if state != State.ALIVE or max_hp <= 0:
		return

	var clamped_hp: int = clamp(hp, 0, max_hp)
	var hp_ratio: float = float(clamped_hp) / float(max_hp)
	var bar_rect: Rect2 = Rect2(HEALTH_BAR_OFFSET, HEALTH_BAR_SIZE)
	var fill_width: float = floor(bar_rect.size.x * hp_ratio)

	draw_rect(bar_rect.grow(1.0), HEALTH_BAR_BORDER_COLOR, true)
	draw_rect(bar_rect, HEALTH_BAR_EMPTY_COLOR, true)
	if fill_width > 0.0:
		var fill_rect: Rect2 = Rect2(bar_rect.position, Vector2(fill_width, bar_rect.size.y))
		draw_rect(fill_rect, HEALTH_BAR_FILL_COLOR, true)

func set_grid_position(value: Vector2i, sync_visual: bool = true) -> void:
	grid_position = value
	if not sync_visual:
		return
	@warning_ignore("integer_division")
	position = Vector2(grid_position * TILE_SIZE) + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)

func get_threatened_tiles() -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	for offset in threat_offsets:
		tiles.append(grid_position + offset)
	return tiles


func get_attack_offsets() -> Array[Vector2i]:
	return threat_offsets.duplicate()


func get_movement_allowance() -> int:
	return movement_per_turn


func reset_combat_energy() -> void:
	current_energy = max_energy


func can_afford_action(cost: int) -> bool:
	return cost >= 0 and current_energy >= cost


func spend_energy(cost: int) -> bool:
	if cost < 0:
		return false
	if current_energy < cost:
		return false
	current_energy -= cost
	return true


func get_movement_energy_cost(tiles: int = 1) -> int:
	return max(tiles, 0) * movement_energy_cost


func get_attack_energy_cost() -> int:
	return attack_energy_cost


func get_special_action_energy_cost() -> int:
	return special_action_energy_cost


func set_health_bar_visible(value: bool) -> void:
	if show_health_bar == value:
		return
	show_health_bar = value
	queue_redraw()

func clear_patrol() -> void:
	patrol_points.clear()
	patrol_index = 0
	patrol_forward = true

func clear_rotation_route() -> void:
	look_directions.clear()
	look_direction_index = 0

func set_rotation_route(directions: Array[Vector2i]) -> void:
	clear_rotation_route()
	for direction in directions:
		if abs(direction.x) + abs(direction.y) != 1:
			continue
		look_directions.append(direction)
	if look_directions.is_empty():
		look_directions = [facing_dir]
	facing_dir = look_directions[0]

func has_rotation_route() -> bool:
	return look_directions.size() > 1

func get_current_look_direction() -> Vector2i:
	if look_directions.is_empty():
		return facing_dir
	return look_directions[look_direction_index]

func advance_look_direction() -> void:
	if look_directions.size() <= 1:
		return
	look_direction_index = (look_direction_index + 1) % look_directions.size()

func get_current_patrol_target() -> Vector2i:
	if patrol_points.is_empty():
		return grid_position
	return patrol_points[patrol_index]

func advance_patrol_index() -> void:
	if patrol_points.size() <= 1:
		return

	match patrol_mode:
		Patrol_Mode.LOOP:
			patrol_index = (patrol_index + 1) % patrol_points.size()

		Patrol_Mode.PINGPONG:
			if patrol_forward:
				patrol_index += 1
				if patrol_index >= patrol_points.size():
					patrol_index = patrol_points.size() - 2
					patrol_forward = false
			else:
				patrol_index -= 1
				if patrol_index < 0:
					patrol_index = 1
					patrol_forward = true

		Patrol_Mode.SENTRY:
			pass

func has_patrol_route() -> bool:
	return patrol_mode != Patrol_Mode.SENTRY and patrol_points.size() > 1


func can_patrol() -> bool:
	return state == State.ALIVE and awareness_state == AwarenessState.IDLE and has_patrol_route()


func can_rotate_in_place() -> bool:
	return state == State.ALIVE and awareness_state == AwarenessState.IDLE and not has_patrol_route() and has_rotation_route()

func set_intent_text(value: String) -> void:
	if _intent_label.text == value:
		return
	_intent_label.text = value
	intent_changed.emit(self, _intent_label.text)

func take_damage(amount: int) -> void:
	hp = max(hp - amount, 0)
	queue_redraw()
	if hp <= 0: 
		die()

signal died(enemy)
signal intent_changed(enemy, new_intent)

func die() -> void:
	if state == State.DEFEATED:
		return
	
	state = State.DEFEATED
	died.emit(self)

	
	
