extends CharacterBody2D

const TILE_SIZE := 48

@onready var _status_label: Label = $StatusLabel

var grid_position := Vector2i.ZERO
var hp := 40
var max_hp := 40
var block := 0
var invisible_charges := 0


func set_grid_position(value: Vector2i) -> void:
	grid_position = value
	position = Vector2(grid_position * TILE_SIZE) + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)


func gain_block(amount: int) -> void:
	block += amount


func gain_invisible_charge(amount: int = 1) -> void:
	invisible_charges += amount
	update_status_label()


func consume_invisible_bonus() -> bool:
	if invisible_charges <= 0:
		return false
	invisible_charges -= 1
	update_status_label()
	return true


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
	update_status_label()


func update_status_label() -> void:
	if invisible_charges > 0:
		_status_label.text = "Hidden x%d" % invisible_charges
	else:
		_status_label.text = ""
