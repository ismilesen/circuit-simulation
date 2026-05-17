class_name PdkManifestLoader
extends Node

signal manifest_loaded(manifest)
signal manifest_failed(message: String)
signal symbol_loaded(symbol: Dictionary, text: String, cached_path: String)
signal symbol_failed(symbol: Dictionary, message: String)
signal symbols_cached(count: int)

const DEFAULT_WEB_MANIFEST := "pdks/sky130/manifest.json"
const PdkManifestScript := preload("res://pdk/pdk_manifest.gd")
const SYMBOL_CACHE_DIR := "user://pdk_symbols"
const SYMBOL_CACHE_ALIASES := {
	"pfet_01v8.sym": ["pfet.sym", "pmos.sym"],
	"nfet_01v8.sym": ["nfet.sym", "nmos.sym"],
}

var _request: HTTPRequest = null
var _symbol_request: HTTPRequest = null
var _pending_url: String = ""
var _pending_symbol: Dictionary = {}


func load_sky130_manifest() -> void:
	load_manifest(DEFAULT_WEB_MANIFEST)


func load_manifest(path_or_url: String) -> void:
	if OS.has_feature("web"):
		_load_manifest_http(_resolve_web_url(path_or_url))
	else:
		_load_manifest_file(path_or_url)


func _load_manifest_file(path: String) -> void:
	var candidates: Array[String] = [path]
	if not path.begins_with("res://") and not path.begins_with("user://"):
		candidates.append("res://" + path)
		candidates.append("res://../project/web/" + path)

	for candidate: String in candidates:
		if not FileAccess.file_exists(candidate):
			continue
		var file := FileAccess.open(candidate, FileAccess.READ)
		if file == null:
			continue
		var text := file.get_as_text()
		file.close()
		_parse_manifest_text(text, candidate)
		return

	manifest_failed.emit("PDK manifest not found: " + path)


func _load_manifest_http(url: String) -> void:
	_pending_url = url
	if _request == null:
		_request = HTTPRequest.new()
		_request.name = "PdkManifestRequest"
		add_child(_request)
		_request.request_completed.connect(_on_request_completed)

	var err := _request.request(url)
	if err != OK:
		manifest_failed.emit("Failed to request PDK manifest: %s (error %d)" % [url, err])


func load_symbol(symbol: Dictionary) -> void:
	var symbol_path := str(symbol.get("symbol_path", ""))
	if symbol_path == "":
		symbol_failed.emit(symbol, "PDK symbol has no symbol_path.")
		return

	var family := "sky130"
	var url := _resolve_web_url("pdks/%s/%s" % [family, symbol_path])
	if OS.has_feature("web"):
		_load_symbol_http(symbol, url)
	else:
		_load_symbol_file(symbol, "project/web/pdks/%s/%s" % [family, symbol_path])


func cache_manifest_symbols(manifest: Variant) -> void:
	if manifest == null:
		symbols_cached.emit(0)
		return

	var cached := 0
	for symbol: Dictionary in manifest.symbols:
		if await ensure_symbol_cached(symbol) != "":
			cached += 1

	symbols_cached.emit(cached)


func ensure_symbol_cached(symbol: Dictionary) -> String:
	var symbol_path := str(symbol.get("symbol_path", ""))
	if symbol_path == "":
		return ""

	var cached_path := _cache_path_for_symbol(symbol)
	if FileAccess.file_exists(cached_path):
		_ensure_symbol_cache_aliases(symbol, cached_path)
		return cached_path

	var text := await _fetch_symbol_text(symbol)
	if text == "":
		return ""
	return _write_symbol_cache(symbol, text)


func get_symbol_text(symbol: Dictionary) -> String:
	return await _fetch_symbol_text(symbol)


func _load_symbol_file(symbol: Dictionary, path: String) -> void:
	var file_path := path
	if not FileAccess.file_exists(file_path):
		file_path = "res://../" + path
	if not FileAccess.file_exists(file_path):
		symbol_failed.emit(symbol, "PDK symbol file not found: " + path)
		return
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		symbol_failed.emit(symbol, "Could not open PDK symbol file: " + path)
		return
	var text := file.get_as_text()
	file.close()
	symbol_loaded.emit(symbol, text, file_path)


func _fetch_symbol_text(symbol: Dictionary) -> String:
	var symbol_path := str(symbol.get("symbol_path", ""))
	if symbol_path == "":
		return ""

	var family := "sky130"
	var url := _resolve_web_url("pdks/%s/%s" % [family, symbol_path])
	if not OS.has_feature("web"):
		var file_path := "project/build/web/release/pdks/%s/%s" % [family, symbol_path]
		if not FileAccess.file_exists(file_path):
			file_path = "res://../" + file_path
		if not FileAccess.file_exists(file_path):
			return ""
		var file := FileAccess.open(file_path, FileAccess.READ)
		if file == null:
			return ""
		var text := file.get_as_text()
		file.close()
		return text

	return await _fetch_url_text(url)


