class_name LocalCharacterRuntime
extends CharacterUIRuntime
## Reuses the accepted workspace; only root-selected level container mapping differs.
func _init() -> void:
	_controller = LocalInventoryController.new()
