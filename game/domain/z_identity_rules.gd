class_name ZIdentityRules
extends RefCounted
## Canonical grammar for product-owned runtime identities.

const PREFIX: String = "zerkov"
const MAX_SEGMENTS: int = 12
const MAX_SEGMENT_BYTES: int = 48
const MAX_IDENTIFIER_BYTES: int = 192


static func compose(kind: StringName, parts: PackedStringArray) -> String:
	var segments := PackedStringArray([PREFIX, String(kind)])
	segments.append_array(parts)
	return ".".join(segments)


static func is_valid(raw: String, expected_kind: StringName) -> bool:
	if raw.is_empty() or raw.to_utf8_buffer().size() > MAX_IDENTIFIER_BYTES:
		return false
	var segments := raw.split(".", true)
	if segments.size() < 4 or segments.size() > MAX_SEGMENTS:
		return false
	if segments[0] != PREFIX or segments[1] != String(expected_kind):
		return false
	for segment in segments:
		if not _is_valid_segment(segment):
			return false
	return true


static func is_valid_part(part: String) -> bool:
	return _is_valid_segment(part)


static func _is_valid_segment(segment: String) -> bool:
	if segment.is_empty() or segment.to_utf8_buffer().size() > MAX_SEGMENT_BYTES:
		return false
	for index in segment.length():
		var code := segment.unicode_at(index)
		var is_lower := code >= 97 and code <= 122
		var is_digit := code >= 48 and code <= 57
		if not is_lower and not is_digit and code != 95 and code != 45:
			return false
	return true
