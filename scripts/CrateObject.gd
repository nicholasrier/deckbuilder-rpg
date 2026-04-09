extends EnvironmentObject
class_name CrateObject


func _ready() -> void:
	object_type = "crate"
	blocks_movement = true
	max_hp = 4
	hp = max_hp
	is_destructible = true
	is_targetable = true
	is_movable = true
