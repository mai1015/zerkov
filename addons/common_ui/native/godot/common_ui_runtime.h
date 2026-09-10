#ifndef COMMON_UI_RUNTIME_H
#define COMMON_UI_RUNTIME_H

#include "core/cu_core.h"
#include "core/cu_device.h"
#include "godot/common_input_binding_registry.h"
#include "godot/common_ui_handles.h"
#include "resources/common_ui_input_config.h"

#include <godot_cpp/classes/input_event.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace godot {

class Viewport;

// The public, versioned CommonUI façade.
//
// CommonUIRuntime is installed as an autoload by the addon plugin. It adapts
// Godot input, objects, and Callables to the engine-free routing core in
// `native/core` and exposes everything game code needs through ClassDB, so
// GDScript and C# consumers share one contract. Internal core classes are not
// exposed and may be reorganised without changing this façade's version.
class CommonUIRuntime : public Node {
	GDCLASS(CommonUIRuntime, Node)

public:
	// Mirrors cu::RouteResult. Handlers return one of these from a press.
	enum RouteResult {
		ROUTE_UNHANDLED = 0,
		ROUTE_HANDLED = 1,
		ROUTE_HANDLED_CONTINUE = 2,
	};

	// Mirrors cu::TriggerPhase.
	enum TriggerPhase {
		PHASE_PRESSED = 0,
		PHASE_RELEASED = 1,
		PHASE_HOLD_STARTED = 2,
		PHASE_HOLD_REPEAT = 3,
		PHASE_CANCELED = 4,
	};

	// Mirrors cu::Modality.
	enum InputModality {
		MODALITY_UNKNOWN = 0,
		MODALITY_KEYBOARD_MOUSE = 1,
		MODALITY_GAMEPAD = 2,
		MODALITY_TOUCH = 3,
	};

	// Namespace composed into the low bits of every cu::DeviceId this façade
	// hands to the core, so a keyboard/mouse event and the first gamepad --
	// both reported by Godot as device 0 -- resolve to different DeviceIds. The
	// core itself never interprets a DeviceId; only this façade composes and
	// decodes it. See compose_device_id()/device_kind_of() in
	// common_ui_runtime.cpp for the exact encoding and its negative-device-id
	// policy. Reported to handlers as payload["device_kind"].
	enum DeviceKind {
		DEVICE_KIND_UNKNOWN = 0,
		DEVICE_KIND_KEYBOARD_MOUSE = 1,
		DEVICE_KIND_JOYPAD = 2,
		DEVICE_KIND_TOUCH = 3,
	};

	// Mirrors cu::Ineligible; reported by routing diagnostics.
	enum IneligibleReason {
		REASON_NONE = 0,
		REASON_RELEASED = 1,
		REASON_OWNER_INVALID = 2,
		REASON_CONTEXT_INACTIVE = 3,
		REASON_CONTEXT_SUSPENDED = 4,
		REASON_LAYER_INACTIVE = 5,
		REASON_SCREEN_INACTIVE = 6,
		REASON_SCREEN_NOT_TOP = 7,
		REASON_ROUTING_STOPPED = 8,
	};

	CommonUIRuntime();
	~CommonUIRuntime() override;

	static CommonUIRuntime *get_singleton() { return singleton; }

	// Version of this façade contract, independent of the addon version.
	static String get_api_version();

	// -- Registration -------------------------------------------------------

	// Registers `callback` for `action`. Recognised option keys:
	//   owner (Object, required unless the callback carries one)
	//   context (StringName), layer (StringName), screen (Object)
	//   priority (int), ui_user (int), viewport (Viewport)
	//   hold_threshold (float seconds), repeat_interval (float seconds),
	//   repeat_enabled (bool)
	// Legacy display_priority/show_in_action_bar keys are accepted but ignored;
	// presentation comes exclusively from the CommonUIAction definition.
	//
	// The callback receives one Dictionary and returns a RouteResult; the
	// return value is only read for PHASE_PRESSED.
	Ref<CommonUIActionHandle> register_action(const StringName &p_action, const Callable &p_callback,
			const Dictionary &p_options);

	// -- Contexts -----------------------------------------------------------

	// p_viewport scopes the context to a SubViewport routed by a
	// CommonUIViewportRouter, exactly like register_action()'s "viewport"
	// option; null (the default) means the default (root) Viewport.
	Ref<CommonUIContextHandle> push_context(const StringName &p_context, int p_priority, int p_ui_user,
			Object *p_viewport = nullptr);

