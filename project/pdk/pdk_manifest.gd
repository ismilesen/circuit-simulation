class_name PdkManifest
extends RefCounted

var schema: int = 0
var pdk_family: String = ""
var virtual_pdk_root: String = ""
var symbols: Array[Dictionary] = []
var files: Array[Dictionary] = []
var symbols_by_id: Dictionary = {}
var symbols_by_file: Dictionary = {}

const SYMBOL_FILE_ALIASES := {
	"pfet.sym": "pfet_01v8.sym",
	"pmos.sym": "pfet_01v8.sym",
	"nfet.sym": "nfet_01v8.sym",
	"nmos.sym": "nfet_01v8.sym",
}


func load_from_dictionary(data: Dictionary) -> void:
	schema = int(data.get("schema", 0))
	pdk_family = str(data.get("pdk_family", ""))
	virtual_pdk_root = str(data.get("virtual_pdk_root", ""))
	symbols = _dictionary_array(data.get("symbols", []))
	files = _dictionary_array(data.get("files", []))
	_rebuild_indexes()


func is_valid() -> bool:
	return schema > 0 and pdk_family != "" and not symbols.is_empty()


func get_symbol(symbol_id: String) -> Dictionary:
	return symbols_by_id.get(symbol_id, {})


func get_symbol_for_file(symbol_file: String) -> Dictionary:
	var key := symbol_file.get_file()
	if symbols_by_file.has(key):
		return symbols_by_file[key]

	var alias_key := str(SYMBOL_FILE_ALIASES.get(key, ""))
	if alias_key != "" and symbols_by_file.has(alias_key):
		return symbols_by_file[alias_key]

	var id_key := key.get_basename()
	if symbols_by_id.has(id_key):
		return symbols_by_id[id_key]

	return {}


func get_symbol_count() -> int:
	return symbols.size()


func get_file_count() -> int:
	return files.size()


func _rebuild_indexes() -> void:
	symbols_by_id.clear()
	symbols_by_file.clear()
	for symbol: Dictionary in symbols:
		var id := str(symbol.get("id", ""))
		if id != "":
			symbols_by_id[id] = symbol
		var symbol_path := str(symbol.get("symbol_path", ""))
		var filename := symbol_path.get_file()
		if filename != "":
			symbols_by_file[filename] = symbol
		if id != "":
			symbols_by_file["%s.sym" % id] = symbol


static func _dictionary_array(value: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if value is Array:
		for item: Variant in value:
			if item is Dictionary:
				result.append(item)
	return result
