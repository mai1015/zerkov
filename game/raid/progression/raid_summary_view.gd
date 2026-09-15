class_name RaidSummaryView
extends RefCounted
## Immutable presentation projection. It accepts only a validated committed
## settlement receipt, never an uncommitted raid scene or authored sample values.
var _value: Dictionary = {}
static func from_committed(result: Dictionary) -> RaidSummaryView:
	if result.get("ok")!=true or result.get("committed")!=true \
		or not result.get("receipt") is Dictionary or not RaidProgressionValues.valid_receipt(result.receipt):return null
	var receipt: Dictionary=result.receipt
	var view:=RaidSummaryView.new()
	view._value=RaidProgressionValues.freeze({"raid_id":receipt.raid_id,"settlement_id":receipt.settlement_id,
		"final":true,"outcome":receipt.outcome,"duration_ticks":receipt.duration_ticks,
		"audit_available":receipt.audit_available,"audit_digest":receipt.audit_digest,
		"stats":receipt.stats,"health":receipt.health,"task":receipt.task,
		"retained":receipt.retained,"lost":receipt.lost,"valuation_available":false,"currency_reward":0,
		"profile_generation":receipt.profile_generation,"input_digest":receipt.input_digest})
	return view
func snapshot() -> Dictionary:
	return _value
