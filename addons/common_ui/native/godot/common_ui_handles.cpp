#include "godot/common_ui_handles.h"

#include "godot/common_ui_runtime.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>

namespace godot {

namespace {

// Resolves the runtime that issued a handle, or null once it has been freed.
// Handles outlive the runtime in teardown, so this must never dereference a
// stale pointer.
CommonUIRuntime *resolve_runtime(uint64_t p_runtime_id) {
	if (p_runtime_id == 0) {
		return nullptr;
	}
	return Object::cast_to<CommonUIRuntime>(ObjectDB::get_instance(p_runtime_id));
}

} // namespace

bool CommonUIActionHandle::release() {
	if (released) {
		return false;
	}
	released = true;
	CommonUIRuntime *runtime = resolve_runtime(runtime_id);
	return runtime != nullptr && runtime->release_handle(handle_id);
}

bool CommonUIActionHandle::is_active() const {
	if (released || handle_id == 0) {
		return false;
	}
	CommonUIRuntime *runtime = resolve_runtime(runtime_id);
	return runtime != nullptr && runtime->is_handle_active(handle_id);
}

void CommonUIActionHandle::_bind_methods() {
	ClassDB::bind_method(D_METHOD("release"), &CommonUIActionHandle::release);
	ClassDB::bind_method(D_METHOD("is_active"), &CommonUIActionHandle::is_active);
	ClassDB::bind_method(D_METHOD("get_action"), &CommonUIActionHandle::get_action);
	ClassDB::bind_method(D_METHOD("get_ui_user"), &CommonUIActionHandle::get_ui_user);
	ClassDB::bind_method(D_METHOD("get_handle_id"), &CommonUIActionHandle::get_handle_id);
}

bool CommonUIContextHandle::release() {
	if (released) {
		return false;
	}
	released = true;
	CommonUIRuntime *runtime = resolve_runtime(runtime_id);
	return runtime != nullptr && runtime->release_handle(handle_id);
}

bool CommonUIContextHandle::is_active() const {
	if (released || handle_id == 0) {
		return false;
	}
	CommonUIRuntime *runtime = resolve_runtime(runtime_id);
	return runtime != nullptr && runtime->is_handle_active(handle_id);
}

bool CommonUIContextHandle::set_suspended(bool p_suspended) {
	if (released) {
		return false;
	}
	CommonUIRuntime *runtime = resolve_runtime(runtime_id);
	if (runtime == nullptr || !runtime->set_context_suspended(handle_id, p_suspended)) {
		return false;
	}
	suspended = p_suspended;
	return true;
}

void CommonUIContextHandle::_bind_methods() {
	ClassDB::bind_method(D_METHOD("release"), &CommonUIContextHandle::release);
	ClassDB::bind_method(D_METHOD("is_active"), &CommonUIContextHandle::is_active);
	ClassDB::bind_method(D_METHOD("set_suspended", "suspended"), &CommonUIContextHandle::set_suspended);
	ClassDB::bind_method(D_METHOD("is_suspended"), &CommonUIContextHandle::is_suspended);
	ClassDB::bind_method(D_METHOD("get_context"), &CommonUIContextHandle::get_context);
	ClassDB::bind_method(D_METHOD("get_ui_user"), &CommonUIContextHandle::get_ui_user);
	ClassDB::bind_method(D_METHOD("get_handle_id"), &CommonUIContextHandle::get_handle_id);
}

} // namespace godot
