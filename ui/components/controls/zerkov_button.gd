@tool
class_name ZerkovButton
extends CommonButton

const Adapter = preload("res://ui/theme/theme_adapter.gd")
const VARIATIONS := {
	"secondary": &"ZButton", "primary": &"ZPrimaryButton",
	"flat": &"ZFlatButton", "hit": &"ZHitButton",
	"destructive": &"ZDestructiveButton", "dialog_secondary": &"ZDialogSecondary",
}

@export_enum("secondary", "primary", "flat", "hit", "destructive", "dialog_secondary") var variant: String = "secondary":
	set(value):
		variant = value
		theme_type_variation = VARIATIONS.get(value, &"ZButton")

func _ready() -> void:
	super._ready()
	theme = Adapter.adapt_theme(theme)
	Adapter.adapt_control(self)
