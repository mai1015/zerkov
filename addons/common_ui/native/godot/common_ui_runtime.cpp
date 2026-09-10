#include "godot/common_ui_runtime.h"

#include "resources/common_ui_binding.h"

#include <algorithm>

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/input.hpp>
#include <godot_cpp/classes/input_event_joypad_button.hpp>
#include <godot_cpp/classes/input_event_joypad_motion.hpp>
#include <godot_cpp/classes/input_event_key.hpp>
#include <godot_cpp/classes/input_event_mouse_button.hpp>
#include <godot_cpp/classes/input_event_mouse_motion.hpp>
#include <godot_cpp/classes/input_event_screen_drag.hpp>
#include <godot_cpp/classes/input_event_screen_touch.hpp>
#include <godot_cpp/classes/input_map.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {

CommonUIRuntime *CommonUIRuntime::singleton = nullptr;

namespace {

// Seconds are the project-facing unit; the core works in microseconds.
cu::TimeUsec to_usec(double p_seconds) {
	return p_seconds <= 0.0 ? 0 : static_cast<cu::TimeUsec>(p_seconds * 1'000'000.0);
}

int option_int(const Dictionary &p_options, const char *p_key, int p_default) {
	return p_options.has(p_key) ? static_cast<int>(p_options[p_key]) : p_default;
}

bool option_bool(const Dictionary &p_options, const char *p_key, bool p_default) {
	return p_options.has(p_key) ? static_cast<bool>(p_options[p_key]) : p_default;
}

double option_float(const Dictionary &p_options, const char *p_key, double p_default) {
	return p_options.has(p_key) ? static_cast<double>(p_options[p_key]) : p_default;
}

StringName option_name(const Dictionary &p_options, const char *p_key) {
	return p_options.has(p_key) ? StringName(p_options[p_key]) : StringName();
}

Object *option_object(const Dictionary &p_options, const char *p_key) {
	if (!p_options.has(p_key)) {
		return nullptr;
	}
	return Object::cast_to<Object>(p_options[p_key]);
}

// ---------------------------------------------------------------------------
// Device-id namespacing (Bug: DeviceId not namespaced by device class)
//
// Godot's InputEvent::get_device() is not unique across device *classes*: a
// keyboard or mouse event reports device 0, and so does the first gamepad.
// cu::DeviceId is a raw platform value with no notion of device class, so the
// core cannot tell a keyboard-0 from a gamepad-0 apart on its own -- and it
// should not have to; cu_ids.h deliberately keeps DeviceId an opaque engine
// value. This façade is the boundary that composes a (kind, raw index) pair
// into the DeviceId the core sees, so those two devices resolve to different
// values everywhere a device id enters the core (press/release/cancel_device).
//
// Encoding: (kind << 16) | (raw_index & 0xFFFF). Kinds come from
// CommonUIRuntime::DeviceKind; the low 16 bits are ample for any real device
// index (joypads top out in the single digits; keyboard/mouse are always 0).
//
// Negative device ids: Godot reports device -1 ("all devices") on some
// synthetic events, and cu::INVALID_DEVICE is also -1 -- Core treats it as a
// wildcard that matches any captured device (see
// Core::find_releasable_trigger_index()). Composing a namespaced value for -1
// would turn that wildcard into an ordinary namespaced id and silently break
// every device-match check built on it, so a negative raw index is passed
// through unchanged as INVALID_DEVICE instead of being namespaced. It decodes
// back to DEVICE_KIND_UNKNOWN / index -1.
constexpr int DEVICE_KIND_SHIFT = 16;
constexpr cu::DeviceId DEVICE_INDEX_MASK = 0xFFFF;

cu::DeviceId compose_device_id(CommonUIRuntime::DeviceKind p_kind, int p_raw_index) {
	if (p_raw_index < 0) {
		return cu::INVALID_DEVICE;
	}
	return (static_cast<cu::DeviceId>(p_kind) << DEVICE_KIND_SHIFT) |
			(static_cast<cu::DeviceId>(p_raw_index) & DEVICE_INDEX_MASK);
}

CommonUIRuntime::DeviceKind device_kind_of(cu::DeviceId p_device) {
	if (p_device == cu::INVALID_DEVICE) {
		return CommonUIRuntime::DEVICE_KIND_UNKNOWN;
	}
	return static_cast<CommonUIRuntime::DeviceKind>((p_device >> DEVICE_KIND_SHIFT) & DEVICE_INDEX_MASK);
}

int device_index_of(cu::DeviceId p_device) {
	if (p_device == cu::INVALID_DEVICE) {
		return -1;
	}
	return static_cast<int>(p_device & DEVICE_INDEX_MASK);
}

// Device kind an InputEvent belongs to, derived from its concrete subclass.
// Keyboard and mouse deliberately share DEVICE_KIND_KEYBOARD_MOUSE: Godot
// does not namespace either against the other, and the framework never needs
// to tell them apart (see CommonUIBinding::DeviceKind, which the binding
// resources use and which this kind is not required to match one-to-one --
// keyboard and mouse are two of its values but only one of this façade's).
CommonUIRuntime::DeviceKind device_kind_of_event(const Ref<InputEvent> &p_event) {
	if (Ref<InputEventJoypadButton>(p_event).is_valid() || Ref<InputEventJoypadMotion>(p_event).is_valid()) {
		return CommonUIRuntime::DEVICE_KIND_JOYPAD;
	}
	if (Ref<InputEventKey>(p_event).is_valid() || Ref<InputEventMouseButton>(p_event).is_valid() ||
			Ref<InputEventMouseMotion>(p_event).is_valid()) {
		return CommonUIRuntime::DEVICE_KIND_KEYBOARD_MOUSE;
	}
	if (Ref<InputEventScreenTouch>(p_event).is_valid() || Ref<InputEventScreenDrag>(p_event).is_valid()) {
		return CommonUIRuntime::DEVICE_KIND_TOUCH;
	}
	return CommonUIRuntime::DEVICE_KIND_UNKNOWN;
}

cu::DeviceId composed_device_of(const Ref<InputEvent> &p_event) {
	return compose_device_id(device_kind_of_event(p_event), p_event->get_device());
}

} // namespace

CommonUIRuntime::CommonUIRuntime() {
	if (singleton == nullptr) {
		singleton = this;
	}
}

CommonUIRuntime::~CommonUIRuntime() {
	if (singleton == this) {
		singleton = nullptr;
	}
}

String CommonUIRuntime::get_api_version() {
	// Major.minor of the façade contract, not of the addon release.
	return "0.1";
}

// ---------------------------------------------------------------------------
// Invoker bridge
// ---------------------------------------------------------------------------

bool CommonUIRuntime::Invoker::is_owner_valid(cu::OwnerId p_owner) const {
	// Checked lookup: the core never holds a raw scene pointer, so a freed owner
	// simply stops resolving.
	return p_owner != 0 && ObjectDB::get_instance(p_owner) != nullptr;
}

