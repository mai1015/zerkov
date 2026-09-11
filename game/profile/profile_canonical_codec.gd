class_name ProfileCanonicalCodec
extends RefCounted
## Strict deterministic codec for the bounded values accepted by ProfileStore.
##
## This deliberately does not use JSON or Variant binary serialization. JSON
## permits duplicate-key ambiguity and numeric coercion, while Variant encoding
## accepts many engine-owned types that are not part of the persisted profile
## contract. Every accepted byte stream has exactly one encoding.

const FORMAT: String = "zerkov.profile.canonical-value.v1"
const MAX_DEPTH: int = 8
const MAX_NODES: int = 2048
const MAX_COLLECTION_COUNT: int = 128
const MAX_STRING_BYTES: int = 512
const MAX_BLOB_BYTES: int = 1_052_672
const MAX_ENCODED_BYTES: int = 2_200_000
const MAX_ABS_INTEGER: int = 9_007_199_254_740_991

const _TAG_NIL: int = 0x6e # n
const _TAG_FALSE: int = 0x66 # f
const _TAG_TRUE: int = 0x74 # t
const _TAG_INT: int = 0x69 # i
const _TAG_STRING: int = 0x73 # s
const _TAG_BYTES: int = 0x78 # x
const _TAG_ARRAY: int = 0x61 # a
const _TAG_DICTIONARY: int = 0x64 # d
const _COUNT_SEPARATOR: int = 0x3a # :
const _INT_TERMINATOR: int = 0x3b # ;
const _ARRAY_OPEN: int = 0x5b # [
const _ARRAY_CLOSE: int = 0x5d # ]
const _DICTIONARY_OPEN: int = 0x7b # {
const _DICTIONARY_CLOSE: int = 0x7d # }


static func encode(value: Variant) -> Dictionary:
	var output := PackedByteArray()
	var budget: Array[int] = [MAX_NODES]
	var reason := _encode_value(value, 0, budget, output)
	if not reason.is_empty():
		return _failure(reason)
	if output.is_empty() or output.size() > MAX_ENCODED_BYTES:
		return _failure(&"encoded_size_invalid")
	return {"ok": true, "bytes": output, "reason": &""}


static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty() or bytes.size() > MAX_ENCODED_BYTES:
		return _failure(&"encoded_size_invalid")
	var state := {"index": 0, "nodes_left": MAX_NODES}
	var parsed := _decode_value(bytes, state, 0)
	if not bool(parsed.get("ok", false)):
		return parsed
	if int(state["index"]) != bytes.size():
		return _failure(&"trailing_bytes")
	var canonical := encode(parsed.get("value"))
	if not bool(canonical.get("ok", false)) \
			or (canonical.get("bytes", PackedByteArray()) as PackedByteArray) != bytes:
		return _failure(&"noncanonical_encoding")
	return {"ok": true, "value": parsed.get("value"), "reason": &""}


static func sha256_domain(domain: String, bytes: PackedByteArray) -> String:
	if domain.is_empty() or domain.to_utf8_buffer().size() > MAX_STRING_BYTES \
			or bytes.size() > MAX_ENCODED_BYTES:
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	var domain_bytes := domain.to_utf8_buffer()
	domain_bytes.append(0)
	if context.update(domain_bytes) != OK or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


