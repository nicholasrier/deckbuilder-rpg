extends MapPickup
class_name RewardPickup

signal reward_requested(pickup: RewardPickup, reward_options: Array)

var reward_options: Array[Dictionary] = []


func _ready() -> void:
	super._ready()
	object_type = "reward pickup"


func configure(options: Array[Dictionary]) -> void:
	reward_options = options.duplicate(true)


func activate(_player, _game) -> void:
	if consumed:
		return
	if reward_options.is_empty():
		return
	reward_requested.emit(self, reward_options.duplicate(true))


func mark_consumed() -> void:
	consumed = true
