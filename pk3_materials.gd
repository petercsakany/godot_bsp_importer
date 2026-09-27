@tool
extends RefCounted
## Basic image/material translation, not a full id Tech shader interpreter.
var archives: Array = []
var entries := {}
var shaders := {}
var report: Array = []
var cache := {}
var texture_cache := {}
var errors: Array[String] = []

func mount(base: String) -> Error:
	close()
	entries.clear()
	shaders.clear()
	cache.clear()
	texture_cache.clear()
	report.clear()
	errors.clear()
	var files := DirAccess.get_files_at(base)
	files.sort()
	for filename in files:
		if filename.get_extension().to_lower() != "pk3":
			continue
		var archive = preload("res://addons/jka_bsp/pk3_archive.gd").new()
		var error: Error = archive.open(base.path_join(filename))
		if error != OK:
			errors.append(archive.error_message)
			close()
			return error
		archives.append(archive)
		# Later alphabetic archives override earlier ones, including patch assets.
		for entry in archive.files():
			entries[entry] = archives.size() - 1
	if archives.is_empty():
		errors.append("No PK3 archives found in " + base)
		return ERR_FILE_NOT_FOUND
	var shader_files: Array = entries.keys()
	shader_files.sort()
	for path in shader_files:
		if path.ends_with(".shader") and (path.begins_with("shaders/") or path.begins_with("scripts/")):
			var archive = archives[entries[path]]
			parse_shader_text(archive.read_file(path).get_string_from_utf8(), archive.archive_path + "::" + path)
	return OK

func close() -> void:
	for archive in archives:
		archive.close()
	archives.clear()

func parse_shader_text(text: String, source: String) -> void:
	# Tokenize comments, quoted paths, newlines, and braces independently.
	var regex := RegEx.new()
	regex.compile('(?s)/\\*.*?\\*/|//[^\\n]*|"[^"\\n]*"|[{}\\n]|[^\\s{}"]+')
	var tokens: Array[String] = []
	for hit in regex.search_all(text):
		var token := hit.get_string()
		if token.begins_with("//") or token.begins_with("/*"):
			continue
		tokens.append(token.trim_prefix('"').trim_suffix('"'))
	var name := ""
	var depth := 0
	var definition := {}
	var stage: Array = []
	var line: Array[String] = []
	for token in tokens:
		if token in ["\n", "{", "}"]:
			if not line.is_empty():
				if depth == 0:
					name = line[0].to_lower()
				elif depth == 1:
					definition.directives.append(line.duplicate())
				elif depth == 2:
					stage.append(line.duplicate())
				line.clear()
			if token == "{":
				depth += 1
				if depth == 1:
					definition = {"source": source, "directives": [], "stages": []}
				elif depth == 2:
					stage = []
			elif token == "}":
				if depth == 2:
					definition.stages.append(stage)
				elif depth == 1 and not name.is_empty():
					shaders[name] = definition
				depth = maxi(0, depth - 1)
		else:
			line.append(token)

func _directive(lines: Array, key: String) -> Array:
	for line in lines:
		if not line.is_empty() and str(line[0]).to_lower() == key:
			return line.slice(1)
	return []