func _fetch_url_text(url: String) -> String:
	var request := HTTPRequest.new()
	request.name = "PdkSymbolFetchRequest"
	add_child(request)

	var err := request.request(url)
	if err != OK:
		request.queue_free()
		return ""
	var completed: Array = await request.request_completed
	request.queue_free()
	var result := int(completed[0])
	var response_code := int(completed[1])
	var body: PackedByteArray = completed[3]
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		return ""
	return body.get_string_from_utf8()


func _load_symbol_http(symbol: Dictionary, url: String) -> void:
	_pending_symbol = symbol.duplicate(true)
	if _symbol_request == null:
		_symbol_request = HTTPRequest.new()
		_symbol_request.name = "PdkSymbolRequest"
		add_child(_symbol_request)
		_symbol_request.request_completed.connect(_on_symbol_request_completed)

	var err := _symbol_request.request(url)
	if err != OK:
		symbol_failed.emit(symbol, "Failed to request PDK symbol: %s (error %d)" % [url, err])


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		manifest_failed.emit("Failed to fetch PDK manifest: %s (result %d)" % [_pending_url, result])
		return
	if response_code < 200 or response_code >= 300:
		manifest_failed.emit("Failed to fetch PDK manifest: %s (HTTP %d)" % [_pending_url, response_code])
		return
	_parse_manifest_text(body.get_string_from_utf8(), _pending_url)


func _on_symbol_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var symbol := _pending_symbol.duplicate(true)
	if result != HTTPRequest.RESULT_SUCCESS:
		symbol_failed.emit(symbol, "Failed to fetch PDK symbol (result %d)" % result)
		return
	if response_code < 200 or response_code >= 300:
		symbol_failed.emit(symbol, "Failed to fetch PDK symbol (HTTP %d)" % response_code)
		return
	var text := body.get_string_from_utf8()
	var cached_path := _cache_symbol_text(symbol, text)
	symbol_loaded.emit(symbol, text, cached_path)


func _parse_manifest_text(text: String, source: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		manifest_failed.emit("PDK manifest is not a JSON object: " + source)
		return

	var manifest = PdkManifestScript.new()
	manifest.load_from_dictionary(parsed)
	if not manifest.is_valid():
		manifest_failed.emit("PDK manifest is missing required fields: " + source)
		return

	manifest_loaded.emit(manifest)


func _resolve_web_url(path_or_url: String) -> String:
	if path_or_url.begins_with("http://") or path_or_url.begins_with("https://"):
		return path_or_url

	var relative := path_or_url.trim_prefix("/")
	if OS.has_feature("web"):
		var script := """
			(() => {
				const base = window.location.href.replace(/[#?].*$/, "").replace(/[^/]*$/, "");
				return new URL("%s", base).toString();
			})()
		""" % relative.json_escape()
		var resolved: Variant = JavaScriptBridge.eval(script, true)
		if typeof(resolved) == TYPE_STRING and str(resolved) != "":
			return str(resolved)
	return relative


func _cache_symbol_text(symbol: Dictionary, text: String) -> String:
	return _write_symbol_cache(symbol, text)


func _write_symbol_cache(symbol: Dictionary, text: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SYMBOL_CACHE_DIR))
	var cached_path := _cache_path_for_symbol(symbol)
	var file := FileAccess.open(cached_path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(text)
	file.close()
	_ensure_symbol_cache_aliases(symbol, cached_path)
	return cached_path


func _cache_path_for_symbol(symbol: Dictionary) -> String:
	var symbol_path := str(symbol.get("symbol_path", ""))
	var filename := symbol_path.get_file()
	if filename == "":
		filename = "%s.sym" % str(symbol.get("id", "component"))
	return "%s/%s" % [SYMBOL_CACHE_DIR, _sanitize_filename(filename)]


func _ensure_symbol_cache_aliases(symbol: Dictionary, cached_path: String) -> void:
	var source_file := cached_path.get_file()
	var aliases: Array = SYMBOL_CACHE_ALIASES.get(source_file, [])
	if aliases.is_empty():
		return

	var file := FileAccess.open(cached_path, FileAccess.READ)
	if file == null:
		return
	var text := file.get_as_text()
	file.close()

	for alias: String in aliases:
		var alias_path := "%s/%s" % [SYMBOL_CACHE_DIR, _sanitize_filename(alias)]
		if FileAccess.file_exists(alias_path):
			continue
		var alias_file := FileAccess.open(alias_path, FileAccess.WRITE)
		if alias_file == null:
			continue
		alias_file.store_string(text)
		alias_file.close()


func _sanitize_filename(filename: String) -> String:
	var result := filename.strip_edges()
	for ch in ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]:
		result = result.replace(ch, "_")
	if result == "":
		return "symbol.sym"
	return result