cu::RouteResult CommonUIRuntime::Invoker::invoke(const cu::HandlerCall &p_call) {
	auto found = runtime->callbacks.find(p_call.registration);
	if (found == runtime->callbacks.end() || !found->second.is_valid()) {
		return cu::RouteResult::UNHANDLED;
	}

	Dictionary payload;
	payload["action"] = runtime->name_of(p_call.action);
	payload["phase"] = static_cast<int>(p_call.phase);
	// "device" is the same composed id the core routed on (namespaced by
	// device kind -- see compose_device_id() above); "device_kind" and
	// "device_index" are its decoded parts so a handler does not need to do
	// its own bit math to tell a keyboard press from a gamepad's.
	payload["device"] = p_call.device;
	payload["device_kind"] = static_cast<int>(device_kind_of(p_call.device));
	payload["device_index"] = device_index_of(p_call.device);
	payload["ui_user"] = static_cast<int>(p_call.scope.user);
	payload["viewport_id"] = p_call.scope.viewport;
	payload["time_usec"] = p_call.time_usec;
	payload["repeat_index"] = p_call.repeat_index;
	payload["handle_id"] = p_call.registration;

	const Variant result = found->second.call(payload);
	if (p_call.phase != cu::TriggerPhase::PRESSED) {
		return cu::RouteResult::UNHANDLED;
	}
	if (result.get_type() == Variant::NIL && runtime->nil_return_warned.insert(p_call.registration).second) {
		// A day-one adopter bug: a handler that falls off the end (or returns
		// early) without an explicit `return CommonUIRuntime.ROUTE_*` silently
		// becomes UNHANDLED. Warn once per handler so it is self-diagnosing
		// instead of a mysteriously unresponsive action.
		WARN_PRINT(vformat(
				"CommonUIRuntime: handler for '%s' returned no route result; treating as UNHANDLED.",
				String(runtime->name_of(p_call.action))));
	}
	const int value = static_cast<int>(result);
	switch (value) {
		case ROUTE_HANDLED:
			return cu::RouteResult::HANDLED;
		case ROUTE_HANDLED_CONTINUE:
			return cu::RouteResult::HANDLED_CONTINUE;
		default:
			return cu::RouteResult::UNHANDLED;
	}
}

void CommonUIRuntime::Invoker::on_trigger_canceled(const cu::TriggerState &p_trigger, cu::TimeUsec) {
	runtime->emit_signal("trigger_canceled", runtime->name_of(p_trigger.action),
			static_cast<int>(p_trigger.scope.user));
}

void CommonUIRuntime::Invoker::on_active_actions_changed(const cu::ScopeKey &p_scope) {
	// A release requested inside a handler is applied only after that dispatch.
	// Cleaning here keeps every callback in the stable snapshot callable, then
	// drops it as soon as the core no longer owns its handle.
	runtime->prune_callback_cache();
	runtime->routed_actions_dirty = true;
	runtime->emit_signal("active_actions_changed", static_cast<int>(p_scope.user));
}

void CommonUIRuntime::Invoker::on_context_changed(const cu::ScopeKey &p_scope) {
	runtime->emit_signal("context_changed", static_cast<int>(p_scope.user));
}

// ---------------------------------------------------------------------------
// Name and scope helpers
// ---------------------------------------------------------------------------

cu::Id CommonUIRuntime::intern(const StringName &p_name) {
	const cu::Id *cached = intern_cache.getptr(p_name);
	if (cached != nullptr) {
		return *cached;
	}
	const String text = String(p_name);
	if (text.is_empty()) {
		// Never cached: every empty StringName means "no name" identically, so
		// there is nothing to gain from caching this one degenerate case.
		return cu::INVALID_ID;
	}
	const cu::Id id = core.names().intern(text.utf8().get_data());
	names[id] = p_name;
	intern_cache[p_name] = id;
	return id;
}

cu::Id CommonUIRuntime::find_id(const StringName &p_name) const {
	const cu::Id *cached = intern_cache.getptr(p_name);
	if (cached != nullptr) {
		return *cached;
	}
	return core.names().find(String(p_name).utf8().get_data());
}

StringName CommonUIRuntime::name_of(cu::Id p_id) const {
	auto found = names.find(p_id);
	if (found != names.end()) {
		return found->second;
	}
	return StringName(String::utf8(core.names().text(p_id).c_str()));
}

cu::ScopeKey CommonUIRuntime::scope_for(int p_ui_user, Object *p_viewport) const {
	cu::ScopeKey scope;
	scope.user = static_cast<cu::UserId>(p_ui_user < 0 ? 0 : p_ui_user);
	scope.viewport = p_viewport != nullptr ? p_viewport->get_instance_id() : default_viewport_id;
	return scope;
}

void CommonUIRuntime::warn_if_viewport_unrouted(Object *p_viewport, const String &p_what) {
	if (p_viewport == nullptr) {
		return;
	}
	const uint64_t viewport_id = p_viewport->get_instance_id();
	if (viewport_id == default_viewport_id ||
			router_viewports.find(viewport_id) != router_viewports.end()) {
		return;
	}
	if (!warned_unrouted_viewports.insert(viewport_id).second) {
		return;
	}
	// The autoload only routes its own (root) Viewport. State scoped to another
	// Viewport is routed by a CommonUIViewportRouter placed inside it; without
	// one, nothing will ever reach it. Say so rather than failing silently. (A
	// router added later clears router_viewports for its scope, but this
	// warning does not retroactively un-warn -- it already told the caller once.)
	UtilityFunctions::push_warning(vformat(
			"CommonUIRuntime: %s is scoped to a Viewport with no CommonUIViewportRouter. "
			"Add one inside that Viewport so its input is routed.",
			p_what));
}

void CommonUIRuntime::warn_unknown_options(const Dictionary &p_options, const char *p_method) {
	static const std::unordered_set<std::string> known_keys = {
		"owner",
		"context",
		"layer",
		"screen",
		"priority",
		"ui_user",
		"viewport",
		"display_priority",
		"show_in_action_bar",
		"hold_threshold",
		"repeat_interval",
		"repeat_enabled",
	};
	const Array keys = p_options.keys();
	for (int i = 0; i < keys.size(); ++i) {
		if (keys[i].get_type() != Variant::STRING && keys[i].get_type() != Variant::STRING_NAME) {
			continue;
		}
		const String key_name = keys[i];
		const std::string key = key_name.utf8().get_data();
		if (known_keys.find(key) != known_keys.end()) {
			continue;
		}
		if (warned_unknown_option_keys.insert(key).second) {
			UtilityFunctions::push_warning(vformat(
					"CommonUIRuntime.%s: unrecognized option '%s'.", String(p_method), key_name));
		}
	}
}

cu::TriggerPolicy CommonUIRuntime::policy_for(const StringName &p_action) const {
	cu::TriggerPolicy policy;
	if (input_config.is_null()) {
		return policy;
	}
	const Ref<CommonUIAction> action = input_config->find_action(p_action);
	if (action.is_null()) {
		return policy;
	}
	// Hold and repeat timing comes from the action definition, never from the
	// operating system's key echo.
	policy.hold_threshold_usec = to_usec(action->get_hold_threshold());
	policy.repeat_interval_usec = to_usec(action->get_repeat_interval());
	policy.repeat_enabled = action->is_repeat_enabled();
	return policy;
}

