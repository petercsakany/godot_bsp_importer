@tool
extends RefCounted
## Read-only Raven RBSP v1 reader. Coordinates remain in original map units.
## Layout reference: JACoders/OpenJK code/qcommon/qfiles.h.
## No rendering, texture loading, or entity spawning is performed here.

const NAMES = ["entities", "shaders", "planes", "nodes", "leaves", "leaf_surfaces", "leaf_brushes", "models", "brushes", "brush_sides", "vertices", "indices", "fogs", "surfaces", "lightmaps", "light_grid", "visibility", "light_array"]
const STRIDES = [0, 72, 16, 36, 48, 4, 4, 40, 12, 12, 80, 4, 72, 148, 49152, 30, 0, 2]

var errors: Array[String] = []
var warnings: Array[String] = []
var data: Dictionary = {}

func read_bsp(path: String) -> Dictionary:
	errors.clear()
	warnings.clear()
	data = {"path": path, "lumps": [], "records": {}}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _fail("Cannot open BSP: %s (%s)" % [path, error_string(FileAccess.get_open_error())])
	file.big_endian = false
	return _read_stream(file)

## ZIPReader returns decompressed bytes. Parse them without extracting a file.
func read_bytes(bytes: PackedByteArray, source: String) -> Dictionary:
	errors.clear()
	warnings.clear()
	data = {"path": source, "lumps": [], "records": {}}
	return _read_stream(MemoryReader.new(bytes))

class MemoryReader extends RefCounted:
	var stream := StreamPeerBuffer.new()
	func _init(bytes: PackedByteArray) -> void:
		stream.data_array = bytes
		stream.big_endian = false
	func get_length() -> int:
		return stream.get_size()
	func get_position() -> int:
		return stream.get_position()
	func seek(position: int) -> void:
		stream.seek(position)
	func get_32() -> int:
		return stream.get_u32()
	func get_float() -> float:
		return stream.get_float()
	func get_buffer(size: int) -> PackedByteArray:
		return stream.get_data(size)[1]
	func close() -> void:
		pass

func _read_stream(file) -> Dictionary:
	var length: int = file.get_length()
	if length < 152:
		return _fail("Truncated header: RBSP v1 requires 152 bytes")
	var magic: String = file.get_buffer(4).get_string_from_ascii()
	var version: int = file.get_32()
	data.merge({"magic": magic, "version": version, "file_bytes": length})
	if magic != "RBSP" or version != 1:
		return _fail("Unsupported BSP: %s version %d; expected Raven RBSP version 1" % [magic, version])
	for i in NAMES.size():
		var offset: int = file.get_32()
		var size: int = file.get_32()
		if offset > length or size > length - offset or (size > 0 and offset < 152):
			return _fail("Out-of-file lump: " + NAMES[i])
		if STRIDES[i] > 0 and size % STRIDES[i] != 0:
			return _fail("Invalid record length for " + NAMES[i])
		data.lumps.append({"name": NAMES[i], "offset": offset, "bytes": size, "stride": STRIDES[i], "count": int(size / STRIDES[i]) if STRIDES[i] else -1})
	for i in data.lumps.size():
		var a: Dictionary = data.lumps[i]
		for j in range(i):
			var b: Dictionary = data.lumps[j]
			if a.bytes > 0 and b.bytes > 0 and a.offset < b.offset + b.bytes and b.offset < a.offset + a.bytes:
				return _fail("Overlapping lumps: %s / %s" % [a.name, b.name])
	# Seek each section, then stream its fixed-size records rather than reading the whole BSP.
	for lump in data.lumps:
		file.seek(lump.offset)
		var records: Array = []
		match lump.name:
			"entities":
				data.entity_text = _text(file.get_buffer(lump.bytes))
			"lightmaps", "light_grid", "light_array":
				continue # Directory validated; payload decoding is a later stage.
			"visibility":
				if lump.bytes == 0:
					data.visibility = {}
				elif lump.bytes < 8:
					return _fail("Truncated visibility header")
				else:
					var clusters := _int(file)
					var row_bytes := _int(file)
					if clusters < 0 or row_bytes < 0 or clusters * row_bytes != lump.bytes - 8:
						return _fail("Invalid visibility bitset size")
					data.visibility = {"clusters": clusters, "bytes_per_cluster": row_bytes}
			_:
				for index in lump.count:
					var record := _record(file, lump.name)
					records.append(record)
				data.records[lump.name] = records
	file.close()
	_validate_references()
	data["ok"] = errors.is_empty()
	data["errors"] = errors.duplicate()
	data["warnings"] = warnings.duplicate()
	return data

