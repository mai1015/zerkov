class_name InventoryView
extends ZReadOnlyView
## Confirmed inventory projection for one profile or raid scope.

enum Scope {
	PROFILE,
	RAID,
}

enum ContainerKind {
	POCKETS,
	RIG,
	BACKPACK,
	SECURE,
	EQUIPMENT,
	STASH,
	CRATE,
	CORPSE,
}

class ItemRecord extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _instance_id: int = 0:
		set(value):
			if not _sealed:
				_instance_id = value
	var _content_id: StringName = &"":
		set(value):
			if not _sealed:
				_content_id = value
	var _display_name: String = "":
		set(value):
			if not _sealed:
				_display_name = value
	var _quantity: int = 0:
		set(value):
			if not _sealed:
				_quantity = value
	var _position: Vector2i = Vector2i.ZERO:
		set(value):
			if not _sealed:
				_position = value
	var _size: Vector2i = Vector2i.ONE:
		set(value):
			if not _sealed:
				_size = value
	var _rotated: bool = false:
		set(value):
			if not _sealed:
				_rotated = value
	var _icon_id: StringName = &"":
		set(value):
			if not _sealed:
				_icon_id = value
	var _category: StringName = &"":
		set(value):
			if not _sealed:
				_category = value
	var _placeholder_art: bool = false:
		set(value):
			if not _sealed:
				_placeholder_art = value

	static func create(
		p_instance_id: int,
		p_content_id: StringName,
		p_display_name: String,
		p_quantity: int,
		p_position: Vector2i,
		p_size: Vector2i,
		p_rotated: bool,
		p_icon_id: StringName,
		p_category: StringName,
		p_placeholder_art: bool = false
	) -> ItemRecord:
		if p_instance_id <= 0 or not ZReadOnlyView.content_id_is_valid(p_content_id) \
				or p_display_name.is_empty() or p_quantity <= 0:
			return null
		if p_position.x < 0 or p_position.y < 0 or p_size.x <= 0 or p_size.y <= 0:
			return null
		var result := ItemRecord.new()
		result._instance_id = p_instance_id
		result._content_id = p_content_id
		result._display_name = p_display_name
		result._quantity = p_quantity
		result._position = p_position
		result._size = p_size
		result._rotated = p_rotated
		result._icon_id = p_icon_id
		result._category = p_category
		result._placeholder_art = p_placeholder_art
		result._seal_record()
		return result

	func instance_id() -> int:
		return _instance_id

	func content_id() -> StringName:
		return _content_id

	func display_name() -> String:
		return _display_name

	func quantity() -> int:
		return _quantity

	func position() -> Vector2i:
		return _position

	func size() -> Vector2i:
		return _size

	func rotated() -> bool:
		return _rotated

	func icon_id() -> StringName:
		return _icon_id

	func category() -> StringName:
		return _category

	func uses_placeholder_art() -> bool:
		return _placeholder_art

	func snapshot() -> ItemRecord:
		return create(_instance_id, _content_id, _display_name, _quantity,
			_position, _size, _rotated, _icon_id, _category, _placeholder_art)

class ContainerRecord extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _inventory_id: int = 0:
		set(value):
			if not _sealed:
				_inventory_id = value
	var _container_id: int = 0:
		set(value):
			if not _sealed:
				_container_id = value
	var _inventory_revision: int = 0:
		set(value):
			if not _sealed:
				_inventory_revision = value
	var _kind: ContainerKind = ContainerKind.POCKETS:
		set(value):
			if not _sealed:
				_kind = value
	var _content_id: StringName = &"":
		set(value):
			if not _sealed:
				_content_id = value
	var _display_name: String = "":
		set(value):
			if not _sealed:
				_display_name = value
	var _grid_size: Vector2i = Vector2i.ONE:
		set(value):
			if not _sealed:
				_grid_size = value
	var _read_only: bool = true:
		set(value):
			if not _sealed:
				_read_only = value
	var _items: Array[ItemRecord] = []:
		set(value):
			if not _sealed:
				_items = value

	static func create(
		p_inventory_id: int,
		p_container_id: int,
		p_inventory_revision: int,
		p_kind: ContainerKind,
		p_content_id: StringName,
		p_display_name: String,
		p_grid_size: Vector2i,
		p_read_only: bool,
		p_items: Array[ItemRecord]
	) -> ContainerRecord:
		if p_inventory_id <= 0 or p_container_id <= 0 or p_inventory_revision < 0 \
				or not ZReadOnlyView.content_id_is_valid(p_content_id) \
				or p_display_name.is_empty() or p_grid_size.x <= 0 or p_grid_size.y <= 0:
			return null
		if not ZReadOnlyView.enum_value_is_valid(int(p_kind), ContainerKind.size()):
			return null
		var seen: Dictionary = {}
		for item in p_items:
			if item == null or seen.has(item.instance_id()):
				return null
			if item.position().x + item.size().x > p_grid_size.x \
					or item.position().y + item.size().y > p_grid_size.y:
				return null
			seen[item.instance_id()] = true
		var result := ContainerRecord.new()
		result._inventory_id = p_inventory_id
		result._container_id = p_container_id
		result._inventory_revision = p_inventory_revision
		result._kind = p_kind
		result._content_id = p_content_id
		result._display_name = p_display_name
		result._grid_size = p_grid_size
		result._read_only = p_read_only
		for item in p_items:
			result._items.append(item.snapshot())
		result._items.make_read_only()
		result._seal_record()
		return result

	func inventory_id() -> int:
		return _inventory_id

	func container_id() -> int:
		return _container_id

	func inventory_revision() -> int:
		return _inventory_revision

	func kind() -> ContainerKind:
		return _kind

	func content_id() -> StringName:
		return _content_id

	func display_name() -> String:
		return _display_name

	func grid_size() -> Vector2i:
		return _grid_size

	func is_interaction_read_only() -> bool:
		return _read_only

	func items() -> Array[ItemRecord]:
		var result: Array[ItemRecord] = []
		for item in _items:
			result.append(item.snapshot())
		result.make_read_only()
		return result

	func snapshot() -> ContainerRecord:
		return create(_inventory_id, _container_id, _inventory_revision, _kind, _content_id,
			_display_name, _grid_size, _read_only, items())

