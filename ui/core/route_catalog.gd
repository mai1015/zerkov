class_name ZRouteCatalog
extends RefCounted

## Route IDs are public; resource paths are an implementation detail.
const BACK_POP := &"pop"
const BACK_OPEN := &"open"

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

## Back is part of the declared route policy. Screens submit the logical Back
## intent through their CommonUI context; the navigator applies this table only
## after the currently active route has been validated.
const BACK_POLICIES := {
	"title": [BACK_OPEN, "main_menu"],
	"pause": [BACK_POP, ""],
	"build_mode": [BACK_OPEN, "bunker"],
	"crafting": [BACK_OPEN, "bunker"],
	"summary_solo": [BACK_OPEN, "bunker"],
	"summary_squad": [BACK_OPEN, "bunker"],
	"hud": [BACK_OPEN, "pause"],
	"hud_coop": [BACK_OPEN, "pause"],
	"bunker": [BACK_OPEN, "pause"],
	"session": [BACK_OPEN, "pause"],
	"main_menu": [BACK_OPEN, "pause"],
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


static func layer_for(route: String) -> StringName:
	return CommonUIDefaults.LAYER_HUD if role_for(route) == "hud" else CommonUIDefaults.LAYER_MENU


static func priority_for(route: String) -> int:
	return CommonUIDefaults.PRIORITY_HUD if layer_for(route) == CommonUIDefaults.LAYER_HUD else CommonUIDefaults.PRIORITY_MENU


static func is_developer_only(route: String) -> bool:
	return role_for(route) == "study"


static func expected_payload_type(_route: String) -> StringName:
	# Feature-specific route data belongs to tasks 8.4-8.8. Until those typed
	# contracts exist, every registered route explicitly accepts no payload.
	return ZUIRoutePayload.EMPTY_TYPE


static func back_policy_for(route: String) -> Dictionary:
	var entry: Array = BACK_POLICIES.get(route, [BACK_POP, ""])
	return {
		"operation": entry[0],
		"target": entry[1],
	}


static func validate_intent(value: Variant) -> String:
	if not value is ZUIRouteIntent:
		return "Invalid UI route request type."
	var intent := value as ZUIRouteIntent
	if intent.kind < ZUIRouteIntent.Kind.OPEN or intent.kind > ZUIRouteIntent.Kind.BACK:
		return "Unknown UI route request kind."
	if intent.origin < ZUIRouteIntent.Origin.PRODUCTION or intent.origin > ZUIRouteIntent.Origin.SYSTEM:
		return "Unknown UI route request origin."
	if intent.stack_mode < ZUIRouteIntent.StackMode.AUTO or intent.stack_mode > ZUIRouteIntent.StackMode.RESET:
		return "Unknown UI route stack mode."
	var route := String(intent.route_id)
	if route.is_empty() or not ROUTES.has(route):
		return "Unknown UI route: " + route
	if intent.kind == ZUIRouteIntent.Kind.BACK:
		if intent.route_id != intent.origin_route:
			return "Back intent route must match its origin route."
		if intent.stack_mode != ZUIRouteIntent.StackMode.AUTO:
			return "Back intent cannot request a stack mode."
	if intent.payload == null:
		return "Missing typed UI route payload for: " + route
	if intent.payload.type_id != expected_payload_type(route):
		return "Unknown UI route payload '%s' for: %s" % [intent.payload.type_id, route]
	if not intent.payload.is_empty():
		return "Unexpected UI route payload values for: " + route
	if intent.origin == ZUIRouteIntent.Origin.DEVELOPER_CATALOG:
		if intent.kind != ZUIRouteIntent.Kind.OPEN:
			return "Developer catalog authorization only opens catalog selections."
		if intent.authorization == null:
			return "Developer route requires live F1 catalog authorization."
	elif intent.authorization != null:
		return "Unexpected UI route authorization."
	if intent.kind == ZUIRouteIntent.Kind.OPEN \
			and is_developer_only(route) and intent.origin not in [
		ZUIRouteIntent.Origin.DEVELOPER_CATALOG,
		ZUIRouteIntent.Origin.REVIEW,
	]:
		return "Developer route requires the F1 catalog: " + route
	return ""

static func scene_for(route: String) -> PackedScene:
	var path := path_for(route)
	return load(path) as PackedScene if not path.is_empty() and ResourceLoader.exists(path) else null

static func id_for_scene(path: String) -> String:
	for route in ROUTES:
		if path_for(route) == path:
			return str(route)
	return ""
