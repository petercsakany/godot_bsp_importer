@tool
extends Node3D
## Add a JkaBspMap, choose a base folder and map, then click Build Map.
## Generated geometry is saved with the scene. Runtime never opens game archives.
@export_global_dir var base_directory := "C:/Program Files (x86)/Steam/steamapps/common/Jedi Academy/GameData/base":
	set(value):
		base_directory = value
		if Engine.is_editor_hint() and is_inside_tree():
			queue_scan()
## Optional: restrict map choices to one PK3. Empty scans all PK3s in Base Directory.
@export_global_file("*.pk3") var map_archive := "":
	set(value):
		map_archive = value
		if Engine.is_editor_hint() and is_inside_tree():
			queue_scan()
@export var bsp_map := "maps/mp/duel4.bsp"
@export var load_textures := true
@export_range(1, 32, 1) var curve_subdivisions := 8
@export_range(1.0, 256.0, 1.0) var map_units_per_godot_unit := 32.0
@export var preview_lighting := true
@export_multiline var status := "Choose a map, then Build Map."
var available_maps := PackedStringArray()
var map_sources := {}
var material_report: Array = []
var _scan_queued := false

func _ready() -> void:
	if Engine.is_editor_hint():
		queue_scan()

func queue_scan() -> void:
	if not _scan_queued:
		_scan_queued = true
		_scan_deferred.call_deferred()

func _scan_deferred() -> void:
	_scan_queued = false
	if is_inside_tree():
		scan_maps()

func _validate_property(property: Dictionary) -> void:
	if property.name == "bsp_map" and not available_maps.is_empty():
		property.hint = PROPERTY_HINT_ENUM
		var choices := available_maps.duplicate()
		if not bsp_map.is_empty() and bsp_map not in choices:
			choices.append(bsp_map)
		property.hint_string = ",".join(choices)
	if property.name == "status":
		property.usage |= PROPERTY_USAGE_READ_ONLY

func scan_maps() -> bool:
	available_maps.clear()
	map_sources.clear()
	var paths := PackedStringArray()
	if not map_archive.is_empty():
		paths.append(map_archive)
	elif DirAccess.dir_exists_absolute(base_directory):
		var filenames := DirAccess.get_files_at(base_directory)
		filenames.sort()
		for filename in filenames:
			if filename.get_extension().to_lower() == "pk3":
				paths.append(base_directory.path_join(filename))
	var failures := PackedStringArray()
	for path in paths:
		var archive = preload("res://addons/jka_bsp/pk3_archive.gd").new()
		if archive.open(path) != OK:
			failures.append(archive.error_message)
			continue
		for entry in archive.files(".bsp"):
			map_sources[entry] = path
		archive.close()
	available_maps = PackedStringArray(map_sources.keys())
	available_maps.sort()
	status = "%d maps found." % available_maps.size()
	if paths.is_empty():
		status = "No PK3 files found. Check Base Directory or Map Archive."
	if not failures.is_empty():
		status += "\n" + "\n".join(failures)
	notify_property_list_changed()
	return not available_maps.is_empty() and failures.is_empty()

## Builds off-tree; existing scene content is replaced only after a successful build.
func create_map() -> Node3D:
	if not scan_maps() or not map_sources.has(bsp_map):
		status = "Build failed: selected BSP is unavailable. Check the folder/archive and refresh maps."
		notify_property_list_changed()
		return null
	var archive = preload("res://addons/jka_bsp/pk3_archive.gd").new()
	if archive.open(map_sources[bsp_map]) != OK:
		status = archive.error_message
		return null
	var data: Dictionary = archive.read_bsp(bsp_map)
	archive.close()
	if not data.ok:
		status = "Build failed: " + str(data.errors)
		notify_property_list_changed()
		return null
	var builder = preload("res://addons/jka_bsp/bsp_scene_builder.gd").new()
	var generated: Node3D = builder.build(data, curve_subdivisions)
	if generated == null:
		status = "Geometry generation failed."
		return null
	material_report.clear()
	var missing := 0
	if load_textures:
		var materials = preload("res://addons/jka_bsp/pk3_materials.gd").new()
		if materials.mount(base_directory) != OK:
			status = "Texture archive loading failed: " + str(materials.errors)
			generated.free()
			notify_property_list_changed()
			return null
		for child in generated.get_children():
			if child is MeshInstance3D:
				child.mesh.surface_set_material(0, materials.material(child.get_meta("bsp_shader")))
		material_report = materials.report.duplicate(true)
		for item in material_report:
			if item.status != "textured":
				missing += 1
		materials.close()
	if not preview_lighting:
		for child in generated.get_children():
			if child is WorldEnvironment or child is Light3D:
				generated.remove_child(child)
				child.free()
	generated.name = "MapGeometry"
	generated.scale = Vector3.ONE * (32.0 / map_units_per_godot_unit)
	generated.set_meta("jka_bsp_generated", true)
	generated.set_meta("material_report", material_report)
	status = "Built %s\n%d surfaces, %d patches, %d triangles.\n%d materials, %d missing images. Shader effects and collision are not fully implemented." % [bsp_map, builder.stats.surfaces, builder.stats.patches, builder.stats.triangles, material_report.size(), missing]
	notify_property_list_changed()
	return generated

func attach_generated(child: Node) -> void:
	add_child(child)
	_set_owners(child, owner if owner != null else self)

func detach_generated(child: Node) -> void:
	remove_child(child)

func _set_owners(child: Node, scene_owner: Node) -> void:
	child.owner = scene_owner
	for descendant in child.get_children():
		_set_owners(descendant, scene_owner)
