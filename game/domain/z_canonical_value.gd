class_name ZCanonicalValue
extends RefCounted
## Bounded deterministic Variant validation, encoding, and SHA-256 hashing.

const DEFAULT_MAX_DEPTH: int = 6
const DEFAULT_MAX_NODES: int = 256
const DEFAULT_MAX_COLLECTION: int = 64
const DEFAULT_MAX_STRING_BYTES: int = 256


static func is_bounded(value: Variant) -> bool:
	var budget: Array[int] = [DEFAULT_MAX_NODES]
	return _validate(value, 0, budget)


static func encode(value: Variant) -> String:
	if not is_bounded(value):
		return ""
	return _encode_valid(value)


static func sha256(value: Variant) -> String:
	var encoded := encode(value)
	if encoded.is_empty():
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(encoded.to_utf8_buffer()) != OK:
		return ""
	return context.finish().hex_encode()


static func _validate(value: Variant, depth: int, budget: Array[int]) -> bool:
	if depth > DEFAULT_MAX_DEPTH or budget[0] <= 0:
		return false
	budget[0] -= 1
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_VECTOR2I:
			return true
		TYPE_STRING, TYPE_STRING_NAME:
			return String(value).to_utf8_buffer().size() <= DEFAULT_MAX_STRING_BYTES
		TYPE_PACKED_BYTE_ARRAY:
			return (value as PackedByteArray).size() <= DEFAULT_MAX_STRING_BYTES
		TYPE_PACKED_INT64_ARRAY:
			return (value as PackedInt64Array).size() <= DEFAULT_MAX_COLLECTION
		TYPE_ARRAY:
			var array := value as Array
			if array.size() > DEFAULT_MAX_COLLECTION:
				return false
			for child in array:
				if not _validate(child, depth + 1, budget):
					return false
			return true
		TYPE_DICTIONARY:
			var dictionary := value as Dictionary
			if dictionary.size() > DEFAULT_MAX_COLLECTION:
				return false
			var canonical_keys: Dictionary = {}
			for key in dictionary:
				if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME:
					return false
				var key_text := String(key)
				if key_text.to_utf8_buffer().size() > DEFAULT_MAX_STRING_BYTES:
					return false
				if canonical_keys.has(key_text):
					return false
				canonical_keys[key_text] = true
				if not _validate(dictionary[key], depth + 1, budget):
					return false
			return true
		_:
			return false


static func _encode_valid(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL:
			return "n"
		TYPE_BOOL:
			return "b1" if value else "b0"
		TYPE_INT:
			return "i" + str(value) + ";"
		TYPE_STRING, TYPE_STRING_NAME:
			var text := String(value)
			return "s%d:%s" % [text.to_utf8_buffer().size(), text]
		TYPE_VECTOR2I:
			var point := value as Vector2i
			return "v%d,%d;" % [point.x, point.y]
		TYPE_PACKED_BYTE_ARRAY:
			var bytes := value as PackedByteArray
			return "x%d:%s" % [bytes.size(), bytes.hex_encode()]
		TYPE_PACKED_INT64_ARRAY:
			var numbers := value as PackedInt64Array
			var encoded_numbers := PackedStringArray()
			for number in numbers:
				encoded_numbers.append(str(number))
			return "p%d:%s;" % [numbers.size(), ",".join(encoded_numbers)]
		TYPE_ARRAY:
			var array := value as Array
			var encoded_items := PackedStringArray()
			for child in array:
				encoded_items.append(_encode_valid(child))
			return "a%d:[%s]" % [array.size(), "".join(encoded_items)]
		TYPE_DICTIONARY:
			var dictionary := value as Dictionary
			var keys := PackedStringArray()
			var normalized: Dictionary = {}
			for key in dictionary:
				var key_text := String(key)
				keys.append(key_text)
				normalized[key_text] = dictionary[key]
			keys.sort()
			var encoded_pairs := PackedStringArray()
			for key in keys:
				encoded_pairs.append(_encode_valid(key) + _encode_valid(normalized[key]))
			return "d%d:{%s}" % [dictionary.size(), "".join(encoded_pairs)]
	return ""