void CommonUIRuntime::refresh_routed_actions() {
	routed_actions = core.registered_actions();
	routed_action_names.clear();
	routed_action_names.reserve(routed_actions.size());
	for (cu::Id id : routed_actions) {
		routed_action_names.push_back(name_of(id));
	}
	routed_actions_dirty = false;
}

void CommonUIRuntime::prune_callback_cache() {
	for (auto callback = callbacks.begin(); callback != callbacks.end();) {
		if (!core.is_handle_known(callback->first)) {
			nil_return_warned.erase(callback->first);
			callback = callbacks.erase(callback);
		} else {
			++callback;
		}
	}
}

// ---------------------------------------------------------------------------
// Façade
// ---------------------------------------------------------------------------

Ref<CommonUIActionHandle> CommonUIRuntime::register_action(const StringName &p_action,
		const Callable &p_callback, const Dictionary &p_options) {
	Ref<CommonUIActionHandle> handle;
	handle.instantiate();

	if (String(p_action).is_empty()) {
		UtilityFunctions::push_error("CommonUIRuntime.register_action: action name is empty.");
		return handle;
	}
	if (!p_callback.is_valid()) {
		UtilityFunctions::push_error(vformat(
				"CommonUIRuntime.register_action: callback for '%s' is not valid.", String(p_action)));
		return handle;
	}

	warn_unknown_options(p_options, "register_action");

	// The owner governs the registration's lifetime. It defaults to the object
	// the callback is bound to, which is what a screen or button normally wants.
	Object *owner = option_object(p_options, "owner");
	const uint64_t owner_id = owner != nullptr ? owner->get_instance_id() : p_callback.get_object_id();
	if (owner_id == 0) {
		UtilityFunctions::push_error(vformat(
				"CommonUIRuntime.register_action: '%s' has no owner object.", String(p_action)));
		return handle;
	}

	Object *screen = option_object(p_options, "screen");

	Object *viewport = option_object(p_options, "viewport");
	warn_if_viewport_unrouted(viewport, vformat("register_action: '%s'", String(p_action)));

	cu::RegistrationRequest request;
	request.scope = scope_for(option_int(p_options, "ui_user", 0), viewport);
	request.action = intern(p_action);
	request.context = intern(option_name(p_options, "context"));
	request.layer = intern(option_name(p_options, "layer"));
	request.screen = screen != nullptr ? screen->get_instance_id() : cu::INVALID_OWNER;
	request.owner = owner_id;
	request.priority = option_int(p_options, "priority", 0);
	// Presentation belongs to the CommonUIAction definition. The legacy
	// registration keys remain recognised for compatibility, but cannot create
	// a second, conflicting source for action-bar ordering or visibility.
	const Ref<CommonUIAction> action_definition = input_config.is_valid()
			? input_config->find_action(p_action)
			: Ref<CommonUIAction>();
	request.display_priority = action_definition.is_valid()
			? action_definition->get_display_priority()
			: 0;
	request.show_in_action_bar = action_definition.is_valid()
			? action_definition->is_shown_in_action_bar()
			: true;
	request.hold_threshold_usec = to_usec(option_float(p_options, "hold_threshold", 0.0));
	request.repeat_interval_usec = to_usec(option_float(p_options, "repeat_interval", 0.0));
	request.repeat_enabled = option_bool(p_options, "repeat_enabled", false);
	// An explicitly supplied hold/repeat option wins over whatever policy the
	// loaded CommonUIInputConfig resolves for this action (see policy_for());
	// an omitted option inherits from the config. Without this marker the core
	// cannot tell "explicitly asked for these options" apart from "left every
	// field at its zero/false default".
	request.has_trigger_policy = p_options.has("hold_threshold") || p_options.has("repeat_interval") ||
			p_options.has("repeat_enabled");

	const cu::HandleId handle_id = core.register_action(request);
	if (handle_id == cu::INVALID_HANDLE) {
		return handle;
	}

	callbacks[handle_id] = p_callback;
	routed_actions_dirty = true;

	handle->runtime_id = get_instance_id();
	handle->handle_id = handle_id;
	handle->action = p_action;
	handle->ui_user = static_cast<int>(request.scope.user);
	return handle;
}

Ref<CommonUIContextHandle> CommonUIRuntime::push_context(const StringName &p_context, int p_priority,
		int p_ui_user, Object *p_viewport) {
	Ref<CommonUIContextHandle> handle;
	handle.instantiate();

	const cu::Id context = intern(p_context);
	if (context == cu::INVALID_ID) {
		UtilityFunctions::push_error("CommonUIRuntime.push_context: context name is empty.");
		return handle;
	}
	warn_if_viewport_unrouted(p_viewport, vformat("push_context('%s')", String(p_context)));

	const cu::ScopeKey scope = scope_for(p_ui_user, p_viewport);
	const cu::HandleId handle_id = core.push_context(scope, context, p_priority);
	if (handle_id == cu::INVALID_HANDLE) {
		return handle;
	}

	handle->runtime_id = get_instance_id();
	handle->handle_id = handle_id;
	handle->context = p_context;
	handle->ui_user = static_cast<int>(scope.user);
	return handle;
}

void CommonUIRuntime::configure_layer(const StringName &p_layer, int p_priority, bool p_active,
		int p_ui_user, Object *p_viewport) {
	warn_if_viewport_unrouted(p_viewport, vformat("configure_layer('%s')", String(p_layer)));
	core.configure_layer(scope_for(p_ui_user, p_viewport), intern(p_layer), p_priority, p_active);
}

void CommonUIRuntime::set_layer_active(const StringName &p_layer, bool p_active, int p_ui_user,
		Object *p_viewport) {
	warn_if_viewport_unrouted(p_viewport, vformat("set_layer_active('%s')", String(p_layer)));
	core.set_layer_active(scope_for(p_ui_user, p_viewport), intern(p_layer), p_active);
}

void CommonUIRuntime::push_screen(const StringName &p_layer, Object *p_screen, int p_ui_user,
		Object *p_viewport) {
	if (p_screen == nullptr) {
		return;
	}
	warn_if_viewport_unrouted(p_viewport, vformat("push_screen('%s')", String(p_layer)));
	const cu::Id layer = intern(p_layer);
	const bool pushed = core.push_screen(scope_for(p_ui_user, p_viewport), layer, p_screen->get_instance_id());
	if (!pushed && warned_unconfigured_layers.insert(layer).second) {
		WARN_PRINT(vformat("CommonUIRuntime.push_screen: layer '%s' was never configured.",
				String(p_layer)));
	}
}

void CommonUIRuntime::remove_screen(const StringName &p_layer, Object *p_screen, int p_ui_user,
		Object *p_viewport) {
	if (p_screen == nullptr) {
		return;
	}
	core.remove_screen(scope_for(p_ui_user, p_viewport), intern(p_layer), p_screen->get_instance_id());
}

Object *CommonUIRuntime::get_top_screen(const StringName &p_layer, int p_ui_user, Object *p_viewport) const {
	const cu::Id layer = find_id(p_layer);
	if (layer == cu::INVALID_ID) {
		return nullptr;
	}
	const cu::OwnerId screen = core.top_screen(scope_for(p_ui_user, p_viewport), layer);
	return screen == cu::INVALID_OWNER ? nullptr : ObjectDB::get_instance(screen);
}

