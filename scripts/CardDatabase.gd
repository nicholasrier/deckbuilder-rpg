extends RefCounted

const STARTER_DECK := [
	"strike", "strike", "strike", "strike",
	"block", "block", "block", "block",
	"lunge", "lunge",
	"backstab", "backstab",
	"slip_past", "slip_past",
	"unseen", "unseen"
]

const CARDS := {
	"strike": {
		"id": "strike",
		"name": "Strike",
		"cost": 1,
		"text": "Deal 6 damage to an adjacent enemy.",
		"combat_only": false
	},
	"block": {
		"id": "block",
		"name": "Block",
		"cost": 1,
		"text": "Gain 5 block.",
		"combat_only": true
	},
	"lunge": {
		"id": "lunge",
		"name": "Lunge",
		"cost": 1,
		"text": "Move 1 tile toward the enemy, then deal 6 damage if adjacent.",
		"combat_only": false
	},
	"backstab": {
		"id": "backstab",
		"name": "Backstab",
		"cost": 1,
		"text": "Deal 5 damage, or 9 from behind.",
		"combat_only": true
	},
	"slip_past": {
		"id": "slip_past",
		"name": "Slip Past",
		"cost": 1,
		"text": "Swap places with an adjacent enemy.",
		"combat_only": true
	},
	"unseen": {
		"id": "unseen",
		"name": "Unseen",
		"cost": 1,
		"text": "Become hidden. Your next attack deals 50% more damage.",
		"combat_only": false
	}
}


static func make_card(card_id: String) -> Dictionary:
	return CARDS[card_id].duplicate(true)


static func make_starter_deck() -> Array[Dictionary]:
	var deck: Array[Dictionary] = []
	for card_id in STARTER_DECK:
		deck.append(make_card(card_id))
	return deck
