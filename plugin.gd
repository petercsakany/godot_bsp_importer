@tool
extends EditorPlugin
const MapScript = preload("res://addons/jka_bsp/map_node.gd")
var inspector: EditorInspectorPlugin

class MapInspector extends EditorInspectorPlugin:
	var plugin: EditorPlugin
	func _can_handle(object: Object) -> bool:
		return object is Node3D and object.get_script() == preload("res://addons/jka_bsp/map_node.gd")
	func _parse_begin(object: Object) -> void:
		var row := HBoxContainer.new()
		var refresh := Button.new()
		refresh.text = "Refresh Maps"
		refresh.pressed.connect(func(): object.scan_maps())
		row.add_child(refresh)
		var build := Button.new()
		build.text = "Build Map"
		build.pressed.connect(func(): plugin.build_map(object))
		row.add_child(build)
		add_custom_control(row)
		var note := Label.new()
		note.text = "Select a BSP below, then Build Map.\nSave the scene to keep the generated map."
		add_custom_control(note)

func _enter_tree() -> void:
	add_custom_type("JkaBspMap", "Node3D", MapScript, get_editor_interface().get_base_control().get_theme_icon("MeshInstance3D", "EditorIcons"))
	var custom := MapInspector.new()
	custom.plugin = self
	inspector = custom
	add_inspector_plugin(inspector)

func _exit_tree() -> void:
	remove_inspector_plugin(inspector)
	inspector = null
	remove_custom_type("JkaBspMap")

func build_map(map: Node3D) -> void:
	var generated: Node3D = map.create_map()
	if generated == null:
		push_error(map.status)
		return
	var undo := get_undo_redo()
	undo.create_action("Build JKA BSP map", UndoRedo.MERGE_DISABLE, map)
	undo.add_undo_method(map, "detach_generated", generated)
	for child in map.get_children():
		if child.get_meta("jka_bsp_generated", false):
			undo.add_do_method(map, "detach_generated", child)
			undo.add_undo_method(map, "attach_generated", child)
			undo.add_undo_reference(child)
	undo.add_do_method(map, "attach_generated", generated)
	undo.add_do_reference(generated)
	undo.commit_action()