TypedArray<Dictionary> CommonUIRuntime::get_active_actions(int p_ui_user, Object *p_viewport) const {
	TypedArray<Dictionary> result;
	for (const cu::ActiveAction &active : core.active_actions(scope_for(p_ui_user, p_viewport))) {
		Dictionary entry;
		const StringName action_name = name_of(active.action);
		const Ref<CommonUIAction> action_definition = input_config.is_valid()
				? input_config->find_action(action_name)
				: Ref<CommonUIAction>();
		entry["action"] = action_name;
		entry["handle_id"] = active.registration;
		entry["context"] = name_of(active.context);
		entry["layer"] = name_of(active.layer);
		entry["priority"] = active.priority;
		entry["display_name"] = action_definition.is_valid()
				? action_definition->get_display_name()
				: String();
		entry["display_priority"] = action_definition.is_valid()
				? action_definition->get_display_priority()
				: 0;
		entry["show_in_action_bar"] = action_definition.is_valid()
				? action_definition->is_shown_in_action_bar()
				: true;
		entry["screen"] = active.screen == cu::INVALID_OWNER
				? Variant()
				: Variant(ObjectDB::get_instance(active.screen));
		result.push_back(entry);
	}
	return result;
}

TypedArray<Dictionary> CommonUIRuntime::get_active_contexts(int p_ui_user, Object *p_viewport) const {
	TypedArray<Dictionary> result;
	for (const cu::ContextEntry &entry : core.active_contexts(scope_for(p_ui_user, p_viewport))) {
		Dictionary item;
		item["context"] = name_of(entry.context);
		item["handle_id"] = entry.handle;
		item["priority"] = entry.priority;
		item["suspended"] = entry.suspended;
		result.push_back(item);
	}
	return result;
}

TypedArray<Dictionary> CommonUIRuntime::get_captured_triggers(int p_ui_user, Object *p_viewport) const {
	TypedArray<Dictionary> result;
	for (const cu::TriggerState &trigger : core.captured_triggers(scope_for(p_ui_user, p_viewport))) {
		Dictionary item;
		item["action"] = name_of(trigger.action);
		item["device"] = trigger.device;
		item["device_kind"] = static_cast<int>(device_kind_of(trigger.device));
		item["device_index"] = device_index_of(trigger.device);
		item["pressed_usec"] = trigger.pressed_usec;
		item["hold_started"] = trigger.hold_started;
		item["repeat_index"] = trigger.repeat_index;
		Array chain;
		for (cu::HandleId handle : trigger.chain) {
			chain.push_back(handle);
		}
		item["chain"] = chain;
		result.push_back(item);
	}
	return result;
}

Dictionary CommonUIRuntime::make_route_dictionary(const cu::RouteReport &p_report) const {
	Dictionary report;
	report["action"] = name_of(p_report.action);
	report["ui_user"] = static_cast<int>(p_report.scope.user);
	// The composed device id (see compose_device_id() above), decoded the same
	// way a handler payload's "device_kind"/"device_index" are.
	report["device"] = p_report.device;
	report["device_kind"] = static_cast<int>(device_kind_of(p_report.device));
	report["device_index"] = device_index_of(p_report.device);
	report["consumed"] = p_report.consumed;
	report["stopped"] = p_report.stopped;
	// True when the press was not routed at all because the action already had
	// a live captured trigger (same-device echo, or a different device -- see
	// Core::press_now()); "consumed" already reflects whether the originating
	// Godot event was marked handled either way.
	report["suppressed"] = p_report.suppressed;

	Array chain;
	for (cu::HandleId handle : p_report.chain) {
		chain.push_back(handle);
	}
	report["chain"] = chain;

	Array entries;
	for (const cu::RouteEntry &entry : p_report.entries) {
		Dictionary item;
		item["handle_id"] = entry.registration;
		item["reason"] = static_cast<int>(entry.reason);
		item["order"] = entry.order;
		item["invoked"] = entry.invoked;
		item["result"] = static_cast<int>(entry.result);
		entries.push_back(item);
	}
	report["entries"] = entries;
	return report;
}

Dictionary CommonUIRuntime::get_last_route_report() const {
	return make_route_dictionary(core.last_route());
}

bool CommonUIRuntime::has_active_trigger(const StringName &p_action, int p_ui_user, Object *p_viewport) const {
	const cu::Id action = find_id(p_action);
	if (action == cu::INVALID_ID) {
		return false;
	}
	return core.has_active_trigger(scope_for(p_ui_user, p_viewport), action);
}

bool CommonUIRuntime::cancel_action(const StringName &p_action, int p_ui_user, Object *p_viewport) {
	const cu::Id action = find_id(p_action);
	if (action == cu::INVALID_ID) {
		return false;
	}
	return core.cancel_action(scope_for(p_ui_user, p_viewport), action,
			Time::get_singleton()->get_ticks_usec());
}

void CommonUIRuntime::set_input_config(const Ref<CommonUIInputConfig> &p_config) {
	if (p_config.is_null()) {
		return;
	}
	if (binding_registry.is_null()) {
		binding_registry.instantiate();
	}
	const PackedStringArray errors = binding_registry->configure(p_config);
	for (int i = 0; i < errors.size(); ++i) {
		UtilityFunctions::push_error(vformat("CommonUI input config: %s", errors[i]));
	}
	if (!errors.is_empty()) {
		// configure() retains the prior effective set on rejection; keep the
		// matching resource and policy as well so the façade never exposes a mixed
		// old-registry/new-config state.
		return;
	}
	input_config = p_config;
	binding_registry->load_overrides();
	apply_input_policy();
}

void CommonUIRuntime::apply_input_policy() {
	if (input_config.is_null()) {
		return;
	}
	const Ref<CommonUIInputPolicy> policy = input_config->get_input_policy();
	if (policy.is_null()) {
		return;
	}
	cu::ModalityPolicy core_policy;
	core_policy.mouse_jitter_threshold = policy->get_mouse_jitter_threshold();
	core_policy.stick_dead_zone = policy->get_stick_dead_zone();
	core_policy.hysteresis_usec = to_usec(policy->get_modality_hysteresis());
	core_policy.mouse_button_always_activates = policy->is_mouse_button_always_activating();
	core_policy.mouse_motion_decay_usec = to_usec(policy->get_mouse_motion_decay());
	modality.set_policy(core_policy);

	device_assignment.set_unassigned_use_default_user(policy->are_unassigned_devices_using_default_user());
	device_assignment.set_shared_device_policy(policy->is_shared_device_policy_enabled());
}

// ---------------------------------------------------------------------------
// Devices and modality
// ---------------------------------------------------------------------------

CommonUIRuntime::InputModality CommonUIRuntime::get_input_modality() const {
	return static_cast<InputModality>(modality.get_modality());
}

int CommonUIRuntime::get_active_device() const {
	return modality.get_active_device();
}

String CommonUIRuntime::get_active_device_name() const {
	return active_device_name;
}

