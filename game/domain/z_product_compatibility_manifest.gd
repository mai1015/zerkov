class_name ZProductCompatibilityManifest
extends RefCounted
## Product-owned compatibility offer used before a remote session is admitted.

const MAX_VERSION: int = 2_147_483_647
const MAX_FEATURES: int = 64
const SHA256_HEX_LENGTH: int = 64

var protocol_version: int = 0
var command_schema_version: int = 0
var content_fingerprint: String = ""
var features: PackedStringArray = PackedStringArray()


static func create(
	p_protocol_version: int,
	p_command_schema_version: int,
	p_content_fingerprint: String,
	p_features: PackedStringArray = PackedStringArray()
) -> ZProductCompatibilityManifest:
	var normalized := _normalize_features(p_features)
	if normalized.is_empty() and not p_features.is_empty():
		return null
	var result := ZProductCompatibilityManifest.new()
	result.protocol_version = p_protocol_version
	result.command_schema_version = p_command_schema_version
	result.content_fingerprint = p_content_fingerprint
	result.features = normalized
	return result if result.is_well_formed() else null


func is_well_formed() -> bool:
	if (
		protocol_version <= 0
		or protocol_version > MAX_VERSION
		or command_schema_version <= 0
		or command_schema_version > MAX_VERSION
		or not is_sha256(content_fingerprint)
		or features.size() > MAX_FEATURES
	):
		return false
	var previous := ""
	for feature_name in features:
		var feature := String(feature_name)
		if not ZIdentityRules.is_valid_part(feature):
			return false
		if not previous.is_empty() and feature <= previous:
			return false
		previous = feature
	return true


func snapshot() -> ZProductCompatibilityManifest:
	if not is_well_formed():
		return null
	return create(
		protocol_version,
		command_schema_version,
		content_fingerprint,
		features.duplicate()
	)


func rejection_against(required: ZProductCompatibilityManifest) -> StringName:
	if not is_well_formed() or required == null or not required.is_well_formed():
		return &"malformed_compatibility_manifest"
	if protocol_version != required.protocol_version:
		return &"protocol_version_mismatch"
	if command_schema_version != required.command_schema_version:
		return &"command_schema_version_mismatch"
	if content_fingerprint != required.content_fingerprint:
		return &"content_fingerprint_mismatch"
	var offered: Dictionary = {}
	for feature_name in features:
		offered[String(feature_name)] = true
	for required_feature in required.features:
		if not offered.has(String(required_feature)):
			return &"missing_required_feature"
	return &""


func digest() -> String:
	if not is_well_formed():
		return ""
	return (
		"protocol=%d\nschema=%d\ncontent=%s\nfeatures=%s"
		% [
			protocol_version,
			command_schema_version,
			content_fingerprint,
			",".join(features),
		]
	).sha256_text()


func negotiation_digest(required: ZProductCompatibilityManifest) -> String:
	if not rejection_against(required).is_empty():
		return ""
	return ("%s\n%s" % [required.digest(), digest()]).sha256_text()


static func is_sha256(value: String) -> bool:
	if value.length() != SHA256_HEX_LENGTH or value.to_utf8_buffer().size() != SHA256_HEX_LENGTH:
		return false
	for index in value.length():
		var code := value.unicode_at(index)
		var is_digit := code >= 48 and code <= 57
		var is_lower_hex := code >= 97 and code <= 102
		if not is_digit and not is_lower_hex:
			return false
	return true


static func _normalize_features(source: PackedStringArray) -> PackedStringArray:
	if source.size() > MAX_FEATURES:
		return PackedStringArray()
	var result := PackedStringArray()
	var seen: Dictionary = {}
	for raw_name in source:
		var feature := String(raw_name)
		if not ZIdentityRules.is_valid_part(feature):
			return PackedStringArray()
		if seen.has(feature):
			continue
		seen[feature] = true
		result.append(feature)
	result.sort()
	return result
