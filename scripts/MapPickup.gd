extends EnvironmentObject
class_name MapPickup

var consumed := false


func _ready() -> void:
	object_type = "pickup"
	blocks_movement = false
	is_destructible = false
	is_targetable = false


func triggers_on_player_enter() -> bool:
	return true


func on_player_enter(player, game) -> void:
	activate(player, game)


func activate(player, game) -> void:
	if consumed:
		return

	consumed = true
	_apply_pickup_effect(player, game)
	if game != null and is_instance_valid(self):
		game.consume_map_pickup(self)


func _apply_pickup_effect(_player, _game) -> void:
	pass
