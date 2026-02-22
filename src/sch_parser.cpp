#include "sch_parser.h"
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void SchParser::_bind_methods() {
    ClassDB::bind_method(D_METHOD("parse_file", "path"), &SchParser::parse_file);
    ClassDB::bind_method(D_METHOD("parse_string", "content"), &SchParser::parse_string);
    ClassDB::bind_method(D_METHOD("get_wires"), &SchParser::get_wires);
    ClassDB::bind_method(D_METHOD("get_components"), &SchParser::get_components);
    ClassDB::bind_method(D_METHOD("get_version"), &SchParser::get_version);
    ClassDB::bind_method(D_METHOD("get_component_type", "symbol"), &SchParser::get_component_type);
    ClassDB::bind_method(D_METHOD("print_summary"), &SchParser::print_summary);

    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "wires"), "", "get_wires");
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "components"), "", "get_components");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "version"), "", "get_version");
}

SchParser::SchParser() {
    version = "";
}

SchParser::~SchParser() {
}

bool SchParser::parse_file(const String &path) {
    Ref<FileAccess> file = FileAccess::open(path, FileAccess::READ);
    if (file.is_null()) {
        UtilityFunctions::push_error("SchParser: Failed to open file: " + path);
        return false;
    }

    String content = file->get_as_text();
    file->close();
    return parse_string(content);
}

bool SchParser::parse_string(const String &content) {
    wires.clear();
    components.clear();
    version = "";

    PackedStringArray lines = content.split("\n");
    int i = 0;

    while (i < lines.size()) {
        String line = lines[i].strip_edges();

        if (line.begins_with("v {")) {
            // Version line: v {xschem version=3.4.6 file_version=1.2}
            version = _extract_braces(line.substr(2));

        } else if (line.begins_with("N ")) {
            // Wire: N x1 y1 x2 y2 {lab=LABEL}
            Dictionary wire = _parse_wire(line);
            if (wire.size() > 0) {
                wires.append(wire);
            }

        } else if (line.begins_with("C {")) {
            // Component: C {symbol} x y rot mirror {attributes}
            // May span multiple lines if braces aren't balanced
            String full_line = line;
            while (!_has_complete_braces(full_line) && i + 1 < lines.size()) {
                i += 1;
                full_line += "\n" + lines[i];
            }

            Dictionary component = _parse_component(full_line);
            if (component.size() > 0) {
                components.append(component);
            }
        }
        // Skip G {}, K {}, V {}, S {}, E {} and other lines

        i += 1;
    }

    return true;
}

Dictionary SchParser::_parse_wire(const String &line) {
    // N x1 y1 x2 y2 {lab=LABEL}
    PackedStringArray parts = line.split(" ", false);
    if (parts.size() < 5) {
        return Dictionary();
    }

    Dictionary wire;
    wire["x1"] = parts[1].to_float();
    wire["y1"] = parts[2].to_float();
    wire["x2"] = parts[3].to_float();
    wire["y2"] = parts[4].to_float();
    wire["label"] = String("");

    // Extract label from attributes
    int attr_start = line.find("{");
    if (attr_start != -1) {
        String attrs = _extract_braces(line.substr(attr_start));
        wire["label"] = _get_attr(attrs, "lab");
    }

    return wire;
}