	// -- Layers and screens -------------------------------------------------
	//
	// Every method below accepts the same trailing p_viewport as push_context()
	// above, for the same reason: a layer/screen registered against a
	// SubViewport's scope must be looked up in that same scope, not silently
	// resolved to the default Viewport.

	void configure_layer(const StringName &p_layer, int p_priority, bool p_active, int p_ui_user,
			Object *p_viewport = nullptr);
	void set_layer_active(const StringName &p_layer, bool p_active, int p_ui_user,
			Object *p_viewport = nullptr);
	void push_screen(const StringName &p_layer, Object *p_screen, int p_ui_user,
			Object *p_viewport = nullptr);
	void remove_screen(const StringName &p_layer, Object *p_screen, int p_ui_user,
			Object *p_viewport = nullptr);
	Object *get_top_screen(const StringName &p_layer, int p_ui_user, Object *p_viewport = nullptr) const;

	// -- Per-Viewport routing ----------------------------------------------
	//
	// The autoload only sees events dispatched to its own (root) Viewport, so a
	// registration scoped to a SubViewport needs something inside that Viewport
	// to forward its events. CommonUIViewportRouter is that node: it observes and
	// routes on behalf of the Viewport it lives in, and the runtime keys all
	// state by (UI user, Viewport) so the two never cross.

	// Device/modality observation for an event seen by a router. Never consumes.
	void observe_viewport_input(const Ref<InputEvent> &p_event);
	// Routes an event for p_viewport's scope and consumes it on that Viewport when
	// a handler does. p_unhandled_stage skips keys and joypad buttons, which the
	// shortcut stage already routed, exactly as the autoload does for the root.
	void route_viewport_input(const Ref<InputEvent> &p_event, Object *p_viewport, bool p_unhandled_stage);
	// A router announces the Viewport it drives so registrations scoped there stop
	// warning that nothing can route them.
	void register_viewport_router(Object *p_viewport);
	void unregister_viewport_router(Object *p_viewport);

	// -- Snapshots and diagnostics ------------------------------------------

	// Immutable snapshot of the actions that could route right now, in the same
	// order the router would evaluate them. p_viewport selects the scope, as
	// above; null means the default Viewport.
	TypedArray<Dictionary> get_active_actions(int p_ui_user, Object *p_viewport = nullptr) const;

	// The most recent routing decision, including why each candidate was
	// selected, skipped, or stopped.
	Dictionary get_last_route_report() const;

	// Immutable snapshot of the active contexts, ordered as routing evaluates
	// them. Suspended contexts are listed and flagged rather than omitted.
	TypedArray<Dictionary> get_active_contexts(int p_ui_user, Object *p_viewport = nullptr) const;

	// Immutable snapshot of the trigger sequences currently captured.
	TypedArray<Dictionary> get_captured_triggers(int p_ui_user, Object *p_viewport = nullptr) const;

	bool has_active_trigger(const StringName &p_action, int p_ui_user, Object *p_viewport = nullptr) const;
	bool cancel_action(const StringName &p_action, int p_ui_user, Object *p_viewport = nullptr);

	// -- Configuration ------------------------------------------------------

	void set_input_config(const Ref<CommonUIInputConfig> &p_config);
	Ref<CommonUIInputConfig> get_input_config() const { return input_config; }

	Ref<CommonInputBindingRegistry> get_binding_registry() const { return binding_registry; }

	// -- Devices and modality -----------------------------------------------

	InputModality get_input_modality() const;
	int get_active_device() const;
	// Name reported by the platform for the active gamepad, used to pick a
	// device profile. Empty for keyboard, mouse, and touch.
	String get_active_device_name() const;

	// Logical glyph identifier for an action under the current device.
	StringName resolve_glyph(const StringName &p_action, int p_slot) const;

	void assign_device_to_user(int p_device, int p_ui_user);
	void unassign_device(int p_device);
	int get_user_for_device(int p_device) const;

	// -- Handle support (called by CommonUIActionHandle/CommonUIContextHandle) --

	bool release_handle(uint64_t p_handle_id);
	bool set_context_suspended(uint64_t p_handle_id, bool p_suspended);
	bool is_handle_active(uint64_t p_handle_id) const;

