extends RefCounted

var draw_pile: Array[Dictionary] = []
var hand: Array[Dictionary] = []
var discard_pile: Array[Dictionary] = []


func setup(cards: Array[Dictionary]) -> void:
	draw_pile = cards.duplicate(true)
	hand.clear()
	discard_pile.clear()
	shuffle_draw_pile()


func shuffle_draw_pile() -> void:
	draw_pile.shuffle()


func draw_cards(count: int) -> Array[Dictionary]:
	var drawn: Array[Dictionary] = []
	for _i in range(count):
		if draw_pile.is_empty():
			if discard_pile.is_empty():
				break
			draw_pile = discard_pile.duplicate(true)
			discard_pile.clear()
			shuffle_draw_pile()
		var card: Dictionary = draw_pile.pop_back()
		hand.append(card)
		drawn.append(card)
	return drawn


func discard_from_hand(index: int) -> Dictionary:
	if index < 0 or index >= hand.size():
		return {}
	var card := hand[index]
	hand.remove_at(index)
	discard_pile.append(card)
	return card


func play_from_hand(index: int) -> Dictionary:
	if index < 0 or index >= hand.size():
		return {}
	var card := hand[index]
	hand.remove_at(index)
	discard_pile.append(card)
	return card
