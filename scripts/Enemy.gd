extends CharacterBody2D

const TILE_SIZE := 48

@onready var _intent_label: Label = $IntentLabel

var grid_position := Vector2i.ZERO
var hp := 20
var max_hp := 20
var damage := 5
var facing_dir := Vector2i.LEFT
enum State {
	ALIVE,
	DEFEATED	
}
var state := State.ALIVE


func set_grid_position(value: Vector2i) -> void:
	grid_position = value
	position = Vector2(grid_position * TILE_SIZE) + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)


func set_intent_text(value: String) -> void:
	_intent_label.text = value


func take_damage(amount: int) -> void:
	hp = max(hp - amount, 0)
	if hp <= 0: 
		die()

signal died(enemy)

func die() -> void:
	if state == State.DEFEATED:
		return
	
	state = State.DEFEATED
	died.emit(self)
	
