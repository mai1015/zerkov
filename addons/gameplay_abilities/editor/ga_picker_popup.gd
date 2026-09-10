class_name GAPickerPopup
extends PopupPanel

## Reusable searchable picker popup shared by the hierarchical tag picker and
## the flat/grouped attribute/effect/ability/cue/target-schema pickers
## (design.md decision 2, tasks.md 2.2/2.3). Built in code, no companion
## .tscn, matching this addon's existing dashboard convention
## (see [GameplayAbilitiesDashboard]'s own header comment). All the actual
## search/filter/hierarchy-building/keyboard-index math lives in
## [GATagHierarchy] and [GAPickerNavigation] -- this class only wires those
## pure functions to a LineEdit + Tree and emits the result, so it stays a
## thin, mostly-untested-by-necessity editor-only shell (see
## tests/gameplay_abilities/smoke/test_orphan_preservation.gd for the parts
## of the picker glue that ARE exercised headlessly).

signal identifier_picked(identifier: String)
signal cleared()

var _hierarchical: bool = false
var _hierarchy: Dictionary = {}
var _flat_identifiers: PackedStringArray = PackedStringArray()
var _allow_clear: bool = true

var _search_edit: LineEdit
var _tree: Tree
var _clear_button: Button
## Current visible rows, in display order; each {"full": String, "item": TreeItem}.
var _rows: Array = []


func _ready() -> void:
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(320, 360)
	add_child(vbox)

	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Search..."
	_search_edit.text_changed.connect(_on_search_changed)
	_search_edit.gui_input.connect(_on_search_gui_input)
	vbox.add_child(_search_edit)

	_clear_button = Button.new()
	_clear_button.text = "Clear Selection"
	_clear_button.pressed.connect(func() -> void:
		cleared.emit()
		hide())
	vbox.add_child(_clear_button)

	_tree = Tree.new()
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_activated.connect(_on_tree_item_activated)
	vbox.add_child(_tree)

	_rebuild()


## Populates the popup with a full dotted-identifier hierarchy (the tag
## picker's mode -- tasks.md 2.2).
func configure_hierarchical(identifiers: PackedStringArray, allow_clear: bool = true) -> void:
	_hierarchical = true
	_hierarchy = GATagHierarchy.build_hierarchy(identifiers)
	_allow_clear = allow_clear
	_rebuild()


## Populates the popup with a flat list grouped one level by first dotted
## segment (every non-tag picker's mode -- tasks.md 2.3).
func configure_flat(identifiers: PackedStringArray, allow_clear: bool = true) -> void:
	_hierarchical = false
	_flat_identifiers = identifiers
	_allow_clear = allow_clear
	_rebuild()


func popup_search() -> void:
	popup_centered()
	if _search_edit != null:
		_search_edit.grab_focus()


func _on_search_changed(_text: String) -> void:
	_rebuild(_search_edit.text)


func _rebuild(query: String = "") -> void:
	if _tree == null:
		return
	if _clear_button != null:
		_clear_button.visible = _allow_clear
	_tree.clear()
	_rows.clear()
	var root := _tree.create_item()
	if _hierarchical:
		_add_hierarchy_rows(root, GATagHierarchy.filter(_hierarchy, query))
	else:
		var filtered_ids := GAPickerNavigation.filter_flat(_flat_identifiers, query)
		var groups := GAPickerNavigation.group_by_first_segment(filtered_ids)
		var group_names := groups.keys()
		group_names.sort()
		for group_name in group_names:
			var group_item := _tree.create_item(root)
			group_item.set_text(0, String(group_name))
			group_item.set_selectable(0, false)
			for identifier in groups[group_name]:
				var leaf := _tree.create_item(group_item)
				leaf.set_text(0, identifier)
				_rows.append({"full": identifier, "item": leaf})


func _add_hierarchy_rows(parent: TreeItem, node: Dictionary) -> void:
	for segment in GATagHierarchy.sorted_keys(node):
		var info: Dictionary = node[segment]
		var item := _tree.create_item(parent)
		var has_resource: bool = info["has_resource"]
		item.set_text(0, segment if has_resource else "%s (implicit)" % segment)
		item.set_tooltip_text(0, info["full"])
		if has_resource:
			_rows.append({"full": info["full"], "item": item})
		else:
			item.set_selectable(0, false)
			item.set_custom_color(0, Color(0.6, 0.6, 0.6))
		_add_hierarchy_rows(item, info["children"])


func _on_tree_item_activated() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	for row in _rows:
		if row["item"] == item:
			identifier_picked.emit(row["full"])
			hide()
			return


func _on_search_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var key_event: InputEventKey = event
	if key_event.keycode == KEY_ENTER or key_event.keycode == KEY_KP_ENTER:
		if _rows.size() == 1:
			identifier_picked.emit(_rows[0]["full"])
			hide()
		_search_edit.accept_event()
	elif key_event.keycode == KEY_ESCAPE:
		hide()
		_search_edit.accept_event()
	elif key_event.keycode == KEY_DOWN or key_event.keycode == KEY_UP \
			or key_event.keycode == KEY_HOME or key_event.keycode == KEY_END:
		_move_selection(key_event.keycode)
		_search_edit.accept_event()


func _move_selection(key: Key) -> void:
	if _rows.is_empty():
		return
	var current := -1
	var selected := _tree.get_selected()
	for i in range(_rows.size()):
		if _rows[i]["item"] == selected:
			current = i
			break
	var new_index := GAPickerNavigation.move(current, _rows.size(), key)
	if new_index >= 0 and new_index < _rows.size():
		var item: TreeItem = _rows[new_index]["item"]
		item.select(0)
		_tree.scroll_to_item(item)
