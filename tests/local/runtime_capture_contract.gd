extends RefCounted
## Native differential regression for the runtime capture scanner. Compares
## every result to the unchanged RaidAuthority reference on the SAME authority.
class Holder:
	extends RefCounted
	var payload: Variant
	func noop() -> void: pass
class ScriptedDefinition:
	extends GameplayModifierDeclaration
	var payload: Variant
	func _get_property_list() -> Array[Dictionary]:
		return [{"name":"pretend_integer", "type":TYPE_INT}]
	func _get(property: StringName) -> Variant:
		return payload if property == &"pretend_integer" else null

var _raid: RaidAuthority
var _check: Callable
var _checks: int = 0
var _failures: int = 0
func run(raid: RaidAuthority, check_callback: Callable) -> bool:
	_raid = raid
	_check = check_callback
	var holder := Holder.new()
	var bearer := BodyHitboxWorld2D.BindingCapability.new()
	for native: String in RaidCallbackCaptureScanner.NATIVE_DEFINITIONS:
		var definition := ClassDB.instantiate(StringName(native)) as Resource
		if not _assert(definition != null, "shipped native definition exists " + native): return false
		holder.payload = definition
		if not _same(holder, true, "empty native definition " + native): return false
		definition.set_meta(&"capture_test", {"counter":1})
		if not _same(holder, true, "late primitive metadata " + native): return false
		definition.set_meta(&"capture_test", [{"capability":bearer}])
		if not _same(holder, false, "late native metadata cannot hide bearer " + native): return false
		definition.remove_meta(&"capture_test")
		if not _same(holder, true, "metadata removal revalidated " + native): return false
		var mutable: Array = [1]
		definition.set_meta(&"capture_test", mutable)
		if not _same(holder, true, "mutable metadata starts safe " + native): return false
		mutable.append(bearer)
		if not _same(holder, false, "same array mutated after safe scan " + native): return false
		definition.remove_meta(&"capture_test")
	var scripted := ScriptedDefinition.new()
	holder.payload = scripted
	scripted.payload = 7
	if not _same(holder, true, "script attached to whitelisted native class uses full scan"): return false
	scripted.payload = bearer
	if not _same(holder, false, "script cannot disguise a bearer as typed scalar"): return false
	scripted.payload = null
	var nested: Variant = 0
	for depth in range(20):
		holder.payload = nested
		if not _equivalent(holder, "depth boundary " + str(depth)): return false
		nested = {"child":nested}
	var cyclic: Array = []
	cyclic.append(cyclic)
	holder.payload = cyclic
	if not _same(holder, false, "cyclic collection fails closed"): return false
	cyclic.clear()
	holder.payload = {bearer:"key"}
	if not _same(holder, false, "bearer as dictionary key"): return false
	holder.payload = Callable(holder, "noop").bind(bearer)
	if not _same(holder, false, "bound callable argument scanned"): return false
	holder.payload = null
	if not _lifecycle_boundaries(): return false
	print("RUNTIME_CAPTURE_RESULT checks=", _checks, " failures=", _failures)
	return _failures == 0

func _equivalent(holder: Holder, label: String) -> bool:
	var callback := Callable(holder, "noop")
	var reference := not _raid._variant_graph_contains_hitbox_bearer(callback, 0, {_raid.get_instance_id():true})
	return _assert(_raid.phase_handler_callback_is_safe(callback) == reference, label)

func _same(holder: Holder, expected: bool, label: String) -> bool:
	var callback := Callable(holder, "noop")
	var reference := not _raid._variant_graph_contains_hitbox_bearer(callback, 0, {_raid.get_instance_id():true})
	return _assert(reference == expected and _raid.phase_handler_callback_is_safe(callback) == reference, label)

func _assert(ok: bool, label: String) -> bool:
	_checks += 1
	if not ok: _failures += 1
	return bool(_check.call(ok, "capture audit: " + label))

# Short real-native reproduction of the production failure: a derived authority
# could run ticks but its lexical release attestation had the wrong script ID.
func _lifecycle_boundaries() -> bool:
	var index: int = 0
	for ending: String in ["completed", "failed", "settling_shutdown"]:
		index += 1
		var authority := RaidAuthority.new()
		var id := ZRaidId.from_parts(PackedStringArray(["capture", ending]))
		var admission := SessionCoordinator.new().open_offline(id, StringName("capture" + ending))
		if not _assert(authority.configure(id, admission, 1), ending + " configures exact authority"): return false
		var owner := RaidVisionWorldOwner.new()
		(Engine.get_main_loop() as SceneTree).root.add_child(owner)
		var ok := _assert(owner.configure(9_000 + index), ending + " configures real Vision")
		ok = _assert(owner.register_with_raid_authority(authority), ending + " registers reserved owner") and ok
		ok = _assert(authority.transition(RaidAuthority.Lifecycle.ACTIVE, authority.generation()), ending + " activates") and ok
		ok = _assert(authority.advance_one(authority.generation()), ending + " executes real native tick") and ok
		ok = _assert(authority.transition(RaidAuthority.Lifecycle.SETTLING, authority.generation()), ending + " enters settling") and ok
		if ending == "completed":
			ok = _assert(authority.transition(RaidAuthority.Lifecycle.COMPLETED, authority.generation()), "completion releases Vision with exact lexical attestation") and ok
		elif ending == "failed":
			ok = _assert(authority.transition(RaidAuthority.Lifecycle.FAILED, authority.generation()), "failure releases Vision with exact lexical attestation") and ok
		ok = _assert(authority.teardown(authority.generation()), ending + " authority teardown") and ok
		ok = _assert(owner.lifecycle == RaidVisionWorldOwner.Lifecycle.QUARANTINED, ending + " owner is synchronously quarantined") and ok
		ok = _assert(owner.teardown(owner.generation()), ending + " owner disposal after slot release") and ok
		owner.free()
		if not ok: return false
	return true
