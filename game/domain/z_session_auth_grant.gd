class_name ZSessionAuthGrant
extends RefCounted
## Credential-free claims returned by a trusted server-side authenticator.

var principal_key: StringName = &""
var profile_key: StringName = &""
var actor_slot: StringName = &""


static func create(
	p_principal_key: StringName,
	p_profile_key: StringName,
	p_actor_slot: StringName
) -> ZSessionAuthGrant:
	var result := ZSessionAuthGrant.new()
	result.principal_key = p_principal_key
	result.profile_key = p_profile_key
	result.actor_slot = p_actor_slot
	return result if result.is_well_formed() else null


func is_well_formed() -> bool:
	return (
		ZIdentityRules.is_valid_part(String(principal_key))
		and ZIdentityRules.is_valid_part(String(profile_key))
		and ZIdentityRules.is_valid_part(String(actor_slot))
	)


func snapshot() -> ZSessionAuthGrant:
	if not is_well_formed():
		return null
	return create(principal_key, profile_key, actor_slot)
