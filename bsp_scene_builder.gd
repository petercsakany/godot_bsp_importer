@tool
extends RefCounted
## Geometry-only RBSP preview. Matches FuncGodot's axes and 1/32 scale.
const SCALE := 1.0 / 32.0
const SURF_NODRAW := 0x00200000
var stats: Dictionary

func build(data: Dictionary, subdivisions: int = 8) -> Node3D:
	if not data.get("ok", false) or subdivisions < 1 or subdivisions > 64:
		return null
	stats = {"surfaces": 0, "patches": 0, "skipped_nodraw": 0, "skipped_unsupported": 0, "triangles": 0, "degenerate_triangles": 0}
	var root := Node3D.new()
	root.name = "BSPPreview"
	var records: Dictionary = data.records
	# Keep BSP models separate; entity transforms/behaviour are a later stage.
	for model_id in records.models.size():
		var model: Dictionary = records.models[model_id]
		var groups := {}
		for sid in range(model.first_surface, model.first_surface + model.num_surfaces):
			var surface: Dictionary = records.surfaces[sid]
			var shader: Dictionary = records.shaders[surface.shader]
			if int(shader.surface_flags) & SURF_NODRAW:
				stats.skipped_nodraw += 1
				continue
			if surface.type not in [1, 2, 3]:
				stats.skipped_unsupported += 1
				continue
			if not groups.has(surface.shader):
				var tool := SurfaceTool.new()
				tool.begin(Mesh.PRIMITIVE_TRIANGLES)
				groups[surface.shader] = tool
			var tool: SurfaceTool = groups[surface.shader]
			if surface.type == 2:
				_patch(tool, surface, records.vertices, subdivisions)
				stats.patches += 1
			else:
				for i in range(surface.first_index, surface.first_index + surface.num_indices, 3):
					var triangle: Array = []
					for k in 3:
						triangle.append(_vertex(records.vertices[surface.first_vertex + records.indices[i + k].value]))
					_triangle(tool, triangle)
			stats.surfaces += 1
		for shader_id in groups:
			var tool: SurfaceTool = groups[shader_id]
			tool.index()
			var mesh := tool.commit()
			if mesh == null or mesh.get_surface_count() == 0:
				continue
			var material := StandardMaterial3D.new()
			material.albedo_color = Color(0.68, 0.72, 0.77)
			material.roughness = 0.9
			mesh.surface_set_material(0, material)
			var instance := MeshInstance3D.new()
			instance.name = "Model_%d_Material_%d" % [model_id, shader_id]
			instance.mesh = mesh
			instance.set_meta("bsp_shader", records.shaders[shader_id].name)
			instance.set_meta("bsp_model", model_id)
			root.add_child(instance)
			instance.owner = root
	var environment := WorldEnvironment.new()
	environment.name = "PreviewEnvironment"
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.10, 0.12, 0.15)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.65
	root.add_child(environment)
	environment.owner = root
	var light := DirectionalLight3D.new()
	light.name = "PreviewLight"
	light.rotation_degrees = Vector3(-55, -35, 0)
	root.add_child(light)
	light.owner = root
	root.set_meta("bsp_source", data.path)
	root.set_meta("build_stats", stats)
	return root

func _vertex(v: Dictionary) -> Dictionary:
	return {"p": _axis(v.position) * SCALE, "n": _axis(v.normal).normalized(), "uv": Vector2(v.uv[0], v.uv[1])}

func _axis(v: Array) -> Vector3:
	return Vector3(v[1], v[2], v[0])

func _triangle(tool: SurfaceTool, t: Array) -> void:
	var cross: Vector3 = (t[1].p - t[0].p).cross(t[2].p - t[0].p)
	if cross.length_squared() < 1e-16:
		stats.degenerate_triangles += 1
		return
	# Godot front faces use clockwise winding. Orient against outward normals.
	if cross.dot(t[0].n + t[1].n + t[2].n) > 0:
		var swap: Dictionary = t[1]
		t[1] = t[2]
		t[2] = swap
	for v in t:
		tool.set_normal(v.n)
		tool.set_uv(v.uv)
		tool.add_vertex(v.p)
	stats.triangles += 1

func _patch(tool: SurfaceTool, s: Dictionary, vertices: Array, steps: int) -> void:
	# Overlapping 3x3 quadratic spans, not a single high-degree Bezier surface.
	for y in range(0, s.patch_height - 2, 2):
		for x in range(0, s.patch_width - 2, 2):
			var controls: Array = []
			for row in 3:
				for col in 3:
					controls.append(_vertex(vertices[s.first_vertex + (y + row) * s.patch_width + x + col]))
			var grid: Array = []
			for row in range(steps + 1):
				for col in range(steps + 1):
					grid.append(_sample(controls, float(col) / steps, float(row) / steps))
			for row in steps:
				for col in steps:
					var a := row * (steps + 1) + col
					var b := a + steps + 1
					_triangle(tool, [grid[a], grid[a + 1], grid[b]])
					_triangle(tool, [grid[a + 1], grid[b + 1], grid[b]])

func _sample(c: Array, u: float, v: float) -> Dictionary:
	var bu := Vector3((1-u)*(1-u), 2*u*(1-u), u*u)
	var bv := Vector3((1-v)*(1-v), 2*v*(1-v), v*v)
	var du := Vector3(-2*(1-u), 2-4*u, 2*u)
	var dv := Vector3(-2*(1-v), 2-4*v, 2*v)
	var p := Vector3.ZERO
	var n := Vector3.ZERO
	var tangent_u := Vector3.ZERO
	var tangent_v := Vector3.ZERO
	var uv := Vector2.ZERO
	for row in 3:
		for col in 3:
			var point: Dictionary = c[row * 3 + col]
			var weight := bu[col] * bv[row]
			p += point.p * weight
			n += point.n * weight
			uv += point.uv * weight
			tangent_u += point.p * du[col] * bv[row]
			tangent_v += point.p * bu[col] * dv[row]
	var normal := tangent_u.cross(tangent_v).normalized()
	if normal.is_zero_approx():
		normal = n.normalized()
	elif normal.dot(n) < 0:
		normal = -normal
	return {"p": p, "n": normal, "uv": uv}
