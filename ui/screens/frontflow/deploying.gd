extends "res://ui/screens/frontflow/frontflow_actions.gd"

## Authored deployment loading screen controller.
##
## The visual hierarchy is authored in deploying.tscn. This script only binds
## the inherited progress state, starts its timer callback, and queues the
## existing compact reflow from frontflow.gd.

func build() -> void:
	reset_adaptive_layout()
	active_route = str(app.current_route)
	menu_entries.clear()

	deploy_phase_label = get_node("DeployCenter/Phase") as Label
	deploy_bar = get_node("DeployCenter/Progress") as ProgressBar
	deploy_value_label = get_node("DeployCenter/Value") as Label
	_install_authored_scale_safe_styles()
	_initialize_deployment_state()
	_wire_deployment_timer()
	queue_adaptive_layout()


func _initialize_deployment_state() -> void:
	var initial: float = float(app.fixture_get("frontflow_deploy_percent", 68.0))
	if initial < 1.0 or initial >= 100.0:
		initial = 68.0
	deploy_bar.value = initial
	deploy_value_label.text = "%d%%" % int(initial)
	app.fixture_set("frontflow_deploy_percent", initial)


func _wire_deployment_timer() -> void:
	var timer: Timer = get_node_or_null("FrontflowDeployTimer") as Timer
	if timer == null:
		timer = Timer.new()
		timer.name = "FrontflowDeployTimer"
		timer.wait_time = 0.7
		timer.one_shot = false
		add_child(timer)
	var callback := Callable(self, "_advance_deploy")
	if not timer.timeout.is_connected(callback):
		timer.timeout.connect(callback)
	timer.start()