Dictionary SchParser::_parse_component(const String &accumulated_line) {
    // C {symbol} x y rot mirror {attributes}
    int symbol_start = accumulated_line.find("{");
    int symbol_end = accumulated_line.find("}", symbol_start);
    if (symbol_start == -1 || symbol_end == -1) {
        return Dictionary();
    }

    String symbol = accumulated_line.substr(symbol_start + 1, symbol_end - symbol_start - 1);

    // Parse coordinates after symbol
    String after_symbol = accumulated_line.substr(symbol_end + 1).strip_edges();
    PackedStringArray parts = after_symbol.split(" ", false);

    if (parts.size() < 4) {
        return Dictionary();
    }

    Dictionary component;
    component["symbol"] = symbol;
    component["x"] = parts[0].to_float();
    component["y"] = parts[1].to_float();
    component["rotation"] = parts[2].to_int();
    component["mirror"] = parts[3].to_int();
    component["attributes"] = Dictionary();
    component["name"] = String("");
    component["label"] = String("");
    component["type"] = get_component_type(symbol);

    // Extract attributes from the rest
    int attr_start = after_symbol.find("{");
    if (attr_start != -1) {
        String attrs_str = _extract_braces(after_symbol.substr(attr_start));
        Dictionary attrs = _parse_attributes(attrs_str);
        component["attributes"] = attrs;

        if (attrs.has("name")) {
            component["name"] = attrs["name"];
        }
        if (attrs.has("lab")) {
            component["label"] = attrs["lab"];
        }
    }

    return component;
}

Dictionary SchParser::_parse_attributes(const String &attrs_str) {
    Dictionary attrs;
    // Handle both space-separated and newline-separated attributes
    String normalized = attrs_str.replace("\n", " ");
    PackedStringArray parts = normalized.split(" ", false);

    for (int i = 0; i < parts.size(); i++) {
        String part = parts[i].strip_edges();
        int eq_pos = part.find("=");
        if (eq_pos != -1) {
            String key = part.substr(0, eq_pos);
            String value = part.substr(eq_pos + 1);
            attrs[key] = value;
        }
    }

    return attrs;
}

String SchParser::_extract_braces(const String &text) {
    int start = text.find("{");
    if (start == -1) {
        return text;
    }
    int end = text.rfind("}");
    if (end == -1) {
        return text.substr(start + 1);
    }
    return text.substr(start + 1, end - start - 1);
}

bool SchParser::_has_complete_braces(const String &text) {
    int open_count = 0;
    int close_count = 0;
    for (int i = 0; i < text.length(); i++) {
        if (text[i] == '{') {
            open_count++;
        } else if (text[i] == '}') {
            close_count++;
        }
    }
    return open_count == close_count;
}

String SchParser::_get_attr(const String &attrs_str, const String &key) {
    String search = key + String("=");
    int pos = attrs_str.find(search);
    if (pos == -1) {
        return String("");
    }
    int start = pos + search.length();
    int end = attrs_str.find(" ", start);
    if (end == -1) {
        end = attrs_str.length();
    }
    return attrs_str.substr(start, end - start);
}

String SchParser::get_component_type(const String &symbol) const {
    if (symbol.find("pfet") != -1 || symbol.to_lower().find("pmos") != -1) {
        return "pmos";
    } else if (symbol.find("nfet") != -1 || symbol.to_lower().find("nmos") != -1) {
        return "nmos";
    } else if (symbol.find("ipin") != -1) {
        return "input_pin";
    } else if (symbol.find("opin") != -1) {
        return "output_pin";
    } else if (symbol.find("lab_pin") != -1) {
        return "label";
    } else if (symbol.find("res") != -1) {
        return "resistor";
    } else if (symbol.find("cap") != -1) {
        return "capacitor";
    }
    return "unknown";
}

Array SchParser::get_wires() const {
    return wires;
}

Array SchParser::get_components() const {
    return components;
}

String SchParser::get_version() const {
    return version;
}

void SchParser::print_summary() {
    UtilityFunctions::print("=== Schematic Summary ===");
    UtilityFunctions::print("Version: ", version);
    UtilityFunctions::print("Wires: ", wires.size());

    for (int i = 0; i < wires.size(); i++) {
        Dictionary w = wires[i];
        UtilityFunctions::print("  Wire: (", w["x1"], ",", w["y1"], ") -> (", w["x2"], ",", w["y2"], ") lab=", w["label"]);
    }

    UtilityFunctions::print("Components: ", components.size());

    for (int i = 0; i < components.size(); i++) {
        Dictionary c = components[i];
        UtilityFunctions::print("  ", c["type"], ": ", c["name"], " at (", c["x"], ",", c["y"], ") lab=", c["label"]);
    }
}