var _scope: Scope = Scope.PROFILE:
	set(value):
		if not _sealed_view:
			_scope = value
var _actor_key: String = "":
	set(value):
		if not _sealed_view:
			_actor_key = value
var _containers: Array[ContainerRecord] = []:
	set(value):
		if not _sealed_view:
			_containers = value


static func create(
	p_generation: int,
	p_revision: int,
	p_source_tick: int,
	p_scope: Scope,
	p_actor_id: ZEntityId,
	p_containers: Array[ContainerRecord]
) -> InventoryView:
	if p_actor_id == null or not p_actor_id.is_initialized():
		return null
	if not enum_value_is_valid(int(p_scope), Scope.size()):
		return null
	var seen: Dictionary = {}
	var inventory_revisions: Dictionary = {}
	for container in p_containers:
		if container == null:
			return null
		var key := "%d:%d" % [container.inventory_id(), container.container_id()]
		if seen.has(key):
			return null
		if inventory_revisions.has(container.inventory_id()) \
				and int(inventory_revisions[container.inventory_id()]) != container.inventory_revision():
			return null
		inventory_revisions[container.inventory_id()] = container.inventory_revision()
		seen[key] = true
	var result := InventoryView.new()
	result._scope = p_scope
	result._actor_key = p_actor_id.canonical_key()
	for container in p_containers:
		result._containers.append(container.snapshot())
	result._containers.make_read_only()
	if not result._initialize_view(p_generation, p_revision, p_source_tick, SyncState.READY):
		return null
	return result


static func unavailable(
	p_scope: Scope,
	p_sync_state: SyncState,
	p_diagnostic: StringName,
	p_generation: int = 0,
	p_revision: int = 0,
	p_source_tick: int = 0,
	p_actor_id: ZEntityId = null
) -> InventoryView:
	if p_sync_state == SyncState.READY:
		return null
	if not enum_value_is_valid(int(p_scope), Scope.size()):
		return null
	if sync_state_requires_subject(p_sync_state) \
			and (p_actor_id == null or not p_actor_id.is_initialized()):
		return null
	var result := InventoryView.new()
	result._scope = p_scope
	result._actor_key = p_actor_id.canonical_key() if p_actor_id != null else ""
	return result if result._initialize_view(
		p_generation, p_revision, p_source_tick, p_sync_state, p_diagnostic) else null


func scope() -> Scope:
	return _scope


func actor_id() -> ZEntityId:
	return ZEntityId.parse(_actor_key) if not _actor_key.is_empty() else null


func _ready_payload_is_valid() -> bool:
	if actor_id() == null or not enum_value_is_valid(int(_scope), Scope.size()):
		return false
	var keys: Dictionary = {}
	var revisions: Dictionary = {}
	for container in _containers:
		if container == null or container.snapshot() == null:
			return false
		var key := "%d:%d" % [container.inventory_id(), container.container_id()]
		if keys.has(key):
			return false
		keys[key] = true
		if revisions.has(container.inventory_id()) \
				and int(revisions[container.inventory_id()]) != container.inventory_revision():
			return false
		revisions[container.inventory_id()] = container.inventory_revision()
	return true


func containers() -> Array[ContainerRecord]:
	var result: Array[ContainerRecord] = []
	for container in _containers:
		result.append(container.snapshot())
	result.make_read_only()
	return result
