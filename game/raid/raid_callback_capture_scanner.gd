class_name RaidCallbackCaptureScanner
extends RefCounted
## Cache only schemas of fixed native definition Resources.
## This is a scanner, NOT a RaidAuthority subtype: release attestations must
## originate from the exact RaidAuthority script that owns the lifecycle.
## Never cache callback safety, object values, metadata, or lifecycle decisions.
## Unknown/scripted objects retain the complete reference scan. The installed
## ClassDB property schema is verified before caching; hot-reload during a raid
## is outside the sealed toolchain. Differential contracts cover every class.
const NATIVE_DEFINITIONS: PackedStringArray = [
	"GameplayDefinitionCatalog", "GameplayTagDefinition", "GameplayAttributeDefinition",
	"GameplayEffectDefinition", "GameplayAbilityDefinition", "GameplayModifierDeclaration",
	"GameplayCueDefinition", "GameplayMagnitude", "GameplayStackingPolicy",
	"GameplayTagOperand", "GameplayTagQueryResource", "GameplayAbilityTrigger",
	"GameplaySetByCallerField", "GameplayTagReactionDefinition", "GameplayTargetDataSchema",
	"InventoryCatalogResource", "InventoryContainerConstraints", "InventoryContainerDefinition",
	"InventoryDiscoveryPolicy", "InventoryItemDefinition", "InventoryItemTraitValue",
	"InventoryNamedSlot", "InventoryProfileDefinition", "InventoryProfileLimits", "InventoryTraitSchema",
]
# Cached schemas are lexical and immutable at the publication boundary.
# Reflection can query the dispatcher, but cannot replace it or edit its cache.
var _schema_dispatch: Callable = Callable():
	set(value):
		if not _schema_dispatch.is_valid(): _schema_dispatch = value

func _init() -> void:
	var schemas: Dictionary = {}
	_schema_dispatch = func(object: Object, native: String) -> Dictionary:
		if object == null or not is_instance_valid(object) or object.get_script() != null \
			or object.get_class() != native or not NATIVE_DEFINITIONS.has(native): return {}
		if schemas.has(native): return schemas[native]
		var schema := _build_definition_schema(object, native)
		if schema.has("references"): schema.references.make_read_only()
		schema.make_read_only()
		schemas[native] = schema
		return schema

# Scalar Variants cannot contain a bearer. Avoid a GDScript recursive call for
# each number/string in snapshots and definitions. This is type dispatch only;
# current object properties, metadata, keys and references are still read at
# every invocation. The depth rule also applies to scalars at depth 17.
const REFERENCE_TYPES: int = (1 << TYPE_OBJECT) | (1 << TYPE_CALLABLE) | (1 << TYPE_DICTIONARY) | (1 << TYPE_ARRAY)

func is_safe(callback: Callable, authority_instance_id: int) -> bool:
	return callback.is_valid() and not _capture_contains_bearer(callback, 0, {authority_instance_id:true})

func _capture_contains_bearer(value: Variant, depth: int, visited: Dictionary) -> bool:
	if depth > 16: return true
	match typeof(value):
		TYPE_CALLABLE:
			# The reference scanner visits even a null callable owner at depth+1.
			if depth == 16: return true
			var callback := value as Callable
			if _capture_contains_bearer(callback.get_object(), depth + 1, visited): return true
			for argument in callback.get_bound_arguments():
				if (REFERENCE_TYPES & (1 << typeof(argument))) != 0 \
					and _capture_contains_bearer(argument, depth + 1, visited): return true
		TYPE_OBJECT:
			var object := value as Object
			if object == null or not is_instance_valid(object): return false
			if object is BodyHitboxWorld2D.BindingCapability: return true
			var id := object.get_instance_id()
			if visited.has(id): return false
			visited[id] = true
			var native: String = object.get_class()
			var schema: Dictionary = {}
			if object.get_script() == null and NATIVE_DEFINITIONS.has(native):
				schema = _definition_schema(object, native)
			if not schema.is_empty():
				if depth == 16 and schema.has_properties: return true
				for name: StringName in schema.references:
					var child: Variant = object.get(name)
					if (REFERENCE_TYPES & (1 << typeof(child))) != 0 \
						and _capture_contains_bearer(child, depth + 1, visited): return true
				for name: StringName in object.get_meta_list():
					if depth == 16: return true
					var child: Variant = object.get_meta(name)
					if (REFERENCE_TYPES & (1 << typeof(child))) != 0 \
						and _capture_contains_bearer(child, depth + 1, visited): return true
			else:
				for property_value in object.get_property_list():
					var name := StringName((property_value as Dictionary).get("name", &""))
					if name.is_empty(): continue
					# Read the value even at the boundary: do not change getter calls.
					var child: Variant = object.get(name)
					if depth == 16: return true
					if (REFERENCE_TYPES & (1 << typeof(child))) != 0 \
						and _capture_contains_bearer(child, depth + 1, visited): return true
			if object is RaidAuthority.PhaseHandlerRelay:
				for connection: Dictionary in object.get_signal_connection_list(&"invoked"):
					if _capture_contains_bearer(connection.get("callable", Callable()), depth + 1, visited): return true
		TYPE_DICTIONARY:
			# Nonempty collections at the boundary fail even with scalar children.
			if depth == 16: return not value.is_empty()
			for key in value.keys():
				if (REFERENCE_TYPES & (1 << typeof(key))) != 0 \
					and _capture_contains_bearer(key, depth + 1, visited): return true
				var child: Variant = value[key]
				if (REFERENCE_TYPES & (1 << typeof(child))) != 0 \
					and _capture_contains_bearer(child, depth + 1, visited): return true
		TYPE_ARRAY:
			if depth == 16: return not value.is_empty()
			for child in value as Array:
				if (REFERENCE_TYPES & (1 << typeof(child))) != 0 \
					and _capture_contains_bearer(child, depth + 1, visited): return true
	return false

func _definition_schema(object: Object, native: String) -> Dictionary:
	return _schema_dispatch.call(object, native)

static func _build_definition_schema(object: Object, native: String) -> Dictionary:
	var registered: Dictionary = {}
	for property: Dictionary in ClassDB.class_get_property_list(StringName(native)):
		registered[StringName(property.name)] = int(property.type)
	var references: Array[StringName] = []
	var has_properties: bool = false
	for property: Dictionary in object.get_property_list():
		var name := StringName(property.get("name", &""))
		if name.is_empty(): continue
		has_properties = true
		if name == &"script" or String(name).begins_with("metadata/"): continue
		var usage: int = int(property.get("usage", 0))
		if (usage & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP)) != 0: continue
		if not registered.has(name) or registered[name] != int(property.type):
			return {}
		match int(property.type):
			TYPE_NIL, TYPE_OBJECT, TYPE_CALLABLE, TYPE_DICTIONARY, TYPE_ARRAY:
				references.append(name)
	var schema := {"references":references, "has_properties":has_properties}
	return schema
