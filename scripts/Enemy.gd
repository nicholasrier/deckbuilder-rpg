extends CharacterBody2D

class_name Enemy

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
var threat_offsets: Array[Vector2i] = []

func _ready() -> void:
	threat_offsets = [
		Vector2i(0, 1),
		Vector2i(1, 0),
		Vector2i(0, -1),
		Vector2i(-1, 0)
	]

func set_grid_position(value: Vector2i) -> void:
	grid_position = value
	@warning_ignore("integer_division")
	position = Vector2(grid_position * TILE_SIZE) + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)
	moved.emit(self)

func get_threatened_tiles() -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	for offset in threat_offsets:
		tiles.append(grid_position + offset)
	return tiles

func set_intent_text(value: String) -> void:
	if _intent_label.text == value:
		return
	_intent_label.text = value
	intent_changed.emit(self, _intent_label.text)

func take_damage(amount: int) -> void:
	hp = max(hp - amount, 0)
	if hp <= 0: 
		die()

signal died(enemy)
signal moved(enemy)
signal intent_changed(enemy, new_intent)

func die() -> void:
	if state == State.DEFEATED:
		return
	
	state = State.DEFEATED
	died.emit(self)

	
	
