#ifndef SCH_PARSER_H
#define SCH_PARSER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class SchParser : public RefCounted {
    GDCLASS(SchParser, RefCounted)

private:
    Array wires;
    Array components;
    String version;

    // Parsing helpers
    Dictionary _parse_wire(const String &line);
    Dictionary _parse_component(const String &accumulated_line);
    Dictionary _parse_attributes(const String &attrs_str);
    String _extract_braces(const String &text);
    bool _has_complete_braces(const String &text);
    String _get_attr(const String &attrs_str, const String &key);

protected:
    static void _bind_methods();

public:
    SchParser();
    ~SchParser();

    // Parse from file path or string content
    bool parse_file(const String &path);
    bool parse_string(const String &content);

    // Getters
    Array get_wires() const;
    Array get_components() const;
    String get_version() const;

    // Utility
    String get_component_type(const String &symbol) const;
    void print_summary();
};

} // namespace godot

#endif // SCH_PARSER_H