StringName CommonUIRuntime::resolve_glyph(const StringName &p_action, int p_slot) const {
	if (binding_registry.is_null()) {
		return StringName();
	}
	const CommonInputBindingRegistry::Slot slot = p_slot == 1
			? CommonInputBindingRegistry::SLOT_SECONDARY
			: CommonInputBindingRegistry::SLOT_PRIMARY;
	return binding_registry->resolve_glyph(p_action, slot, active_device_name);
}

void CommonUIRuntime::assign_device_to_user(int p_device, int p_ui_user) {
	device_assignment.assign(p_device, static_cast<cu::UserId>(p_ui_user < 0 ? 0 : p_ui_user));
}

void CommonUIRuntime::unassign_device(int p_device) {
	device_assignment.unassign(p_device);
}

int CommonUIRuntime::get_user_for_device(int p_device) const {
	return static_cast<int>(device_assignment.user_for(p_device));
}

void CommonUIRuntime::on_joy_connection_changed(int p_device, bool p_connected) {
	if (p_connected) {
		return;
	}
	// A disconnect cancels anything that device was holding and may clear the
	// active modality. Composing the joypad kind here is what keeps this from
	// also cancelling a keyboard-captured trigger that happens to share raw
	// device index 0 with the disconnected pad (Bug: DeviceId not namespaced).
	core.cancel_device(compose_device_id(DEVICE_KIND_JOYPAD, p_device), Time::get_singleton()->get_ticks_usec());
	if (modality.device_disconnected(p_device, Time::get_singleton()->get_ticks_usec())) {
		active_device_name = String();
		emit_signal("input_modality_changed", static_cast<int>(modality.get_modality()),
				modality.get_active_device());
	}
	device_assignment.unassign(p_device);
}

void CommonUIRuntime::observe_device(const Ref<InputEvent> &p_event, cu::TimeUsec p_time_usec) {
	bool changed = false;

	const Ref<InputEventMouseMotion> motion = p_event;
	if (motion.is_valid()) {
		changed = modality.observe_mouse_motion(motion->get_relative().length(), p_time_usec);
	} else if (Ref<InputEventMouseButton>(p_event).is_valid()) {
		changed = modality.observe_mouse_button(p_time_usec);
	} else if (Ref<InputEventKey>(p_event).is_valid()) {
		changed = modality.observe_key(p_time_usec);
	} else if (Ref<InputEventJoypadButton>(p_event).is_valid()) {
		changed = modality.observe_gamepad_button(p_event->get_device(), p_time_usec);
	} else {
		const Ref<InputEventJoypadMotion> joypad_motion = p_event;
		if (joypad_motion.is_valid()) {
			changed = modality.observe_gamepad_axis(p_event->get_device(),
					Math::abs(joypad_motion->get_axis_value()), p_time_usec);
		} else if (Ref<InputEventScreenTouch>(p_event).is_valid() ||
				Ref<InputEventScreenDrag>(p_event).is_valid()) {
			changed = modality.observe_touch(p_time_usec);
		}
	}

	if (!changed) {
		return;
	}
	active_device_name = modality.get_modality() == cu::Modality::GAMEPAD
			? Input::get_singleton()->get_joy_name(modality.get_active_device())
			: String();
	emit_signal("input_modality_changed", static_cast<int>(modality.get_modality()),
			modality.get_active_device());
}

// ---------------------------------------------------------------------------
// Physical-state reconciliation (Bug: no physical-state resync; stranded
// repeating triggers)
//
// Focus loss is handled unconditionally by _notification(); this covers the
// other half of the bug -- a GUI Control eating the corresponding release
// event before framework routing ever sees it. The physical release still
// reaches Godot's Input singleton (it tracks raw physical state from
// Input::parse_input_event(), independently of whether any node's GUI/
// unhandled-input dispatch "handles" the matching InputEvent), so polling it
// here catches what routing missed.
// ---------------------------------------------------------------------------

namespace {
// A trigger must be observed as physically released for this many
// consecutive reconciliation passes before it is cancelled. This is a
// deliberate policy choice beyond the literal "not the same frame as the
// press" requirement: a couple of this addon's own integration-test helpers
// push synthetic events directly into a Viewport (or straight through
// route_viewport_input()) without going through Input::parse_input_event(),
// so the Input singleton never learns those presses happened at all: without
// a multi-frame margin, the very first reconciliation pass after such a press
// would see "no physical binding held" and cancel it before its own
// (equally synthetic) release two frames later ever arrives. Three frames is
// far below the threshold of user-perceptible latency for the genuine
// stranded-trigger case this feature targets, while comfortably clearing that
// gap.
constexpr int RECONCILE_GRACE_FRAMES = 3;

std::uint64_t reconcile_key(const cu::ScopeKey &p_scope, cu::Id p_action) {
	// Same mixing shape as cu::ScopeKeyHash, extended with the action id.
	std::uint64_t mixed = p_scope.viewport * 0x9E3779B97F4A7C15ULL;
	mixed ^= static_cast<std::uint64_t>(p_scope.user) + 0x165667B19E3779F9ULL + (mixed << 6) + (mixed >> 2);
	mixed ^= static_cast<std::uint64_t>(p_action) + 0x9E3779B97F4A7C15ULL + (mixed << 6) + (mixed >> 2);
	return mixed;
}

} // namespace

void CommonUIRuntime::query_physical_state(const cu::TriggerState &p_trigger, bool &r_checked_any,
		bool &r_still_down) const {
	r_checked_any = false;
	r_still_down = false;
	if (binding_registry.is_null()) {
		return;
	}

	const StringName action_name = name_of(p_trigger.action);
	const DeviceKind kind = device_kind_of(p_trigger.device);
	const int device_index = device_index_of(p_trigger.device);
	Input *input = Input::get_singleton();

	const CommonInputBindingRegistry::Slot slots[2] = {
		CommonInputBindingRegistry::SLOT_PRIMARY,
		CommonInputBindingRegistry::SLOT_SECONDARY,
	};
	for (CommonInputBindingRegistry::Slot slot : slots) {
		const Ref<CommonUIBinding> binding = binding_registry->get_effective_binding(action_name, slot);
		if (binding.is_null()) {
			continue;
		}
		switch (binding->get_device_kind()) {
			case CommonUIBinding::DEVICE_KEYBOARD:
				if (kind != DEVICE_KIND_KEYBOARD_MOUSE) {
					continue;
				}
				r_checked_any = true;
				r_still_down = r_still_down ||
						input->is_physical_key_pressed(static_cast<Key>(binding->get_code()));
				break;
			case CommonUIBinding::DEVICE_MOUSE:
				if (kind != DEVICE_KIND_KEYBOARD_MOUSE) {
					continue;
				}
				r_checked_any = true;
				r_still_down = r_still_down ||
						input->is_mouse_button_pressed(static_cast<MouseButton>(binding->get_code()));
				break;
			case CommonUIBinding::DEVICE_GAMEPAD_BUTTON:
				if (kind != DEVICE_KIND_JOYPAD || device_index < 0) {
					continue;
				}
				r_checked_any = true;
				r_still_down = r_still_down ||
						input->is_joy_button_pressed(device_index, static_cast<JoyButton>(binding->get_code()));
				break;
			case CommonUIBinding::DEVICE_GAMEPAD_AXIS:
			case CommonUIBinding::DEVICE_TOUCH:
			default:
				// An axis hold has no reliable discrete "still down" boolean, and
				// there is no cheap way to poll whether a specific touch index is
				// still down; skip rather than false-cancel either.
				break;
		}
	}
}