	void _ready() override;
	void _exit_tree() override;
	void _process(double p_delta) override;
	void _input(const Ref<InputEvent> &p_event) override;
	void _shortcut_input(const Ref<InputEvent> &p_event) override;
	void _unhandled_input(const Ref<InputEvent> &p_event) override;
	// Not a C++ virtual override -- Wrapped/_bind_methods() dispatch this by
	// member-pointer comparison, the same mechanism _ready()/_process() use
	// under the hood (see GDCLASS's _get_notification()). Handles
	// NOTIFICATION_APPLICATION_FOCUS_OUT / NOTIFICATION_WM_WINDOW_FOCUS_OUT by
	// cancelling every captured trigger: nothing guarantees a held action's
	// release ever arrives after focus is lost (e.g. alt-tab).
	void _notification(int p_what);

protected:
	static void _bind_methods();

private:
	// Bridges the engine-free core back to Godot objects and Callables. Kept as
	// a member rather than a second base class so GDCLASS stays single-rooted.
	class Invoker : public cu::HandlerInvoker {
	public:
		explicit Invoker(CommonUIRuntime *p_runtime) :
				runtime(p_runtime) {}

		bool is_owner_valid(cu::OwnerId p_owner) const override;
		cu::RouteResult invoke(const cu::HandlerCall &p_call) override;
		void on_trigger_canceled(const cu::TriggerState &p_trigger, cu::TimeUsec p_time_usec) override;
		void on_active_actions_changed(const cu::ScopeKey &p_scope) override;
		void on_context_changed(const cu::ScopeKey &p_scope) override;

	private:
		CommonUIRuntime *runtime = nullptr;
	};

	cu::Id intern(const StringName &p_name);
	// Cached read-only counterpart to intern(): looks up an already-interned
	// name without creating one, same as calling core.names().find() directly,
	// but consults intern_cache first so a repeated per-frame lookup (e.g.
	// has_active_trigger() polled from an action-bar update) is not a fresh
	// String -> utf8 -> std::string conversion every time.
	cu::Id find_id(const StringName &p_name) const;
	StringName name_of(cu::Id p_id) const;
	cu::ScopeKey scope_for(int p_ui_user, Object *p_viewport) const;
	cu::TriggerPolicy policy_for(const StringName &p_action) const;
	void refresh_routed_actions();
	void prune_callback_cache();
	Dictionary make_route_dictionary(const cu::RouteReport &p_report) const;
	// Warns (once per distinct Viewport instance) when p_viewport is neither
	// null/default nor announced by a live CommonUIViewportRouter, so state
	// scoped to it (a context, layer, screen, or registration) is not silently
	// stranded -- nothing will ever route it. p_what names the call that
	// triggered the check, e.g. "push_context('menu')".
	void warn_if_viewport_unrouted(Object *p_viewport, const String &p_what);
	// Warns (once per distinct unrecognized key string, across every call) on
	// a register_action() options key this façade does not understand, so a
	// typo does not silently mis-scope (or simply no-op) a registration.
	void warn_unknown_options(const Dictionary &p_options, const char *p_method);
	// Observes p_event for modality only. Never marks the event handled.
	void observe_device(const Ref<InputEvent> &p_event, cu::TimeUsec p_time_usec);
	void apply_input_policy();
	// Shared body of both post-GUI routing stages. Routes for p_viewport's scope
	// and consumes on p_viewport; p_unhandled_stage skips events the shortcut
	// stage already routed.
	void route_event(const Ref<InputEvent> &p_event, Viewport *p_viewport, bool p_unhandled_stage);
	void on_joy_connection_changed(int p_device, bool p_connected);
	// Cheap per-tick physical-state resync: verifies every captured trigger's
	// binding is still physically held via the Input singleton and cancels the
	// ones that are not (a GUI Control ate the corresponding release, for
	// example). No-ops when nothing is captured. See query_physical_state() and
	// the RECONCILE_GRACE_FRAMES policy documented in the .cpp.
	void reconcile_physical_state(cu::TimeUsec p_time_usec);
	// Fills r_checked_any/r_still_down for one captured trigger by polling the
	// Input singleton for whichever of its bindings match the trigger's device
	// kind. r_checked_any stays false when no binding of that kind could be
	// polled (axis holds, touch, or an action outside the loaded config), which
	// tells the caller to skip rather than false-cancel.
	void query_physical_state(const cu::TriggerState &p_trigger, bool &r_checked_any,
			bool &r_still_down) const;

