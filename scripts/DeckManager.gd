extends RefCounted

var deck: Array[Dictionary] = []
var draw_pile: Array[Dictionary] = []
var hand: Array[Dictionary] = []
var discard_pile: Array[Dictionary] = []
var exhaust_pile: Array[Dictionary] = []


func setup(cards: Array[Dictionary]) -> void:
	deck = cards.duplicate(true)
	draw_pile = cards.duplicate(true)
	hand.clear()
	discard_pile.clear()
	exhaust_pile.clear()
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


func add_card_to_deck(card: Dictionary) -> void:
	if card.is_empty():
		return
	deck.append(card.duplicate(true))


func add_card_to_hand(card: Dictionary) -> Dictionary:
	if card.is_empty():
		return {}
	var hand_card := card.duplicate(true)
	hand.append(hand_card)
	return hand_card


func discard_from_hand(index: int) -> Dictionary:
	if index < 0 or index >= hand.size():
		return {}
	var card := hand[index]
	hand.remove_at(index)
	discard_pile.append(card)
	return card


func play_from_hand(index: int, exhaust: bool = false) -> Dictionary:
	if index < 0 or index >= hand.size():
		return {}
	var card := hand[index]
	hand.remove_at(index)
	if exhaust:
		exhaust_pile.append(card)
	else:
		discard_pile.append(card)
	return card


func recover_exhausted_cards() -> int:
	var recovered_count := exhaust_pile.size()
	if recovered_count <= 0:
		return 0
	discard_pile.append_array(exhaust_pile)
	exhaust_pile.clear()
	return recovered_count
