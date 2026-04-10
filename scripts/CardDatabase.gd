extends RefCounted

const STARTER_DECK := [
	"strike", "strike", "strike", "strike",
	"block", "block", "block", "block",
	"lunge",
	"throwing_dagger", "throwing_dagger",
	"backstab", "backstab", "backstab", "backstab",
	"slip_past",
	"unseen", "unseen",
	"dash", "dash", "dash"
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
		"combat_only": false
	},
	"lunge": {
		"id": "lunge",
		"name": "Lunge",
		"cost": 1,
		"text": "Move 1 tile toward the enemy, then deal 6 damage if adjacent.",
		"combat_only": false
	},
	"throwing_dagger": {
		"id": "throwing_dagger",
		"name": "Throwing Dagger",
		"cost": 1,
		"text": "Throw in a straight cardinal line. Deal 4 damage. Exhaust.",
		"combat_only": false,
		"targeting": "directional_projectile",
		"damage": 4,
		"max_range": -1,
		"breaks_stealth": true,
		"exhaust": true
	},
	"backstab": {
		"id": "backstab",
		"name": "Backstab",
		"cost": 1,
		"text": "Deal 5 damage, or 9 from behind.",
		"combat_only": false
	},
	"slip_past": {
		"id": "slip_past",
		"name": "Slip Past",
		"cost": 1,
		"text": "Swap places with an adjacent movable target.",
		"combat_only": false
	},
	"unseen": {
		"id": "unseen",
		"name": "Unseen",
		"cost": 1,
		"text": "Become hidden. Your next attack deals 50% more damage.",
		"combat_only": false
	},
	"dash": {
		"id": "dash",
		"name": "dash",
		"cost": 0,
		"text": "Move quickly. Add one tile to your next movement this turn.",
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
