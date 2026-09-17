class_name LocalUIHost
extends "res://ui/main.gd"
## Production composition supplies the existing host's provider and Character
## runtime. The additional port contains values and commands, not game owners.
var _local_game_port: LocalGameUI
func inject_local_game_ui(port: LocalGameUI) -> bool:
	if is_inside_tree() or _local_game_port != null or port == null or port.snapshot().is_empty(): return false
	_local_game_port = port
	return true
func local_game_ui() -> LocalGameUI:
	return null if qa_mode or prototype_fixture_mode else _local_game_port
func _refresh_unbound_production_screen() -> void:
	# Local screen bindings update in place after one complete frame publication.
	if _local_game_port == null: super._refresh_unbound_production_screen()

## These home workspaces reuse the same presentation owner as Character.
## The generic host's route policy stays unchanged; previews and non-home
## origins never receive the campaign runtime through this extension.
func character_runtime_for_route(route: String, origin: ZUIRouteIntent.Origin) -> CharacterUIRuntime:
	if route in ["crafting", "build_mode", "session", "bunker", "maps"]:
		var port := local_game_ui()
		if origin != ZUIRouteIntent.Origin.PRODUCTION or port == null \
			or port.snapshot().get("mode") != "home": return null
		return _character_runtime_override if is_instance_valid(_character_runtime_override) else null
	return super.character_runtime_for_route(route, origin)


func _on_route_committed(route: String, view: Control) -> void:
	super._on_route_committed(route, view)
	var port := local_game_ui()
	if port == null or route not in LocalJourneyPresenter.ROUTES or not view is ZScreen: return
	if (view as ZScreen).app.local_game_ui() != port: return
	var presenter := LocalJourneyPresenter.new()
	presenter.name = "JourneyUX"
	view.add_child(presenter)
	presenter.bind(view, port)