func material(name: String) -> StandardMaterial3D:
	name = name.to_lower()
	if cache.has(name):
		return cache[name]
	var material := StandardMaterial3D.new()
	material.resource_name = name
	material.roughness = 0.9
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	material.texture_repeat = true
	var info := {"material": name, "kind": "image", "image": "", "archive": "", "fallback": "", "limitations": [], "status": "missing"}
	var candidates: Array = []
	var selected_stage: Array = []
	var definition: Dictionary = shaders.get(name, {})
	if not definition.is_empty():
		info.kind = "shader"
		info["shader_source"] = definition.source
		var editor := _directive(definition.directives, "qer_editorimage")
		var ranked: Array = []
		for stage in definition.stages:
			var image := _directive(stage, "map")
			if image.is_empty():
				image = _directive(stage, "clampmap")
			if image.is_empty() or str(image[0]).begins_with("$"):
				continue
			var score := 10
			if not _directive(stage, "tcgen").is_empty():
				score -= 30
			if not _directive(stage, "tcmod").is_empty():
				score -= 20
			var blend := " ".join(_directive(stage, "blendfunc")).to_lower()
			if blend in ["add", "gl_one gl_one"]:
				score -= 20
			if str(image[0]).get_basename() == name.get_basename():
				score += 10
			if not editor.is_empty() and str(image[0]).get_basename() == str(editor[0]).get_basename():
				score += 10
			ranked.append({"score": score, "path": image[0], "stage": stage})
			ranked.sort_custom(func(a, b): return a.score > b.score)
		for candidate in ranked:
			candidates.append({"path": candidate.path, "stage": candidate.stage, "fallback": ""})
		if not editor.is_empty():
			candidates.append({"path": editor[0], "stage": [], "fallback": "editor image"})
		if definition.stages.size() > 1:
			info.limitations.append("Only one base image used; additional shader stages are not composited")
		for stage in definition.stages:
			for key in ["tcmod", "tcgen", "animmap", "oneshotanimmap", "rgbgen", "alphagen", "alphafunc"]:
				var values := _directive(stage, key)
				if not values.is_empty() and not (key == "rgbgen" and str(values[0]).to_lower() == "identity"):
					var note: String = key + " " + " ".join(values)
					if note not in info.limitations:
						info.limitations.append(note)
		if not _directive(definition.directives, "skyparms").is_empty():
			info.limitations.append("Sky uses a flat editor-image fallback, not a skybox")
		if not _directive(definition.directives, "deformvertexes").is_empty():
			info.limitations.append("Vertex deformation is not translated")
		var cull := _directive(definition.directives, "cull")
		if not cull.is_empty() and str(cull[0]).to_lower() in ["none", "disable", "twosided"]:
			material.cull_mode = BaseMaterial3D.CULL_DISABLED
	candidates.append({"path": name, "stage": [], "fallback": "same-name image" if not definition.is_empty() else ""})
	for candidate in candidates:
		var image_path := find_image(candidate.path)
		if image_path.is_empty():
			continue
		var texture := load_texture(image_path)
		if texture == null:
			continue
		material.albedo_texture = texture
		info.image = image_path
		info.archive = archives[entries[image_path]].archive_path
		info.fallback = candidate.fallback
		info.status = "textured"
		selected_stage = candidate.stage
		break
	if material.albedo_texture == null:
		material.albedo_color = Color(1, 0, 1)
		info.limitations.append("No decodable image found; magenta fallback")
	else:
		material.albedo_color = Color.WHITE
		if not _directive(selected_stage, "clampmap").is_empty():
			material.texture_repeat = false
		# Alpha blend only when declared as transparent, or a single alpha stage.
		var blend := " ".join(_directive(selected_stage, "blendfunc")).to_lower()
		var transparent := false
		if not definition.is_empty():
			for line in definition.directives:
				if line.size() > 1 and str(line[0]).to_lower() == "surfaceparm" and str(line[1]).to_lower() == "trans":
					transparent = true
			if (definition.stages.size() == 1 or definition.stages.find(selected_stage) == 0) and blend in ["blend", "gl_src_alpha gl_one_minus_src_alpha"]:
				transparent = true
		if transparent:
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			info.limitations.append("Transparency approximated using base image alpha")
			if material.albedo_texture.get_image().detect_alpha() == Image.ALPHA_NONE:
				material.albedo_color.a = 0.35
				info.limitations.append("No image alpha: using preview opacity 0.35 for declared transparent material")
	cache[name] = material
	report.append(info)
	return material

func find_image(path: String) -> String:
	path = path.replace("\\", "/").to_lower()
	if entries.has(path) and path.get_extension() in ["tga", "jpg", "jpeg", "png"]:
		return path
	var base := path.get_basename() if path.get_extension() in ["tga", "jpg", "jpeg", "png"] else path
	for extension in ["tga", "jpg", "png", "jpeg"]:
		if entries.has(base + "." + extension):
			return base + "." + extension
	return ""

func load_texture(path: String) -> ImageTexture:
	if texture_cache.has(path):
		return texture_cache[path]
	var bytes: PackedByteArray = archives[entries[path]].read_file(path)
	var image := Image.new()
	var error := ERR_FILE_UNRECOGNIZED
	match path.get_extension():
		"tga": error = image.load_tga_from_buffer(bytes)
		"jpg", "jpeg": error = image.load_jpg_from_buffer(bytes)
		"png": error = image.load_png_from_buffer(bytes)
	if error != OK:
		errors.append("Image decode failed: " + path)
		return null
	image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	texture.resource_name = path
	texture_cache[path] = texture
	return texture