void CommonUIRuntime::reconcile_physical_state(cu::TimeUsec p_time_usec) {
	// A trigger captured at or after this cutoff has not had a fair chance to
	// be reflected by the platform's Input state yet -- guards against
	// false-cancelling a press during its own frame.
	const cu::TimeUsec cutoff = last_reconcile_usec;
	last_reconcile_usec = p_time_usec;

	if (!core.has_captured_triggers() || binding_registry.is_null()) {
		reconcile_miss_streak.clear();
		return;
	}

	std::unordered_map<std::uint64_t, int> next_streak;
	for (const cu::ScopeKey &scope : core.known_scopes()) {
		for (const cu::TriggerState &trigger : core.captured_triggers(scope)) {
			if (trigger.pressed_usec >= cutoff) {
				continue;
			}

			bool checked_any = false;
			bool still_down = false;
			query_physical_state(trigger, checked_any, still_down);
			if (!checked_any || still_down) {
				// Unverifiable (skip rather than false-cancel) or genuinely still
				// held: either way this trigger's miss streak resets by simply not
				// being carried into next_streak.
				continue;
			}

			const std::uint64_t key = reconcile_key(scope, trigger.action);
			auto previous = reconcile_miss_streak.find(key);
			const int streak = (previous == reconcile_miss_streak.end() ? 0 : previous->second) + 1;
			if (streak < RECONCILE_GRACE_FRAMES) {
				next_streak[key] = streak;
				continue;
			}
			core.cancel_action(scope, trigger.action, p_time_usec);
		}
	}
	reconcile_miss_streak = std::move(next_streak);
}

// ---------------------------------------------------------------------------
// Handle support
// ---------------------------------------------------------------------------

bool CommonUIRuntime::release_handle(uint64_t p_handle_id) {
	if (!core.is_handle_known(p_handle_id)) {
		return false;
	}
	return core.release_handle(p_handle_id);
}

bool CommonUIRuntime::set_context_suspended(uint64_t p_handle_id, bool p_suspended) {
	return core.set_context_suspended(p_handle_id, p_suspended);
}

bool CommonUIRuntime::is_handle_active(uint64_t p_handle_id) const {
	if (!core.is_handle_known(p_handle_id)) {
		return false;
	}
	// prune_dead_owners() is amortized across frames, so a freed owner's
	// registration can linger in the core between passes; is_active() must not
	// report it as live in that window.
	const cu::OwnerId owner = core.owner_of_handle(p_handle_id);
	return owner == cu::INVALID_OWNER || invoker.is_owner_valid(owner);
}

// ---------------------------------------------------------------------------
// Node lifecycle and input
// ---------------------------------------------------------------------------

void CommonUIRuntime::_ready() {
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	if (singleton != nullptr && singleton != this) {
		// A second CommonUIRuntime node entered the tree (typically a project
		// mistake -- the addon is meant to be installed as a single autoload).
		// Leave the existing singleton alone rather than silently stealing it:
		// every consumer already holding a reference to the first instance
		// (get_singleton(), the /root/CommonUI autoload path, or a
		// CommonUIActionHandle/CommonUIContextHandle it issued) must keep
		// working exactly as before. This instance simply never processes
		// input or claims the singleton slot.
		UtilityFunctions::push_warning(
				"CommonUIRuntime: another instance is already the singleton; this instance will not "
				"process input. CommonUIRuntime is meant to be installed as a single autoload.");
		return;
	}
	singleton = this;
	default_viewport_id = get_viewport() != nullptr ? get_viewport()->get_instance_id() : 0;

	if (binding_registry.is_null()) {
		binding_registry.instantiate();
	}
	Input::get_singleton()->connect("joy_connection_changed",
			Callable(this, "_on_joy_connection_changed"));

	// UI must keep responding while the game itself is paused.
	set_process_mode(Node::PROCESS_MODE_ALWAYS);
	set_process(true);
	set_process_input(true);
	set_process_shortcut_input(true);
	set_process_unhandled_input(true);
}

void CommonUIRuntime::_exit_tree() {
	if (singleton == this) {
		singleton = nullptr;
	}
}

void CommonUIRuntime::_notification(int p_what) {
	if (p_what != NOTIFICATION_APPLICATION_FOCUS_OUT && p_what != NOTIFICATION_WM_WINDOW_FOCUS_OUT) {
		return;
	}
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	// Nothing guarantees a held action's release ever arrives once focus is
	// lost (alt-tab is the common case): the platform may never deliver the
	// key-up at all until focus returns, which would otherwise leave
	// Core::tick() firing HOLD_REPEAT forever. Cancelling unconditionally is
	// deliberately more aggressive than the per-tick physical reconciliation
	// below -- that one trusts the Input singleton's tracked state, which a
	// lost-focus key-up may never update either.
	core.cancel_all(Time::get_singleton()->get_ticks_usec());
}

namespace {
// prune_dead_owners() walks every scope's full registration list and does an
// ObjectDB lookup per entry -- O(scopes x registrations) every time it runs.
// Every _process() frame is far more often than a dead owner actually needs
// to be noticed: routing itself already treats a dead owner's registration as
// ineligible (HandlerInvoker::is_owner_valid()), and revalidate_triggers()
// already self-heals any captured trigger whose owner died. Amortizing the
// sweep over a handful of frames trades a small, harmless bookkeeping delay
// for a much cheaper steady-state _process().
constexpr int PRUNE_INTERVAL_FRAMES = 30;
} // namespace

void CommonUIRuntime::_process(double) {
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	// Removes registrations whose scene owners left the tree even when no
	// matching input arrives to trigger routing maintenance. See
	// PRUNE_INTERVAL_FRAMES above for why this does not run every frame.
	if (++prune_frame_counter >= PRUNE_INTERVAL_FRAMES) {
		prune_frame_counter = 0;
		core.prune_dead_owners();
	}
	// Drives hold/repeat.
	const cu::TimeUsec now = Time::get_singleton()->get_ticks_usec();
	core.tick(now);
	reconcile_physical_state(now);
}

