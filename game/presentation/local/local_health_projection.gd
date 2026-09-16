class_name LocalHealthProjection
extends RefCounted
## HealthView uses displayed whole HP; canonical combat retains microunits.
## Home recovery is an explicit local campaign rule, not a rewritten raid receipt.
static func from_combat(admission: ZSessionAdmission, health: Dictionary) -> HealthView:
	if health.is_empty() or health.get("actor_id") != admission.actor_id.canonical_key(): return null
	var parts: Array[HealthView.BodyPart] = []
	for zone: Dictionary in health.body_parts:
		var current := maxi(0, ceili(float(zone.health_micros) / 1_000_000.0))
		var maximum := ceili(float(zone.max_health_micros) / 1_000_000.0)
		var state: HealthView.BodyPartState = HealthView.BodyPartState.HEALTHY
		if current == 0: state = HealthView.BodyPartState.DESTROYED
		elif current < maximum or zone.heavy_bleed or zone.fractured: state = HealthView.BodyPartState.INJURED
		parts.append(HealthView.BodyPart.create(zone.zone_identifier, String(zone.zone_identifier).capitalize(),
			current, maximum, state, zone.heavy_bleed, zone.fractured))
	return HealthView.create(admission.generation, int(health.health_revision), int(health.tick), admission.actor_id,
		HealthView.LifeState.ALIVE if health.alive else HealthView.LifeState.DEAD,
		int(health.stamina_micros) / 1_000_000, int(health.max_stamina_micros) / 1_000_000, int(health.hydration_micros) / 1_000_000, 100,
		0, 1, parts, [], false)

static func recovered_home(admission: ZSessionAdmission) -> HealthView:
	var parts: Array[HealthView.BodyPart] = []
	for zone: Dictionary in ZerkovHealthAbilityContent.body_zone_declarations():
		var maximum := ceili(float(zone.max_health_micros) / 1_000_000.0)
		parts.append(HealthView.BodyPart.create(zone.zone_identifier, String(zone.zone_identifier).capitalize(),
			maximum, maximum, HealthView.BodyPartState.HEALTHY))
	return HealthView.create(admission.generation, 1, 0, admission.actor_id, HealthView.LifeState.ALIVE,
		100, 100, 100, 100, 0, 1, parts, [], false)
