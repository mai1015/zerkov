class_name ZUIRouteIntent
extends RefCounted

## One admitted request to mutate the CommonUI-owned screen composition.
## This object is a command envelope only; it never stores presentation or
## gameplay authority and it is not a second navigation stack.

enum Kind {
	OPEN,
	BACK,
}

enum Origin {
	PRODUCTION,
	DEVELOPER_CATALOG,
	REVIEW,
	SYSTEM,
}

enum StackMode {
	AUTO,
	RESET,
}

var kind: Kind = Kind.OPEN
var route_id: StringName = &""
var origin_route: StringName = &""
var origin: Origin = Origin.PRODUCTION
var stack_mode: StackMode = StackMode.AUTO
var payload: ZUIRoutePayload = null
## Opaque, one-session capability issued by the live F1 catalog. Merely
## selecting the DEVELOPER_CATALOG enum never grants developer-route access.
var authorization: RefCounted = null


func _init(
	p_kind: Kind = Kind.OPEN,
	p_route_id: StringName = &"",
	p_origin_route: StringName = &"",
	p_origin: Origin = Origin.PRODUCTION,
	p_stack_mode: StackMode = StackMode.AUTO,
	p_payload: ZUIRoutePayload = null,
	p_authorization: RefCounted = null
) -> void:
	kind = p_kind
	route_id = p_route_id
	origin_route = p_origin_route
	origin = p_origin
	stack_mode = p_stack_mode
	payload = ZUIRoutePayload.new(p_payload.type_id, p_payload.values()) \
			if p_payload != null else ZUIRoutePayload.empty()
	authorization = p_authorization


static func open_route(
	p_route_id: StringName,
	p_origin_route: StringName = &"",
	p_origin: Origin = Origin.PRODUCTION,
	p_stack_mode: StackMode = StackMode.AUTO,
	p_payload: ZUIRoutePayload = null,
	p_authorization: RefCounted = null
) -> ZUIRouteIntent:
	return ZUIRouteIntent.new(
		Kind.OPEN,
		p_route_id,
		p_origin_route,
		p_origin,
		p_stack_mode,
		p_payload,
		p_authorization
	)


static func back(
	p_origin_route: StringName,
	p_origin: Origin = Origin.PRODUCTION
) -> ZUIRouteIntent:
	return ZUIRouteIntent.new(
		Kind.BACK,
		p_origin_route,
		p_origin_route,
		p_origin,
		StackMode.AUTO,
		ZUIRoutePayload.empty(),
		null
	)
