extends CharacterBody2D

const TILE_SIZE := 48
const INVISIBLE_ALPHA := 0.60

@onready var _body: Polygon2D = $Body

var grid_position := Vector2i.ZERO
var hp := 40
var max_hp := 40
var block := 0
var hiding := false


func set_grid_position(value: Vector2i, sync_visual: bool = true) -> void:
	grid_position = value
	if not sync_visual:
		return
	position = Vector2(grid_position * TILE_SIZE) + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)


func gain_block(amount: int) -> void:
	block += amount


func become_hidden_or_revealed() -> void:
	if hiding: 
		hiding = false
		_body.modulate.a = 1.0
	else:
		hiding = true
		_body.modulate.a = INVISIBLE_ALPHA

func take_damage(amount: int) -> void:
	var remaining := amount
	if block > 0:
		var blocked: int = min(block, remaining)
		block -= blocked
		remaining -= blocked
	if remaining > 0:
		hp = max(hp - remaining, 0)


func reset_turn_state() -> void:
	block = 0
