class_name LtsDocumentFixtures
extends RefCounted

## Headless fixtures used by the document model when the native extension is
## unavailable.  This file intentionally contains no EditorInterface,
## EditorPlugin, Resource, or Control dependency.  The fixture is a bounded
## read-only projection, not a fake editable definition.

const NATIVE_DIAGNOSTIC_CODE := "LTS-NATIVE-001"
const NATIVE_DIAGNOSTIC_PATH := "native.level_task_system"


static func native_extension_unavailable(reason: String = "") -> Dictionary:
	var message := "Native extension unavailable"
	if not reason.strip_edges().is_empty():
		message += ": " + reason.strip_edges()
	return {
		"schema_version": 1,
		"native_extension_available": false,
		"read_only": true,
		"degraded": true,
		"diagnostic": {
			"code": NATIVE_DIAGNOSTIC_CODE,
			"path": NATIVE_DIAGNOSTIC_PATH,
			"severity": "error",
			"message": message,
			"recovery": "Build and load the level_task_system GDExtension before authoring definitions.",
		},
		"catalog": {
			"identifier": "",
			"source_path": "",
			"entries": [],
		},
		"documents": {
			"levels": {},
			"task_graphs": {},
			"conversations": {},
			"speakers": {},
			"providers": {},
		},
		"selection": {
			"resource_kind": "",
			"resource_identifier": "",
			"element_kind": "",
			"element_identifier": "",
			"field_path": "",
		},
		"navigator": {
			"query": "",
			"path": "",
			"resource_kind": "",
			"resource_identifier": "",
		},
		"layout": {
			"graphs": {},
			"conversations": {},
			"levels": {},
			"resources": {},
			"panes": {},
		},
		"revision": 0,
	}


static func native_extension_initializing() -> Dictionary:
	var fixture := native_extension_unavailable("Loading native extension...")
	fixture["diagnostic"]["code"] = "LTS-NATIVE-002"
	fixture["diagnostic"]["severity"] = "info"
	fixture["diagnostic"]["message"] = "Loading native extension..."
	return fixture


static func malformed_resource(path: String, message: String = "Resource projection failed") -> Dictionary:
	return {
		"schema_version": 1,
		"native_extension_available": true,
		"read_only": true,
		"degraded": true,
		"diagnostic": {
			"code": "LTS-DOCUMENT-001",
			"path": path,
			"severity": "error",
			"message": message,
			"recovery": "Inspect or reload the source resource before editing.",
		},
	}


static func is_degraded_state(state: Dictionary) -> bool:
	return bool(state.get("degraded", false)) or not bool(state.get("native_extension_available", true))
