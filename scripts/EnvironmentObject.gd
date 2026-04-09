extends Node2D
class_name EnvironmentObject

const TILE_SIZE := 48

signal destroyed(object)

var grid_position := Vector2i.ZERO
var blocks_movement := true
var hp := 1
var max_hp := 1
var object_type: String = "object"
var is_destructible: bool = false
var is_targetable: bool = false
var is_movable: bool = false


func set_grid_position(value: Vector2i) -> void:
	grid_position = value
	@warning_ignore("integer_division")
	position = Vector2(grid_position * TILE_SIZE) + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)


func triggers_on_player_enter() -> bool:
	return false


func on_player_enter(_player, _game) -> void:
	pass


func take_damage(amount: int) -> void:
	if hp <= 0:
		return

	hp = max(hp - amount, 0)
	if hp <= 0:
		destroyed.emit(self)