void CommonUIRuntime::_input(const Ref<InputEvent> &p_event) {
	if (p_event.is_null() || Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	// Device and modality observation only. This stage deliberately never marks
	// an event handled, so a focused control keeps its normal opportunity to
	// process text entry and built-in navigation. Whether the event is consumed
	// is decided later, solely by the action router's route result.
	observe_device(p_event, Time::get_singleton()->get_ticks_usec());
}

// Godot delivers only InputEventKey and InputEventJoypadButton to
// _shortcut_input. Mouse buttons, joypad axes, and touch reach the tree only at
// the _unhandled_input stage, so framework routing has to run in both -- an
// axis- or mouse-bound action would otherwise never route at all. Both stages
// are post-GUI, so a focused Control still gets its opportunity first.

void CommonUIRuntime::_shortcut_input(const Ref<InputEvent> &p_event) {
	if (p_event.is_null() || Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	route_event(p_event, get_viewport(), false);
}

void CommonUIRuntime::_unhandled_input(const Ref<InputEvent> &p_event) {
	if (p_event.is_null() || Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	route_event(p_event, get_viewport(), true);
}

// --- Per-Viewport routing entrypoints, called by CommonUIViewportRouter ------

void CommonUIRuntime::observe_viewport_input(const Ref<InputEvent> &p_event) {
	if (p_event.is_null() || Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	observe_device(p_event, Time::get_singleton()->get_ticks_usec());
}

void CommonUIRuntime::route_viewport_input(const Ref<InputEvent> &p_event, Object *p_viewport,
		bool p_unhandled_stage) {
	if (p_event.is_null() || Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	route_event(p_event, Object::cast_to<Viewport>(p_viewport), p_unhandled_stage);
}

void CommonUIRuntime::register_viewport_router(Object *p_viewport) {
	if (p_viewport != nullptr) {
		router_viewports.insert(p_viewport->get_instance_id());
	}
}

void CommonUIRuntime::unregister_viewport_router(Object *p_viewport) {
	if (p_viewport == nullptr) {
		return;
	}
	const uint64_t viewport_id = p_viewport->get_instance_id();
	router_viewports.erase(viewport_id);
	if (viewport_id == default_viewport_id) {
		// A CommonUIViewportRouter placed directly in the default (root)
		// Viewport is a project mistake -- the autoload already routes that
		// Viewport itself -- but erasing its scopes here would wipe out every
		// default-scope registration and context for every UI user. Leave
		// default-scope state alone; only a genuine SubViewport's own scopes
		// are ever torn down.
		return;
	}
	// The Viewport no longer routes: every scope Core holds for it (one per UI
	// user that ever registered something there) would otherwise sit stranded
	// forever, along with the handles pointing at it -- Core::scopes has no
	// other eviction path. Cancels any trigger still captured there and drops
	// the registration/context handle bookkeeping; deferred internally if a
	// dispatch happens to be in flight.
	core.erase_scopes_for_viewport(viewport_id, Time::get_singleton()->get_ticks_usec());
}

void CommonUIRuntime::route_event(const Ref<InputEvent> &p_event, Viewport *p_viewport,
		bool p_unhandled_stage) {
	if (p_viewport == nullptr) {
		return;
	}
	// Mouse motion can never satisfy a binding: every CommonUIBinding device
	// kind is a discrete key/button/axis event, never continuous pointer
	// motion. Reject it before the per-action InputMap loop below runs and
	// finds nothing, since this stage otherwise sees one of these per mouse
	// movement. Modality tracking for mouse motion happens separately in
	// observe_device(), called from _input()/observe_viewport_input(), and is
	// unaffected by this early-out.
	if (Ref<InputEventMouseMotion>(p_event).is_valid()) {
		return;
	}
	// Keys and joypad buttons are routed in the shortcut stage. In the unhandled
	// stage they have already had their chance, so routing them again would
	// dispatch the same press twice. Every other event class reaches the tree
	// only at the unhandled stage, so it must route here.
	if (p_unhandled_stage &&
			(Ref<InputEventKey>(p_event).is_valid() || Ref<InputEventJoypadButton>(p_event).is_valid())) {
		return;
	}

	if (routed_actions_dirty) {
		refresh_routed_actions();
	}
	if (routed_actions.empty()) {
		return;
	}

	InputMap *input_map = InputMap::get_singleton();
	const cu::TimeUsec now = Time::get_singleton()->get_ticks_usec();
	// Raw platform device, used only for the (per-physical-device) user
	// assignment lookup below -- that feature is keyed by the same raw index
	// GDScript passes to assign_device_to_user() and is intentionally left
	// un-namespaced. Everything handed to the core uses `composed_device`
	// instead, so a keyboard/mouse event and the first gamepad -- both raw
	// device 0 -- are never confused with each other there.
	const int device = p_event->get_device();
	// One device event reaches exactly one UI user unless a shared-device policy
	// is explicitly enabled.
	if (!device_assignment.routes_anywhere(device)) {
		return;
	}
	const cu::ScopeKey scope = scope_for(static_cast<int>(device_assignment.user_for(device)), p_viewport);
	const cu::DeviceId composed_device = composed_device_of(p_event);


	// Cheap rejection first: most events (mouse motion, unbound keys) match no
	// framework action at all.
	std::vector<cu::Id> pressed;
	std::vector<cu::Id> released;
	for (std::size_t i = 0; i < routed_actions.size(); ++i) {
		const StringName &name = routed_action_names[i];
		if (!input_map->has_action(name)) {
			continue;
		}
		// Exact matching so Shift+Tab cannot satisfy a plain Tab binding. Echo
		// is rejected here and again by the core's live-trigger check.
		if (p_event->is_action_pressed(name, false, true)) {
			pressed.push_back(routed_actions[i]);
		} else if (p_event->is_action_released(name, false)) {
			// Releases match loosely on purpose. A stick returning to centre has
			// no direction, and a modifier can be lifted before its key, so exact
			// matching would silently drop the release and leave the captured
			// trigger pressed and repeating forever. Only the action holding a
			// live trigger responds, so a loose match cannot release anything
			// that was never pressed.
			released.push_back(routed_actions[i]);
		}
	}
	// Stick drift must never START an action, but a stick returning to centre is
	// a genuine release: dropping it would leave the captured trigger pressed
	// and repeating forever.
	const Ref<InputEventJoypadMotion> joypad_motion = p_event;
	if (joypad_motion.is_valid() &&
			modality.is_within_dead_zone(Math::abs(joypad_motion->get_axis_value()))) {
		pressed.clear();
	}
	if (pressed.empty() && released.empty()) {
		return;
	}

	bool consumed = false;

	// One physical event resolves to at most one consuming action. Several
	// effective bindings can match the same event -- two actions in different
	// conflict contexts are allowed to share one -- so the candidates are
	// evaluated in routing precedence order and the first consuming action wins.
	// active_actions() is already ordered by that precedence and only contains
	// actions with an eligible handler, so an action nobody can handle is never
	// dispatched.
	if (!pressed.empty()) {
		std::vector<cu::Id> dispatched;
		for (const cu::ActiveAction &candidate : core.active_actions(scope)) {
			if (std::find(pressed.begin(), pressed.end(), candidate.action) == pressed.end()) {
				continue;
			}
			if (std::find(dispatched.begin(), dispatched.end(), candidate.action) != dispatched.end()) {
				continue;
			}
			dispatched.push_back(candidate.action);

			const StringName name = name_of(candidate.action);
			const cu::RouteReport report = core.press(scope, candidate.action, composed_device, now,
					policy_for(name));
			emit_signal("action_routed", name, report.consumed, static_cast<int>(scope.user));
			if (report.consumed) {
				consumed = true;
				break;
			}
		}
	}

	// Releases target whichever action captured the press; actions without a
	// live trigger simply report false.
	for (cu::Id action : released) {
		if (core.release(scope, action, composed_device, now)) {
			consumed = true;
		}
	}

	if (consumed) {
		// Consume on the Viewport the event belongs to, not necessarily the root:
		// a router routes for its own SubViewport.
		p_viewport->set_input_as_handled();
	}
}

// ---------------------------------------------------------------------------
// Bindings
// ---------------------------------------------------------------------------

void CommonUIRuntime::_bind_methods() {
	ClassDB::bind_static_method("CommonUIRuntime", D_METHOD("get_api_version"),
			&CommonUIRuntime::get_api_version);

	ClassDB::bind_method(D_METHOD("register_action", "action", "callback", "options"),
			&CommonUIRuntime::register_action, DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("push_context", "context", "priority", "ui_user", "viewport"),
			&CommonUIRuntime::push_context, DEFVAL(0), DEFVAL(0), DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("configure_layer", "layer", "priority", "active", "ui_user", "viewport"),
			&CommonUIRuntime::configure_layer, DEFVAL(true), DEFVAL(0), DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("set_layer_active", "layer", "active", "ui_user", "viewport"),
			&CommonUIRuntime::set_layer_active, DEFVAL(0), DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("push_screen", "layer", "screen", "ui_user", "viewport"),
			&CommonUIRuntime::push_screen, DEFVAL(0), DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("remove_screen", "layer", "screen", "ui_user", "viewport"),
			&CommonUIRuntime::remove_screen, DEFVAL(0), DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("get_top_screen", "layer", "ui_user", "viewport"),
			&CommonUIRuntime::get_top_screen, DEFVAL(0), DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("get_active_actions", "ui_user", "viewport"),
			&CommonUIRuntime::get_active_actions, DEFVAL(0), DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("get_active_contexts", "ui_user", "viewport"),
			&CommonUIRuntime::get_active_contexts, DEFVAL(0), DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("get_captured_triggers", "ui_user", "viewport"),
			&CommonUIRuntime::get_captured_triggers, DEFVAL(0), DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("get_last_route_report"), &CommonUIRuntime::get_last_route_report);
	ClassDB::bind_method(D_METHOD("has_active_trigger", "action", "ui_user", "viewport"),
			&CommonUIRuntime::has_active_trigger, DEFVAL(0), DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("cancel_action", "action", "ui_user", "viewport"),
			&CommonUIRuntime::cancel_action, DEFVAL(0), DEFVAL(Variant()));
	ClassDB::bind_method(D_METHOD("set_input_config", "config"), &CommonUIRuntime::set_input_config);
	ClassDB::bind_method(D_METHOD("get_input_config"), &CommonUIRuntime::get_input_config);
	ClassDB::bind_method(D_METHOD("get_binding_registry"), &CommonUIRuntime::get_binding_registry);

	ClassDB::bind_method(D_METHOD("get_input_modality"), &CommonUIRuntime::get_input_modality);
	ClassDB::bind_method(D_METHOD("get_active_device"), &CommonUIRuntime::get_active_device);
	ClassDB::bind_method(D_METHOD("get_active_device_name"), &CommonUIRuntime::get_active_device_name);
	ClassDB::bind_method(D_METHOD("resolve_glyph", "action", "slot"), &CommonUIRuntime::resolve_glyph,
			DEFVAL(0));
	ClassDB::bind_method(D_METHOD("assign_device_to_user", "device", "ui_user"),
			&CommonUIRuntime::assign_device_to_user);
	ClassDB::bind_method(D_METHOD("unassign_device", "device"), &CommonUIRuntime::unassign_device);
	ClassDB::bind_method(D_METHOD("get_user_for_device", "device"), &CommonUIRuntime::get_user_for_device);
	ClassDB::bind_method(D_METHOD("_on_joy_connection_changed", "device", "connected"),
			&CommonUIRuntime::on_joy_connection_changed);

	ClassDB::bind_method(D_METHOD("observe_viewport_input", "event"),
			&CommonUIRuntime::observe_viewport_input);
	ClassDB::bind_method(D_METHOD("route_viewport_input", "event", "viewport", "unhandled_stage"),
			&CommonUIRuntime::route_viewport_input);
	ClassDB::bind_method(D_METHOD("register_viewport_router", "viewport"),
			&CommonUIRuntime::register_viewport_router);
	ClassDB::bind_method(D_METHOD("unregister_viewport_router", "viewport"),
			&CommonUIRuntime::unregister_viewport_router);

	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "input_config", PROPERTY_HINT_RESOURCE_TYPE,
						 "CommonUIInputConfig"),
			"set_input_config", "get_input_config");

	ADD_SIGNAL(MethodInfo("active_actions_changed", PropertyInfo(Variant::INT, "ui_user")));
	ADD_SIGNAL(MethodInfo("context_changed", PropertyInfo(Variant::INT, "ui_user")));
	ADD_SIGNAL(MethodInfo("trigger_canceled", PropertyInfo(Variant::STRING_NAME, "action"),
			PropertyInfo(Variant::INT, "ui_user")));
	ADD_SIGNAL(MethodInfo("action_routed", PropertyInfo(Variant::STRING_NAME, "action"),
			PropertyInfo(Variant::BOOL, "consumed"), PropertyInfo(Variant::INT, "ui_user")));
	ADD_SIGNAL(MethodInfo("input_modality_changed", PropertyInfo(Variant::INT, "modality"),
			PropertyInfo(Variant::INT, "device")));

	BIND_ENUM_CONSTANT(ROUTE_UNHANDLED);
	BIND_ENUM_CONSTANT(ROUTE_HANDLED);
	BIND_ENUM_CONSTANT(ROUTE_HANDLED_CONTINUE);

	BIND_ENUM_CONSTANT(PHASE_PRESSED);
	BIND_ENUM_CONSTANT(PHASE_RELEASED);
	BIND_ENUM_CONSTANT(PHASE_HOLD_STARTED);
	BIND_ENUM_CONSTANT(PHASE_HOLD_REPEAT);
	BIND_ENUM_CONSTANT(PHASE_CANCELED);

	BIND_ENUM_CONSTANT(MODALITY_UNKNOWN);
	BIND_ENUM_CONSTANT(MODALITY_KEYBOARD_MOUSE);
	BIND_ENUM_CONSTANT(MODALITY_GAMEPAD);
	BIND_ENUM_CONSTANT(MODALITY_TOUCH);

	BIND_ENUM_CONSTANT(REASON_NONE);
	BIND_ENUM_CONSTANT(REASON_RELEASED);
	BIND_ENUM_CONSTANT(REASON_OWNER_INVALID);
	BIND_ENUM_CONSTANT(REASON_CONTEXT_INACTIVE);
	BIND_ENUM_CONSTANT(REASON_CONTEXT_SUSPENDED);
	BIND_ENUM_CONSTANT(REASON_LAYER_INACTIVE);
	BIND_ENUM_CONSTANT(REASON_SCREEN_INACTIVE);
	BIND_ENUM_CONSTANT(REASON_SCREEN_NOT_TOP);
	BIND_ENUM_CONSTANT(REASON_ROUTING_STOPPED);
}

} // namespace godot
