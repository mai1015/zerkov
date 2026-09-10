extends RefCounted

static func worlds() -> Array[Dictionary]:
	var fallback: Array[Dictionary] = [
		{"name": "OAK'S BUNKER", "difficulty": "STANDARD", "bunker": "LVL 3", "character": "LVL 14", "playtime": "41 h", "last": "2 h ago", "cloud": "synced"},
		{"name": "NO INSURANCE RUN", "difficulty": "HARDCORE", "bunker": "LVL 1", "character": "LVL 4", "playtime": "6 h", "last": "3 days ago", "cloud": "synced"},
		{"name": "CO-OP WITH KEV", "difficulty": "STANDARD", "bunker": "LVL 2", "character": "LVL 9", "playtime": "12 h", "last": "1 week ago", "cloud": "pending upload"}
	]
	return fallback
