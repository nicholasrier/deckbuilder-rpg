extends MapPickup
class_name ReplayTile

signal replay_requested(tile: Vector2i)


func _ready() -> void:
	super._ready()
	object_type = "replay tile"
	blocks_movement = false
	is_destructible = false
	is_targetable = false


func activate(_player, _game) -> void:
	if consumed:
		return

	consumed = true
	replay_requested.emit(grid_position)


func disable() -> void:
	consumed = true
	hide()