static func is_sha256(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var text := value as String
	if text.length() != 64 or text != text.to_lower():
		return false
	for index in text.length():
		var code := text.unicode_at(index)
		if not (code >= 48 and code <= 57) and not (code >= 97 and code <= 102):
			return false
	return true


static func _encode_value(
	value: Variant,
	depth: int,
	budget: Array[int],
	output: PackedByteArray
) -> StringName:
	if depth > MAX_DEPTH:
		return &"depth_limit_exceeded"
	if budget[0] <= 0:
		return &"node_limit_exceeded"
	budget[0] -= 1
	match typeof(value):
		TYPE_NIL:
			output.append(_TAG_NIL)
		TYPE_BOOL:
			output.append(_TAG_TRUE if value else _TAG_FALSE)
		TYPE_INT:
			var integer := value as int
			if integer < -MAX_ABS_INTEGER or integer > MAX_ABS_INTEGER:
				return &"integer_out_of_bounds"
			output.append(_TAG_INT)
			output.append_array(str(integer).to_ascii_buffer())
			output.append(_INT_TERMINATOR)
		TYPE_STRING:
			var string_bytes := (value as String).to_utf8_buffer()
			if string_bytes.size() > MAX_STRING_BYTES:
				return &"string_too_large"
			_append_counted_prefix(output, _TAG_STRING, string_bytes.size())
			output.append_array(string_bytes)
		TYPE_PACKED_BYTE_ARRAY:
			var blob := value as PackedByteArray
			if blob.size() > MAX_BLOB_BYTES:
				return &"blob_too_large"
			_append_counted_prefix(output, _TAG_BYTES, blob.size())
			output.append_array(blob)
		TYPE_ARRAY:
			var array := value as Array
			if array.size() > MAX_COLLECTION_COUNT:
				return &"collection_too_large"
			_append_counted_prefix(output, _TAG_ARRAY, array.size())
			output.append(_ARRAY_OPEN)
			for child in array:
				var child_reason := _encode_value(child, depth + 1, budget, output)
				if not child_reason.is_empty():
					return child_reason
			output.append(_ARRAY_CLOSE)
		TYPE_DICTIONARY:
			var dictionary := value as Dictionary
			if dictionary.size() > MAX_COLLECTION_COUNT:
				return &"collection_too_large"
			var keys := PackedStringArray()
			for key in dictionary:
				if typeof(key) != TYPE_STRING:
					return &"dictionary_key_type_invalid"
				var key_text := key as String
				if key_text.to_utf8_buffer().size() > MAX_STRING_BYTES:
					return &"string_too_large"
				keys.append(key_text)
			keys.sort()
			_append_counted_prefix(output, _TAG_DICTIONARY, dictionary.size())
			output.append(_DICTIONARY_OPEN)
			for key in keys:
				var key_reason := _encode_value(String(key), depth + 1, budget, output)
				if not key_reason.is_empty():
					return key_reason
				var value_reason := _encode_value(dictionary[String(key)], depth + 1, budget, output)
				if not value_reason.is_empty():
					return value_reason
			output.append(_DICTIONARY_CLOSE)
		_:
			return &"value_type_invalid"
	if output.size() > MAX_ENCODED_BYTES:
		return &"encoded_size_invalid"
	return &""


static func _decode_value(bytes: PackedByteArray, state: Dictionary, depth: int) -> Dictionary:
	if depth > MAX_DEPTH:
		return _failure(&"depth_limit_exceeded")
	if int(state["nodes_left"]) <= 0:
		return _failure(&"node_limit_exceeded")
	state["nodes_left"] = int(state["nodes_left"]) - 1
	if int(state["index"]) >= bytes.size():
		return _failure(&"unexpected_end")
	var tag := bytes[int(state["index"])]
	state["index"] = int(state["index"]) + 1
	match tag:
		_TAG_NIL:
			return _success(null)
		_TAG_FALSE:
			return _success(false)
		_TAG_TRUE:
			return _success(true)
		_TAG_INT:
			return _decode_integer(bytes, state)
		_TAG_STRING:
			return _decode_string(bytes, state)
		_TAG_BYTES:
			return _decode_blob(bytes, state)
		_TAG_ARRAY:
			return _decode_array(bytes, state, depth)
		_TAG_DICTIONARY:
			return _decode_dictionary(bytes, state, depth)
	return _failure(&"unknown_type_tag")


static func _decode_integer(bytes: PackedByteArray, state: Dictionary) -> Dictionary:
	var start := int(state["index"])
	var end := _find_byte(bytes, start, _INT_TERMINATOR, 20)
	if end < 0:
		return _failure(&"integer_encoding_invalid")
	var encoded := bytes.slice(start, end)
	if encoded.is_empty():
		return _failure(&"integer_encoding_invalid")
	var text := encoded.get_string_from_ascii()
	var integer := text.to_int()
	if str(integer) != text or integer < -MAX_ABS_INTEGER or integer > MAX_ABS_INTEGER:
		return _failure(&"integer_encoding_invalid")
	state["index"] = end + 1
	return _success(integer)


static func _decode_string(bytes: PackedByteArray, state: Dictionary) -> Dictionary:
	var length_result := _decode_count(bytes, state, MAX_STRING_BYTES)
	if not bool(length_result.get("ok", false)):
		return length_result
	var length := int(length_result["value"])
	var start := int(state["index"])
	if length > bytes.size() - start:
		return _failure(&"unexpected_end")
	var encoded := bytes.slice(start, start + length)
	if not _is_valid_utf8(encoded):
		return _failure(&"utf8_invalid")
	var value := encoded.get_string_from_utf8()
	if value.to_utf8_buffer() != encoded:
		return _failure(&"utf8_invalid")
	state["index"] = start + length
	return _success(value)


static func _decode_blob(bytes: PackedByteArray, state: Dictionary) -> Dictionary:
	var length_result := _decode_count(bytes, state, MAX_BLOB_BYTES)
	if not bool(length_result.get("ok", false)):
		return length_result
	var length := int(length_result["value"])
	var start := int(state["index"])
	if length > bytes.size() - start:
		return _failure(&"unexpected_end")
	state["index"] = start + length
	return _success(bytes.slice(start, start + length))


static func _decode_array(
	bytes: PackedByteArray,
	state: Dictionary,
	depth: int
) -> Dictionary:
	var count_result := _decode_count(bytes, state, MAX_COLLECTION_COUNT)
	if not bool(count_result.get("ok", false)):
		return count_result
	if not _consume(bytes, state, _ARRAY_OPEN):
		return _failure(&"array_open_missing")
	var value: Array = []
	for _index in int(count_result["value"]):
		var child := _decode_value(bytes, state, depth + 1)
		if not bool(child.get("ok", false)):
			return child
		value.append(child.get("value"))
	if not _consume(bytes, state, _ARRAY_CLOSE):
		return _failure(&"array_close_missing")
	return _success(value)


static func _decode_dictionary(
	bytes: PackedByteArray,
	state: Dictionary,
	depth: int
) -> Dictionary:
	var count_result := _decode_count(bytes, state, MAX_COLLECTION_COUNT)
	if not bool(count_result.get("ok", false)):
		return count_result
	if not _consume(bytes, state, _DICTIONARY_OPEN):
		return _failure(&"dictionary_open_missing")
	var value: Dictionary = {}
	var previous_key: String = ""
	var has_previous: bool = false
	for _index in int(count_result["value"]):
		var key_result := _decode_value(bytes, state, depth + 1)
		if not bool(key_result.get("ok", false)) \
				or typeof(key_result.get("value")) != TYPE_STRING:
			return _failure(&"dictionary_key_type_invalid")
		var key := key_result["value"] as String
		if value.has(key):
			return _failure(&"duplicate_dictionary_key")
		if has_previous and key <= previous_key:
			return _failure(&"dictionary_key_order_invalid")
		var child := _decode_value(bytes, state, depth + 1)
		if not bool(child.get("ok", false)):
			return child
		value[key] = child.get("value")
		previous_key = key
		has_previous = true
	if not _consume(bytes, state, _DICTIONARY_CLOSE):
		return _failure(&"dictionary_close_missing")
	return _success(value)


static func _decode_count(
	bytes: PackedByteArray,
	state: Dictionary,
	maximum: int
) -> Dictionary:
	var start := int(state["index"])
	var end := _find_byte(bytes, start, _COUNT_SEPARATOR, 10)
	if end < 0:
		return _failure(&"count_encoding_invalid")
	var encoded := bytes.slice(start, end)
	if encoded.is_empty():
		return _failure(&"count_encoding_invalid")
	var text := encoded.get_string_from_ascii()
	var count := text.to_int()
	if count < 0 or count > maximum or str(count) != text:
		return _failure(&"count_encoding_invalid")
	state["index"] = end + 1
	return _success(count)


static func _find_byte(
	bytes: PackedByteArray,
	start: int,
	needle: int,
	maximum_length: int
) -> int:
	var limit := mini(bytes.size(), start + maximum_length + 1)
	for index in range(start, limit):
		if bytes[index] == needle:
			return index
	return -1


static func _consume(bytes: PackedByteArray, state: Dictionary, expected: int) -> bool:
	var index := int(state["index"])
	if index >= bytes.size() or bytes[index] != expected:
		return false
	state["index"] = index + 1
	return true


static func _is_valid_utf8(bytes: PackedByteArray) -> bool:
	var index: int = 0
	while index < bytes.size():
		var first := bytes[index]
		if first <= 0x7f:
			index += 1
			continue
		if first >= 0xc2 and first <= 0xdf:
			if index + 1 >= bytes.size() or not _is_continuation(bytes[index + 1]):
				return false
			index += 2
			continue
		if first >= 0xe0 and first <= 0xef:
			if index + 2 >= bytes.size() or not _is_continuation(bytes[index + 2]):
				return false
			var second := bytes[index + 1]
			if first == 0xe0:
				if second < 0xa0 or second > 0xbf:
					return false
			elif first == 0xed:
				if second < 0x80 or second > 0x9f:
					return false
			elif not _is_continuation(second):
				return false
			index += 3
			continue
		if first >= 0xf0 and first <= 0xf4:
			if index + 3 >= bytes.size() \
					or not _is_continuation(bytes[index + 2]) \
					or not _is_continuation(bytes[index + 3]):
				return false
			var second := bytes[index + 1]
			if first == 0xf0:
				if second < 0x90 or second > 0xbf:
					return false
			elif first == 0xf4:
				if second < 0x80 or second > 0x8f:
					return false
			elif not _is_continuation(second):
				return false
			index += 4
			continue
		return false
	return true


static func _is_continuation(byte: int) -> bool:
	return byte >= 0x80 and byte <= 0xbf


static func _append_counted_prefix(
	output: PackedByteArray,
	tag: int,
	count: int
) -> void:
	output.append(tag)
	output.append_array(str(count).to_ascii_buffer())
	output.append(_COUNT_SEPARATOR)


static func _success(value: Variant) -> Dictionary:
	return {"ok": true, "value": value, "reason": &""}


static func _failure(reason: StringName) -> Dictionary:
	return {"ok": false, "value": null, "reason": reason}
