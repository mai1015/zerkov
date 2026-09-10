@tool
class_name CommonUIBoot
extends RefCounted

## Startup checks for the required CommonUI GDExtension.
##
## The addon declares its supported targets in
## `addons/common_ui/release_manifest.json`. A target without a validated native
## artifact is unsupported: this helper turns that into an explicit, readable
## failure rather than a partially working framework.

## Every native class the façade contract depends on.
const REQUIRED_CLASSES: PackedStringArray = [
	"CommonUIRuntime",
	"CommonUIActionHandle",
	"CommonUIContextHandle",
	"CommonUIAction",
	"CommonUIBinding",
	"CommonUIInputPolicy",
	"CommonUIDeviceProfile",
	"CommonUIInputConfig",
]

const MANIFEST_PATH := "res://addons/common_ui/release_manifest.json"


## True when every required native class was registered by the extension.
static func is_native_runtime_available() -> bool:
	for class_name_to_check in REQUIRED_CLASSES:
		if not ClassDB.class_exists(class_name_to_check):
			return false
	return true


## Names of the required native classes that are missing.
static func get_missing_classes() -> PackedStringArray:
	var missing := PackedStringArray()
	for class_name_to_check in REQUIRED_CLASSES:
		if not ClassDB.class_exists(class_name_to_check):
			missing.append(class_name_to_check)
	return missing


## The feature tags that identify the artifact Godot tried to load.
static func describe_current_target() -> String:
	var tags: Array[String] = []
	for tag in ["windows", "macos", "linux", "android", "ios", "web"]:
		if OS.has_feature(tag):
			tags.append(tag)
	for tag in ["x86_64", "arm64", "wasm32"]:
		if OS.has_feature(tag):
			tags.append(tag)
	tags.append("debug" if OS.is_debug_build() else "release")
	return "/".join(tags)


## A diagnostic that names the platform artifact rather than the symptom.
static func describe_missing_runtime() -> String:
	var lines := PackedStringArray()
	lines.append("CommonUI native runtime is not available for target '%s'." % describe_current_target())
	lines.append("Missing native classes: %s." % ", ".join(get_missing_classes()))
	lines.append(
		"Build or install the matching artifact declared in %s. The addon has no "
		% MANIFEST_PATH
		+ "GDScript fallback, so this target is unsupported until its artifact exists."
	)
	if OS.has_feature("web"):
		lines.append(
			"Web exports additionally require a template with Extension Support enabled "
			+ "and a host that serves the build with cross-origin isolation."
		)
	return "\n".join(lines)


## Aborts startup with a readable diagnostic when the runtime is unavailable.
## Returns true when the runtime is present.
static func assert_available(tree: SceneTree) -> bool:
	if is_native_runtime_available():
		return true
	push_error(describe_missing_runtime())
	printerr(describe_missing_runtime())
	if tree != null:
		tree.quit(1)
	return false
