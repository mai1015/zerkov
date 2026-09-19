extends Control
var player: Node2D
var sun: Resource
var message: String = ""
var hint_text: String = ""
var hint_screen := Vector2.ZERO
var overview := true
var font: Font
func _ready() -> void:
	font=ThemeDB.fallback_font
func text(at: Vector2, value: String, size_px: int, color: Color) -> void:
	draw_string(font,at,value,HORIZONTAL_ALIGNMENT_LEFT,-1,size_px,color)
func _draw() -> void:
	if font==null:return
	var s:=get_viewport_rect().size
	var ink:=Color(.89,.88,.80)
	var faint:=Color(.65,.70,.66)
	var panel:=Color(.045,.065,.065,.83)
	draw_rect(Rect2(24,24,336,69),panel)
	draw_line(Vector2(24,24),Vector2(360,24),Color(.6,.62,.48),2)
	text(Vector2(40,50),"P I N E C R E S T   C O A S T",17,ink)
	text(Vector2(40,77),"ROADSIDE COMPOUND  /  ENVIRONMENT STUDY",12,faint)
	# A schematic map, not an invented live-raid radar feed.
	var box:=Rect2(s.x-214,24,190,146)
	draw_rect(box,panel)
	draw_rect(box.grow(-7),Color(.35,.40,.34,.8),false,1)
	draw_rect(Rect2(box.position+Vector2(159,8),Vector2(23,130)),Color(.16,.31,.34,.9))
	draw_line(box.position+Vector2(59,11),box.position+Vector2(59,136),Color(.6,.57,.5,.8),5)
	draw_rect(Rect2(box.position+Vector2(87,33),Vector2(39,33)),Color(.5,.43,.31,.8),false,2)
	text(box.position+Vector2(9,20),"N",11,ink)
	if is_instance_valid(player):
		var dot:=box.position+Vector2(8,8)+player.global_position/Vector2(1792,1024)*Vector2(174,130)
		draw_circle(dot,3.8,Color(.89,.80,.54))
	var base:=Vector2(24,s.y-90)
	draw_rect(Rect2(base,Vector2(830,66)),panel)
	text(base+Vector2(16,23),"WASD  Move     SHIFT  Sprint     F  Interact     F2  Camera     TAB  Hide UI",15,ink)
	var settings:="H  Cast shadows     J  Contact shadows     R  Sun direction     C  Collision"
	if sun!=null:
		settings += "   |   "+str(roundi(sun.direction_degrees))+" deg"
	text(base+Vector2(16,47),settings,13,faint)
	if not hint_text.is_empty():
		var pos:=hint_screen.clamp(Vector2(32,178),s-Vector2(302,110))
		draw_rect(Rect2(pos-Vector2(8,23),Vector2(270,34)),panel)
		text(pos,"[F]  "+hint_text,17,ink)
	if not message.is_empty():
		draw_rect(Rect2(24,108,720,33),panel)
		text(Vector2(39,131),message,14,ink)