	static CommonUIRuntime *singleton;

	Invoker invoker{ this };
	cu::Core core{ &invoker };

	// Registration handle -> the Callable to run. Kept here so the core never
	// stores an engine value.
	std::unordered_map<uint64_t, Callable> callbacks;
	// Interned id -> StringName, so diagnostics and signals can report names.
	std::unordered_map<cu::Id, StringName> names;
	// StringName -> already-interned id, checked by intern()/find_id() before
	// falling back to core.names() so a per-frame lookup of an already-known
	// name (resolve_glyph(), has_active_trigger(), ...) skips the
	// String -> utf8 -> std::string conversion intern()/StringInterner::find()
	// would otherwise redo every single call. The interner itself is
	// append-only and this cache is a pure subset of it, so nothing ever
	// invalidates an entry once written.
	HashMap<StringName, cu::Id> intern_cache;
	// Registration handles a nil-return warning has already been printed for,
	// so a handler that always forgets its return value warns once instead of
	// on every press. Pruned alongside `callbacks`.
	std::unordered_set<uint64_t> nil_return_warned;
	// Viewport instance ids warn_if_viewport_unrouted() has already warned
	// about, so a setup call repeated every frame (or a whole batch of
	// registrations against the same still-unrouted SubViewport) warns once
	// instead of spamming the console.
	std::unordered_set<uint64_t> warned_unrouted_viewports;
	// register_action() options-dictionary keys warn_unknown_options() has
	// already warned about.
	std::unordered_set<std::string> warned_unknown_option_keys;
	// Interned layer ids push_screen() has already warned about pushing a
	// screen onto without that layer ever being configured.
	std::unordered_set<cu::Id> warned_unconfigured_layers;

	Ref<CommonUIInputConfig> input_config;
	Ref<CommonInputBindingRegistry> binding_registry;

	cu::ModalityTracker modality;
	cu::DeviceAssignment device_assignment;
	// Cached joypad name of the active gamepad, refreshed on device change.
	String active_device_name;

	// Timestamp reconcile_physical_state() last ran at (0 before the first
	// call). A trigger captured at or after this time is given at least one
	// more full _process cycle before it is ever considered for physical-state
	// cancellation, so a press can never be false-cancelled by its own frame's
	// reconciliation pass.
	cu::TimeUsec last_reconcile_usec = 0;
	// Consecutive reconcile_physical_state() passes a given (scope, action)'s
	// captured trigger has been observed as physically released. Cancellation
	// only happens once this reaches RECONCILE_GRACE_FRAMES, so a trigger
	// captured and released within a couple of frames -- as a few of this
	// addon's own test helpers do by pushing synthetic events directly into a
	// Viewport without going through Input's physical-state tracking -- is
	// never mistaken for a stranded one.
	std::unordered_map<std::uint64_t, int> reconcile_miss_streak;

	// Cache of the actions an incoming event must be tested against, rebuilt
	// whenever registrations change.
	std::vector<cu::Id> routed_actions;
	std::vector<StringName> routed_action_names;
	bool routed_actions_dirty = true;

	uint64_t default_viewport_id = 0;
	// Viewports with a live CommonUIViewportRouter. Used only to decide whether a
	// non-default-Viewport registration should warn that nothing will route it.
	std::unordered_set<uint64_t> router_viewports;

	// _process() calls core.prune_dead_owners() only every PRUNE_INTERVAL_FRAMES
	// frames instead of every single one -- it is an O(scopes x registrations)
	// ObjectDB-lookup pass, and a dead owner sitting around for a handful of
	// extra frames is harmless: revalidate_triggers() already self-heals any
	// captured trigger whose owner died in the meantime, and routing itself
	// already skips a dead owner's registration via is_owner_valid(). This
	// counter tracks how many frames have elapsed since the last prune.
	int prune_frame_counter = 0;
};

} // namespace godot

VARIANT_ENUM_CAST(CommonUIRuntime::RouteResult);
VARIANT_ENUM_CAST(CommonUIRuntime::TriggerPhase);
VARIANT_ENUM_CAST(CommonUIRuntime::InputModality);
VARIANT_ENUM_CAST(CommonUIRuntime::IneligibleReason);

#endif // COMMON_UI_RUNTIME_H
