class_name RuntimeRaidAuthority
extends RaidAuthority
## Same canonical authority, with a runtime fast path for the installed native
## definition Resources. Only native property SCHEMAS are cached, never values,
## bearer-scan results, callback owners, or generation/liveness decisions.
## Scripted/unknown objects keep the original complete reflection path. Native
## metadata is always read afresh, including metadata added after registration.
## The fixed shipped definition classes use ClassDB-registered property sets.
## Extension hot-reload inside an active raid is outside the sealed toolchain.
const NATIVE_DEFINITIONS: PackedStringArray = [
	"GameplayDefinitionCatalog", "GameplayTagDefinition", "GameplayAttributeDefinition",
	"GameplayEffectDefinition", "GameplayAbilityDefinition", "GameplayModifierDeclaration",
	"GameplayCueDefinition",
]
var _capture_schemas: Dictionary = {}

func phase_handler_callback_is_safe(callback: Callable) -> bool:
	return callback.is_valid() and not _capture_contains_bearer(callback, 0, {get_instance_id():true})

func _capture_contains_bearer(value: Variant, depth: int, visited: Dictionary) -> bool:
	if depth > 16: return true
	if value is BodyHitboxWorld2D.BindingCapability: return true
	match typeof(value):
		TYPE_CALLABLE:
			var callback := value as Callable
			if _capture_contains_bearer(callback.get_object(), depth + 1, visited): return true
			for argument in callback.get_bound_arguments():
				if _capture_contains_bearer(argument, depth + 1, visited): return true
		TYPE_OBJECT:
			var object := value as Object
			if object == null or not is_instance_valid(object): return false
			var id := object.get_instance_id()
			if visited.has(id): return false
			visited[id] = true
			var native: String = object.get_class()
			var schema: Dictionary = {}
			if object.get_script() == null and NATIVE_DEFINITIONS.has(native):
				schema = _definition_schema(object, native)
			if not schema.is_empty():
				# The reference traversal also rejects a primitive child at depth 17.
				if depth == 16 and schema.has_properties: return true
				for name: StringName in schema.references:
					if _capture_contains_bearer(object.get(name), depth + 1, visited): return true
				# Metadata is not part of ClassDB's immutable registered schema.
				for name: StringName in object.get_meta_list():
					if _capture_contains_bearer(object.get_meta(name), depth + 1, visited): return true
			else:
				for property_value in object.get_property_list():
					var name := StringName((property_value as Dictionary).get("name", &""))
					if not name.is_empty() and _capture_contains_bearer(object.get(name), depth + 1, visited): return true
			if object is PhaseHandlerRelay:
				for connection: Dictionary in object.get_signal_connection_list(&"invoked"):
					if _capture_contains_bearer(connection.get("callable", Callable()), depth + 1, visited): return true
		TYPE_DICTIONARY:
			for key in value.keys():
				if _capture_contains_bearer(key, depth + 1, visited) or _capture_contains_bearer(value[key], depth + 1, visited): return true
		TYPE_ARRAY:
			for child in value as Array:
				if _capture_contains_bearer(child, depth + 1, visited): return true
	return false

func _definition_schema(object: Object, native: String) -> Dictionary:
	if _capture_schemas.has(native): return _capture_schemas[native]
	var registered: Dictionary = {}
	for property: Dictionary in ClassDB.class_get_property_list(StringName(native)):
		registered[StringName(property.name)] = int(property.type)
	var references: Array[StringName] = []
	var has_properties: bool = false
	# Validate the native contract against a real instance before using it.
	# Unknown/dynamic native properties fail back to complete reflection.
	for property: Dictionary in object.get_property_list():
		var name := StringName(property.get("name", &""))
		if name.is_empty(): continue
		has_properties = true
		if name == &"script" or String(name).begins_with("metadata/"): continue
		var usage: int = int(property.get("usage", 0))
		if (usage & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP)) != 0:
			continue # Display grouping, not a stored property or reference.
		if not registered.has(name) or registered[name] != int(property.type):
			_capture_schemas[native] = {}
			return {}
		match int(property.type):
			TYPE_NIL, TYPE_OBJECT, TYPE_CALLABLE, TYPE_DICTIONARY, TYPE_ARRAY:
				references.append(name)
	var schema := {"references":references, "has_properties":has_properties}
	_capture_schemas[native] = schema
	return schema
