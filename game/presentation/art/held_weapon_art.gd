class_name ZHeldWeaponArt
extends Resource
## Authored visual binding, not an equip rule or combat definition.
@export var definition_id: String = ""
@export var texture: Texture2D
@export var includes_arms: bool = false
@export var grip: Vector2 = Vector2.ZERO
@export var shoulder: Vector2 = Vector2.ZERO
@export var muzzle: Vector2 = Vector2.ZERO
@export var pixel_scale: float = 1.0
@export var attack_hand: PackedVector2Array = PackedVector2Array()
@export var attack_degrees: PackedFloat32Array = PackedFloat32Array()

## Full-canvas source attack, aligned with the body/arms rather than a grip.
@export var attack_frames: SpriteFrames
@export var attack_pivot: Vector2 = Vector2(32, 48)
@export var muzzle_fx_origin: Vector2 = Vector2(27, 12)
