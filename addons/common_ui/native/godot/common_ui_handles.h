#ifndef COMMON_UI_HANDLES_H
#define COMMON_UI_HANDLES_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/object_id.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

class CommonUIRuntime;

// Handle returned by CommonUIRuntime.register_action().
//
// Dropping the reference does NOT unregister: the registration's lifetime is
// governed by its owner object. Call release() to remove it earlier.
class CommonUIActionHandle : public RefCounted {
	GDCLASS(CommonUIActionHandle, RefCounted)

public:
	// Removes the registration. Safe to call more than once and safe after the
	// runtime itself has been freed.
	bool release();

	// False once released, or once the runtime no longer knows the handle.
	bool is_active() const;

	StringName get_action() const { return action; }
	int get_ui_user() const { return ui_user; }
	uint64_t get_handle_id() const { return handle_id; }

protected:
	static void _bind_methods();

private:
	friend class CommonUIRuntime;

	uint64_t runtime_id = 0;
	uint64_t handle_id = 0;
	StringName action;
	int ui_user = 0;
	bool released = false;
};

// Handle returned by CommonUIRuntime.push_context().
class CommonUIContextHandle : public RefCounted {
	GDCLASS(CommonUIContextHandle, RefCounted)

public:
	bool release();
	bool is_active() const;

	// Makes the context's handlers ineligible without losing its stack position.
	bool set_suspended(bool p_suspended);
	bool is_suspended() const { return suspended; }

	StringName get_context() const { return context; }
	int get_ui_user() const { return ui_user; }
	uint64_t get_handle_id() const { return handle_id; }

protected:
	static void _bind_methods();

private:
	friend class CommonUIRuntime;

	uint64_t runtime_id = 0;
	uint64_t handle_id = 0;
	StringName context;
	int ui_user = 0;
	bool suspended = false;
	bool released = false;
};

} // namespace godot

#endif // COMMON_UI_HANDLES_H