func _record(f, kind: String) -> Dictionary:
	match kind:
		"shaders":
			return {"name": _text(f.get_buffer(64)), "surface_flags": _int(f), "content_flags": _int(f)}
		"planes":
			return {"normal": _floats(f, 3), "distance": f.get_float()}
		"nodes":
			return {"plane": _int(f), "children": _ints(f, 2), "mins": _ints(f, 3), "maxs": _ints(f, 3)}
		"leaves":
			return {"cluster": _int(f), "area": _int(f), "mins": _ints(f, 3), "maxs": _ints(f, 3), "first_surface": _int(f), "num_surfaces": _int(f), "first_brush": _int(f), "num_brushes": _int(f)}
		"models":
			return {"mins": _floats(f, 3), "maxs": _floats(f, 3), "first_surface": _int(f), "num_surfaces": _int(f), "first_brush": _int(f), "num_brushes": _int(f)}
		"brushes":
			return {"first_side": _int(f), "num_sides": _int(f), "shader": _int(f)}
		"brush_sides":
			return {"plane": _int(f), "shader": _int(f), "surface": _int(f)}
		"vertices":
			return {"position": _floats(f, 3), "uv": _floats(f, 2), "lightmap_uv": _floats(f, 8, true), "normal": _floats(f, 3), "colors": Array(f.get_buffer(16))}
		"fogs":
			return {"shader_name": _text(f.get_buffer(64)), "brush": _int(f), "visible_side": _int(f)}
		"surfaces":
			return {"shader": _int(f), "fog": _int(f), "type": _int(f), "first_vertex": _int(f), "num_vertices": _int(f), "first_index": _int(f), "num_indices": _int(f), "lightmap_styles": Array(f.get_buffer(4)), "vertex_styles": Array(f.get_buffer(4)), "lightmap_numbers": _ints(f, 4), "lightmap_x": _ints(f, 4), "lightmap_y": _ints(f, 4), "lightmap_width": _int(f), "lightmap_height": _int(f), "lightmap_origin": _floats(f, 3), "lightmap_vectors": _floats(f, 9), "patch_width": _int(f), "patch_height": _int(f)}
		_:
			return {"value": _int(f)}

