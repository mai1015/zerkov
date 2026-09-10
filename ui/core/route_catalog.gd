class_name ZRouteCatalog
extends RefCounted

## Route IDs are public; resource paths are an implementation detail.
const ROUTES := {
	"title": ["09a · Title", "res://ui/screens/frontflow/title.tscn", "root"],
	"main_menu": ["10a · Main menu", "res://ui/screens/frontflow/main_menu.tscn", "root"],
	"saves": ["10b · Worlds / saves", "res://ui/screens/frontflow/saves.tscn", "page"],
	"join_friend": ["10e · Join a friend", "res://ui/screens/frontflow/join_friend.tscn", "page"],
	"session": ["10c · Bunker session", "res://ui/screens/bunker/session.tscn", "bunker"],
	"bunker": ["08a · Bunker stations", "res://ui/screens/bunker/bunker.tscn", "bunker"],
	"build_mode": ["08b · Build mode", "res://ui/screens/bunker/build_mode.tscn", "bunker"],
	"crafting": ["08c · Crafting", "res://ui/screens/bunker/crafting.tscn", "bunker"],
	"deploying": ["09c · Deploying", "res://ui/screens/frontflow/deploying.tscn", "root"],
	"hud": ["03a · Raid HUD", "res://ui/screens/raid/hud.tscn", "hud"],
	"hud_coop": ["05b · Co-op HUD", "res://ui/screens/raid/hud_coop.tscn", "hud"],
	"hud_detail": ["03a · HUD detail study", "res://ui/dev/screens/hud_detail.tscn", "study"],
	"inventory": ["03a · Inventory / gear", "res://ui/screens/character/inventory.tscn", "workspace"],
	"health": ["03a · Inventory / health", "res://ui/screens/character/health.tscn", "workspace"],
	"stats": ["04d · Stats / skill rulers", "res://ui/screens/character/stats.tscn", "workspace"],
	"maps": ["06a · Maps", "res://ui/screens/utilities/maps.tscn", "workspace"],
	"tasks": ["06b · Tasks", "res://ui/screens/utilities/tasks.tscn", "workspace"],
	"settings": ["07a · Settings", "res://ui/screens/utilities/settings.tscn", "workspace"],
	"controls": ["09d · Controls", "res://ui/screens/utilities/controls.tscn", "workspace"],
	"pause": ["10d · Pause", "res://ui/screens/raid/pause.tscn", "pause"],
	"summary_solo": ["11a · Raid summary / solo", "res://ui/screens/raid/summary_solo.tscn", "summary"],
	"summary_squad": ["11b · Raid summary / squad", "res://ui/screens/raid/summary_squad.tscn", "summary"],
	"crosshairs": ["05a · Crosshairs", "res://ui/dev/screens/crosshairs.tscn", "study"],
	"status_icons": ["03a · Status icons", "res://ui/dev/screens/status_icons.tscn", "study"],
	"squad_list": ["05c · Squad list", "res://ui/dev/screens/squad_list.tscn", "study"],
	"reload": ["03a · Reload ring", "res://ui/dev/screens/reload.tscn", "study"],
	"mag_empty": ["03a · Mag empty", "res://ui/dev/screens/mag_empty.tscn", "study"],
	"showcase": ["UI · Component states", "res://ui/dev/screens/showcase.tscn", "study"],
}

static func labels() -> Dictionary:
	var result := {}
	for route in ROUTES:
		result[route] = ROUTES[route][0]
	return result

static func path_for(route: String) -> String:
	return str(ROUTES[route][1]) if ROUTES.has(route) else ""

static func role_for(route: String) -> String:
	return str(ROUTES[route][2]) if ROUTES.has(route) else ""

static func scene_for(route: String) -> PackedScene:
	var path := path_for(route)
	return load(path) as PackedScene if not path.is_empty() and ResourceLoader.exists(path) else null

static func id_for_scene(path: String) -> String:
	for route in ROUTES:
		if path_for(route) == path:
			return str(route)
	return ""
