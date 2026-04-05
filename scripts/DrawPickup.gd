extends MapPickup
class_name DrawPickup

@export var draw_count := 2


func _ready() -> void:
	super._ready()
	object_type = "draw pickup"


func _apply_pickup_effect(_player, game) -> void:
	if game == null:
		return
	game.resolve_draw_pickup(draw_count)