func _validate_references() -> void:
	var r: Dictionary = data.records
	for b in r.brushes:
		_range(b.first_side, b.num_sides, r.brush_sides.size(), "brush sides")
		_range(b.shader, 1, r.shaders.size(), "brush shader")
	for s in r.brush_sides:
		_range(s.plane, 1, r.planes.size(), "brush plane")
		_range(s.shader, 1, r.shaders.size(), "side shader")
		if s.surface != -1:
			_range(s.surface, 1, r.surfaces.size(), "side surface")
	for m in r.models:
		_range(m.first_surface, m.num_surfaces, r.surfaces.size(), "model surfaces")
		_range(m.first_brush, m.num_brushes, r.brushes.size(), "model brushes")
	for leaf in r.leaves:
		_range(leaf.first_surface, leaf.num_surfaces, r.leaf_surfaces.size(), "leaf surfaces")
		_range(leaf.first_brush, leaf.num_brushes, r.leaf_brushes.size(), "leaf brushes")
	for ref in r.leaf_surfaces:
		_range(ref.value, 1, r.surfaces.size(), "leaf surface reference")
	for ref in r.leaf_brushes:
		_range(ref.value, 1, r.brushes.size(), "leaf brush reference")
	for node in r.nodes:
		_range(node.plane, 1, r.planes.size(), "node plane")
		for child in node.children:
			_range(child if child >= 0 else -child - 1, 1, r.nodes.size() if child >= 0 else r.leaves.size(), "node child")
	for i in r.surfaces.size():
		var s: Dictionary = r.surfaces[i]
		_range(s.shader, 1, r.shaders.size(), "surface shader")
		if s.fog != -1:
			_range(s.fog, 1, r.fogs.size(), "surface fog")
		_range(s.first_vertex, s.num_vertices, r.vertices.size(), "surface vertices")
		if _range(s.first_index, s.num_indices, r.indices.size(), "surface indices"):
			for j in range(s.first_index, s.first_index + s.num_indices):
				_range(r.indices[j].value, 1, s.num_vertices, "surface-local index")
		if s.type == 2:
			if s.patch_width < 3 or s.patch_height < 3 or s.patch_width % 2 == 0 or s.patch_height % 2 == 0 or s.patch_width * s.patch_height != s.num_vertices:
				errors.append("Invalid patch control grid on surface %d" % i)
		elif s.type not in [1, 3, 4]:
			errors.append("Unknown surface type %d on surface %d" % [s.type, i])
		if s.type in [1, 3] and s.num_indices % 3 != 0:
			errors.append("Incomplete triangles on surface %d" % i)

func summary() -> Dictionary:
	var result := data.duplicate()
	result.erase("records")
	result.erase("entity_text")
	if not data.has("records") or not data.records.has("surfaces"):
		return result
	var counts := {"planar": 0, "patch": 0, "triangles": 0, "flare": 0, "unknown": 0}
	var patches: Array = []
	for i in data.records.surfaces.size():
		var s: Dictionary = data.records.surfaces[i]
		var type_name: String = {1: "planar", 2: "patch", 3: "triangles", 4: "flare"}.get(s.type, "unknown")
		counts[type_name] += 1
		if s.type == 2:
			var patch := {"surface": i, "width": s.patch_width, "height": s.patch_height, "control_points": s.num_vertices, "first_vertex": s.first_vertex}
			if s.shader >= 0 and s.shader < data.records.shaders.size():
				patch["shader"] = data.records.shaders[s.shader].name
			if s.first_vertex >= 0 and s.num_vertices > 0 and s.first_vertex + s.num_vertices <= data.records.vertices.size():
				patch["first_control_point"] = data.records.vertices[s.first_vertex]
			patches.append(patch)
	result["surface_types"] = counts
	result["patches"] = patches
	result["shaders"] = data.records.shaders
	result["models"] = data.records.models
	result["sample_vertices"] = data.records.vertices.slice(0, 3)
	result["lighting_payloads_decoded"] = false
	result["entity_text_bytes"] = data.get("entity_text", "").length()
	return result

func _range(first: int, count: int, total: int, label: String) -> bool:
	if first < 0 or count < 0 or first > total or count > total - first:
		errors.append("Invalid %s range: %d + %d / %d" % [label, first, count, total])
		return false
	return true

func _int(f) -> int:
	var value: int = f.get_32()
	return value - 4294967296 if value >= 2147483648 else value

func _ints(f, count: int) -> Array:
	var values: Array = []
	for i in count:
		values.append(_int(f))
	return values

func _floats(f, count: int, lighting: bool = false) -> Array:
	var values: Array = []
	for i in count:
		var value: float = f.get_float()
		if not is_finite(value):
			if lighting:
				warnings.append("Non-finite lightmap UV at byte %d; preserved in memory, lighting import needs handling" % (f.get_position() - 4))
			else:
				errors.append("Non-finite float at byte %d" % (f.get_position() - 4))
		values.append(value)
	return values

func _text(bytes: PackedByteArray) -> String:
	var end := bytes.find(0)
	return (bytes.slice(0, end) if end >= 0 else bytes).get_string_from_utf8()

func _fail(message: String) -> Dictionary:
	errors.append(message)
	data["ok"] = false
	data["errors"] = errors.duplicate()
	data["warnings"] = warnings.duplicate()
	return data
