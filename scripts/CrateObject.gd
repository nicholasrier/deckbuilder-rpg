extends EnvironmentObject
class_name CrateObject


func _ready() -> void:
	object_type = "crate"
	blocks_movement = true
	max_hp = 4
	hp = max_hp
	destructible = true
	targetable = true
