class_name GameplayNetworkPolicyBridge
extends RefCounted

## Applies an authored [GameplayNetworkPolicy] resource to a
## [GameplayAbilityNetworkBridge]'s EXISTING setters (task 9.1's remainder:
## "this is what feeds the bridge's hidden_* properties instead of hand-
## maintained arrays"). This is a one-way, one-time push -- call it again
## after mutating the policy resource if the change should take effect.
##
## Only [member GameplayNetworkPolicy.hidden_attribute_identifiers],
## [member GameplayNetworkPolicy.hidden_tag_identifiers],
## [member GameplayNetworkPolicy.hidden_ability_identifiers],
## [member GameplayNetworkPolicy.default_relevant_peers], and
## [member GameplayNetworkPolicy.owner_view_default] are applied here --
## [GameplayAbilityNetworkBridge] exposes a live setter for exactly those.
## [member GameplayNetworkPolicy.resync_rate_limit_per_minute] and
## [member GameplayNetworkPolicy.prediction_opt_in] are declarative-only (see
## that resource's header comment for why) and are intentionally not applied
## to anything here.
static func apply(policy: GameplayNetworkPolicy, bridge: GameplayAbilityNetworkBridge) -> void:
	if policy == null or bridge == null:
		return
	bridge.set_hidden_attribute_identifiers(policy.get_hidden_attribute_identifiers())
	bridge.set_hidden_tag_identifiers(policy.get_hidden_tag_identifiers())
	bridge.set_hidden_ability_identifiers(policy.get_hidden_ability_identifiers())
	bridge.set_owner_view(policy.get_owner_view_default())
	if not policy.get_default_relevant_peers().is_empty():
		bridge.set_relevant_peers(policy.get_default_relevant_peers())
