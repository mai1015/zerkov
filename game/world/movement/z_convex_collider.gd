class_name ZConvexCollider
extends RefCounted
## Bounded exact-integer convex solid support for authored sloping river banks.
## Compilation accepts only strictly convex, finite polygons. Runtime queries
## use the separating axes of the polygon AND the axis-aligned body. Rendering,
## physics-server state and floating point never participate in these queries.
const MAX_VERTICES: int = 16
const MAX_RAW: int = 256_000_000

static func compile_px(points: PackedVector2Array) -> Dictionary:
	if points.size() < 3 or points.size() > MAX_VERTICES: return {}
	var vertices: Array[Vector2i] = []
	for point: Vector2 in points:
		var value := ZWorldUnits.godot_to_canonical(point)
		if not value.ok: return {}
		var v: Vector2i = value.vector2i_value
		if absi(v.x) > MAX_RAW or absi(v.y) > MAX_RAW or vertices.has(v): return {}
		vertices.append(v)
	var area: int = 0
	for i in vertices.size():
		var a := vertices[i]; var b := vertices[(i+1)%vertices.size()]
		area += int(a.x)*int(b.y)-int(a.y)*int(b.x)
	if area == 0: return {}
	if area < 0: vertices.reverse()
	var planes: Array = []
	var lo := vertices[0]; var hi := vertices[0]
	for i in vertices.size():
		var a := vertices[i]; var b := vertices[(i+1)%vertices.size()]
		var nx: int = int(b.y)-a.y
		var ny: int = int(a.x)-b.x
		var divisor := _gcd(absi(nx), absi(ny))
		@warning_ignore("integer_division")
		nx = nx / divisor
		@warning_ignore("integer_division")
		ny = ny / divisor
		var bound := nx*int(a.x)+ny*int(a.y)
		for j in vertices.size():
			var v := vertices[j]
			var distance := nx*int(v.x)+ny*int(v.y)-bound
			if distance > 0 or (distance == 0 and j != i and j != (i+1)%vertices.size()): return {}
		planes.append([nx,ny,bound])
		lo = Vector2i(mini(lo.x,a.x),mini(lo.y,a.y))
		hi = Vector2i(maxi(hi.x,a.x),maxi(hi.y,a.y))
	# The box's own normals complete SAT. Polygon edge normals alone would
	# overestimate the Minkowski sum around extreme vertices.
	planes.append_array([[1,0,int(hi.x)],[-1,0,-int(lo.x)],[0,1,int(hi.y)],[0,-1,-int(lo.y)]])
	return {"min":lo,"max":hi,"vertices":vertices,"planes":planes}

static func overlaps(record: Dictionary, at: Vector2i, half: Vector2i) -> bool:
	for plane: Array in record.planes:
		var support: int = absi(plane[0])*int(half.x)+absi(plane[1])*int(half.y)
		if int(plane[0])*int(at.x)+int(plane[1])*int(at.y) >= int(plane[2])+support:
			return false
	return true

## Integer positions immediately outside the open forbidden axis interval.
## Returns empty when the orthogonal projection does not overlap. Touch is free.
static func axis_limits(record: Dictionary, at: Vector2i, half: Vector2i, x_axis: bool) -> Array:
	var lower: Array[int] = [-4_000_000_000,1]
	var upper: Array[int] = [4_000_000_000,1]
	for plane: Array in record.planes:
		var n: int = plane[0] if x_axis else plane[1]
		var other: int = plane[1] if x_axis else plane[0]
		var fixed: int = at.y if x_axis else at.x
		var h: int = int(plane[2])+absi(plane[0])*int(half.x)+absi(plane[1])*int(half.y)-other*fixed
		if n == 0:
			if h <= 0: return []
		elif n > 0:
			if _compare(h,n,upper[0],upper[1]) < 0: upper=[h,n]
		else:
			if _compare(-h,-n,lower[0],lower[1]) > 0: lower=[-h,-n]
	# Compare the real interval BEFORE rounding. A sub-microunit interval still
	# blocks a sweep; touching at one point does not. Cross multiplication can
	# overflow for large canonical normals, so use exact continued fractions.
	if _compare(lower[0],lower[1],upper[0],upper[1]) >= 0: return []
	return [_floor_div(lower[0],lower[1]),_ceil_div(upper[0],upper[1])]

static func _compare(a: int, b: int, c: int, d: int) -> int:
	var orientation: int = 1
	while true:
		var qa := _floor_div(a,b); var qc := _floor_div(c,d)
		if qa != qc: return orientation * (-1 if qa < qc else 1)
		var ra := a-qa*b; var rc := c-qc*d
		if ra == 0 or rc == 0:
			return 0 if ra == rc else orientation * (-1 if ra == 0 else 1)
		a=b; b=ra; c=d; d=rc; orientation=-orientation
	return 0

static func _gcd(a: int, b: int) -> int:
	while b != 0:
		var next := a % b; a=b; b=next
	return a

static func _floor_div(a: int, b: int) -> int:
	@warning_ignore("integer_division")
	var q: int = a/b
	return q-1 if a<0 and a%b != 0 else q

static func _ceil_div(a: int, b: int) -> int:
	return -_floor_div(-a,b)
