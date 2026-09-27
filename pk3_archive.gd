@tool
extends RefCounted
## Read-only PK3 access. No archive entries are extracted to disk.
var error_message := ""
var archive_path := ""
var _zip := ZIPReader.new()
var _entries := {}
var _opened := false

func open(path: String) -> Error:
	close()
	error_message = ""
	var error := _zip.open(path)
	if error != OK:
		error_message = "Cannot open PK3 %s: %s" % [path, error_string(error)]
		return error
	_opened = true
	archive_path = path
	for entry in _zip.get_files():
		_entries[entry.replace("\\", "/").to_lower()] = entry
	return OK

func close() -> void:
	if _opened:
		_zip.close()
	_opened = false
	_entries.clear()
	archive_path = ""

func files(extension: String = "") -> PackedStringArray:
	var result := PackedStringArray()
	for entry in _entries:
		if extension.is_empty() or entry.ends_with(extension.to_lower()):
			result.append(entry)
	result.sort()
	return result

func read_file(path: String) -> PackedByteArray:
	error_message = ""
	var normalized := path.replace("\\", "/").to_lower()
	if not _opened or not _entries.has(normalized):
		error_message = "PK3 entry not found: %s in %s" % [path, archive_path]
		return PackedByteArray()
	var bytes := _zip.read_file(_entries[normalized])
	if bytes.is_empty():
		error_message = "PK3 entry is empty or could not be decompressed: " + path
	return bytes

func read_bsp(path: String) -> Dictionary:
	# Accept either maps/mp/duel4.bsp or the convenient mp/duel4.bsp.
	var entry := path.replace("\\", "/").to_lower()
	if not entry.begins_with("maps/"):
		entry = "maps/" + entry
	var bytes := read_file(entry)
	if not error_message.is_empty():
		return {"ok": false, "errors": [error_message]}
	var reader = preload("res://addons/jka_bsp/bsp_reader.gd").new()
	return reader.read_bytes(bytes, archive_path + "::" + entry)
