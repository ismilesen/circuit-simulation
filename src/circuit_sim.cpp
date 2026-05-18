#include "circuit_sim.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <cmath>
#include <limits>
#include <map>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

// std::filesystem is available on all platforms we target.
// On Emscripten it requires linking with -sFORCE_FILESYSTEM but the path
// utilities work correctly. We provide a fallback string-only dirname for web.
#ifndef __EMSCRIPTEN__
#include <filesystem>
#include <fstream>
namespace fs = std::filesystem;
#else
#include <fstream>
#include <sys/stat.h>
#endif

extern "C" {
#include "netlist.h"
#include "parser.h"
#include "xschemrc.h"
}

using namespace godot;

// ─── File / string utilities ────────────────────────────────────────────────

namespace {

constexpr int64_t SIMULATION_DATA_EMIT_STRIDE = 512;
#ifdef __EMSCRIPTEN__
constexpr const char *WEB_SKY130_PDK_ROOT = "user://pdks/sky130/models";
#endif

std::string to_lower_copy(const std::string &s) {
    std::string out = s;
    std::transform(out.begin(), out.end(), out.begin(),
        [](unsigned char c){ return static_cast<char>(std::tolower(c)); });
    return out;
}

std::string trim_copy(const std::string &s) {
    size_t start = 0;
    while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start]))) start++;
    size_t end = s.size();
    while (end > start && std::isspace(static_cast<unsigned char>(s[end - 1]))) end--;
    return s.substr(start, end - start);
}

bool starts_with_ci(const std::string &line, const std::string &prefix) {
    if (line.size() < prefix.size()) return false;
    for (size_t i = 0; i < prefix.size(); i++) {
        if (std::tolower(static_cast<unsigned char>(line[i])) !=
            std::tolower(static_cast<unsigned char>(prefix[i]))) return false;
    }
    return true;
}

std::string unquote_copy(const std::string &v) {
    if (v.size() >= 2 && v.front() == '"' && v.back() == '"')
        return v.substr(1, v.size() - 2);
    return v;
}

std::string maybe_quote(const std::string &v, bool q) {
    return q ? "\"" + v + "\"" : v;
}

std::string replace_all_copy(std::string v, const std::string &needle, const std::string &rep) {
    size_t pos = 0;
    while ((pos = v.find(needle, pos)) != std::string::npos) {
        v.replace(pos, needle.size(), rep);
        pos += rep.size();
    }
    return v;
}

std::string expand_pdk_root(std::string v, const std::string &pdk_root) {
    const char *env = std::getenv("PDK_ROOT");
    const std::string root = pdk_root.empty() ? (env ? std::string(env) : std::string()) : pdk_root;
    if (root.empty()) return v;
    v = replace_all_copy(v, "$PDK_ROOT", root);
    v = replace_all_copy(v, "${PDK_ROOT}", root);
    return v;
}

// Folds SPICE continuation lines ('+') — shared across all platforms.
std::vector<std::string> to_logical_lines(const std::vector<std::string> &physical) {
    std::vector<std::string> out;
    for (const std::string &raw : physical) {
        std::string t = trim_copy(raw);
        if (!t.empty() && t.front() == '+' && !out.empty())
            out.back() += " " + trim_copy(t.substr(1));
        else
            out.push_back(raw);
    }
    return out;
}

void split_text_lines(const std::string &text, std::vector<std::string> &out) {
    std::istringstream stream(text);
    std::string line;
    while (std::getline(stream, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        out.push_back(line);
    }
}

bool read_godot_file_lines(const String &path, std::vector<std::string> &out) {
    Ref<FileAccess> file = FileAccess::open(path, FileAccess::READ);
    if (file.is_null() || !file->is_open()) return false;

    String text = file->get_as_text();
    CharString utf8 = text.utf8();
    split_text_lines(std::string(utf8.get_data()), out);
    return true;
}

#ifndef __EMSCRIPTEN__
// Desktop: full filesystem path resolution via std::filesystem.
std::string resolve_path_token(const std::string &raw, const fs::path &base_dir,
                                const std::string &pdk_root) {
    std::string expanded = expand_pdk_root(raw, pdk_root);
    if (expanded.empty()) return expanded;
    fs::path p(expanded);
    if (p.is_relative()) p = fs::absolute(base_dir / p);
    else p = fs::absolute(p);
    return p.lexically_normal().string();
}

bool read_file_lines(const fs::path &path, std::vector<std::string> &out) {
    std::ifstream f(path);
    if (!f.is_open()) {
        return read_godot_file_lines(String(path.string().c_str()), out);
    }
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        out.push_back(line);
    }
    return true;
}

bool read_file_lines(const std::string &path, std::vector<std::string> &out) {
    return read_file_lines(fs::path(path), out);
}

std::string rewrite_include_or_lib(const std::string &line, const fs::path &base_dir,
                                    const std::string &pdk_root) {
    std::string t = trim_copy(line);
    bool is_inc = starts_with_ci(t, ".include");
    bool is_lib = starts_with_ci(t, ".lib");
    if (!is_inc && !is_lib) return line;
    std::istringstream iss(t);
    std::string directive, path_tok;
    iss >> directive >> path_tok;
    if (path_tok.empty()) return line;
    bool was_quoted = path_tok.size() >= 2 && path_tok.front() == '"' && path_tok.back() == '"';
    std::string resolved = resolve_path_token(unquote_copy(path_tok), base_dir, pdk_root);
    std::string rebuilt = directive + " " + maybe_quote(resolved, was_quoted);
    if (is_lib) { std::string section; if (iss >> section) rebuilt += " " + section; }
    return rebuilt;
}

std::string rewrite_input_file_path(const std::string &line, const fs::path &base_dir,
                                     const std::string &pdk_root) {
    const std::string key = "input_file=\"";
    size_t start = line.find(key);
    if (start == std::string::npos) return line;
    size_t vs = start + key.size();
    size_t ve = line.find('"', vs);
    if (ve == std::string::npos) return line;
    std::string resolved = resolve_path_token(line.substr(vs, ve - vs), base_dir, pdk_root);
    return line.substr(0, vs) + resolved + line.substr(ve);
}

#else
// Web: no std::filesystem — use string-based path helpers.
std::string web_dirname(const std::string &path) {
    size_t pos = path.rfind('/');
    return pos == std::string::npos ? "." : path.substr(0, pos);
}

bool has_godot_scheme(const std::string &path) {
    return path.rfind("user://", 0) == 0 || path.rfind("res://", 0) == 0;
}

std::string resolve_path_token(const std::string &raw, const std::string &base_dir,
                                const std::string &pdk_root) {
    std::string expanded = expand_pdk_root(raw, pdk_root);
    if (expanded.empty()) return expanded;
    if (has_godot_scheme(expanded)) return expanded;
    if (expanded[0] != '/') expanded = base_dir + "/" + expanded;
    return expanded;
}

bool read_file_lines(const std::string &path, std::vector<std::string> &out) {
    std::ifstream f(path);
    if (!f.is_open()) {
        return read_godot_file_lines(String(path.c_str()), out);
    }
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        out.push_back(line);
    }
    return true;
}

std::string rewrite_include_or_lib(const std::string &line, const std::string &base_dir,
                                    const std::string &pdk_root) {
    std::string t = trim_copy(line);
    bool is_inc = starts_with_ci(t, ".include");
    bool is_lib = starts_with_ci(t, ".lib");
    if (!is_inc && !is_lib) return line;
    std::istringstream iss(t);
    std::string directive, path_tok;
    iss >> directive >> path_tok;
    if (path_tok.empty()) return line;
    bool was_quoted = path_tok.size() >= 2 && path_tok.front() == '"' && path_tok.back() == '"';
    std::string resolved = resolve_path_token(unquote_copy(path_tok), base_dir, pdk_root);
    std::string rebuilt = directive + " " + maybe_quote(resolved, was_quoted);
    if (is_lib) { std::string section; if (iss >> section) rebuilt += " " + section; }
    return rebuilt;
}

std::string rewrite_input_file_path(const std::string &line, const std::string &base_dir,
                                     const std::string &pdk_root) {
    const std::string key = "input_file=\"";
    size_t start = line.find(key);
    if (start == std::string::npos) return line;
    size_t vs = start + key.size();
    size_t ve = line.find('"', vs);
    if (ve == std::string::npos) return line;
    std::string resolved = resolve_path_token(line.substr(vs, ve - vs), base_dir, pdk_root);
    return line.substr(0, vs) + resolved + line.substr(ve);
}
#endif

std::string normalize_sky130_subckt_params(const std::string &line) {
    std::string t = trim_copy(line);
    if (t.empty()) return line;

    char first = static_cast<char>(std::tolower(static_cast<unsigned char>(t[0])));
    if (first != 'x') return line;

    std::string lower = to_lower_copy(line);
    if (lower.find("sky130_fd_pr__") == std::string::npos) return line;
    if (lower.find(" w=") == std::string::npos && lower.find(" l=") == std::string::npos) return line;

    std::string normalized = line;
    if (lower.find(" params:") == std::string::npos) {
        size_t model_pos = lower.find("sky130_fd_pr__");
        if (model_pos == std::string::npos) return line;
        size_t model_end = line.find_first_of(" \t", model_pos);
        if (model_end == std::string::npos) return line;
        normalized = line.substr(0, model_end) + " params:" + line.substr(model_end);
    }

#ifdef __EMSCRIPTEN__
    // Convert the common Sky130 cell-netlist convention, e.g.
    // w=1650000u l=150000u, into SI values before browser-side bin selection.
    std::istringstream iss(normalized);
    std::ostringstream rebuilt;
    std::string tok;
    bool first_tok = true;
    while (iss >> tok) {
        std::string out_tok = tok;
        std::string tok_lower = to_lower_copy(tok);
        bool is_dimension = tok_lower.rfind("w=", 0) == 0 || tok_lower.rfind("l=", 0) == 0;
        if (is_dimension && !tok_lower.empty() && tok_lower.back() == 'u') {
            std::string key = tok.substr(0, 2);
            std::string number = tok.substr(2, tok.size() - 3);
            char *end_ptr = nullptr;
            double value = std::strtod(number.c_str(), &end_ptr);
            if (end_ptr != number.c_str() && *end_ptr == '\0' && value >= 1000.0) {
                std::ostringstream value_stream;
                value_stream << (value * 1e-12);
                out_tok = key + value_stream.str();
            }
        }
        if (!first_tok) rebuilt << ' ';
        rebuilt << out_tok;
        first_tok = false;
    }
    return rebuilt.str();
#else
    return normalized;
#endif
}

#ifdef __EMSCRIPTEN__
struct Sky130ModelBin {
    std::string name;
    std::string definition_line;
    int index = 0;
    double lmin = 0.0;
    double lmax = 0.0;
    double wmin = 0.0;
    double wmax = 0.0;
    bool has_bounds = false;
};

using Sky130ModelBins = std::map<std::string, std::vector<Sky130ModelBin>>;

std::vector<std::string> split_tokens(const std::string &line) {
    std::vector<std::string> tokens;
    std::istringstream iss(line);
    std::string tok;
    while (iss >> tok) tokens.push_back(tok);
    return tokens;
}

bool parse_spice_number(const std::string &token, double &out) {
    std::string value = trim_copy(token);
    if (value.empty()) return false;

    char suffix = static_cast<char>(std::tolower(static_cast<unsigned char>(value.back())));
    double scale = 1.0;
    bool has_suffix = true;
    switch (suffix) {
        case 'f': scale = 1e-15; break;
        case 'p': scale = 1e-12; break;
        case 'n': scale = 1e-9; break;
        case 'u': scale = 1e-6; break;
        case 'm': scale = 1e-3; break;
        case 'k': scale = 1e3; break;
        case 'g': scale = 1e9; break;
        case 't': scale = 1e12; break;
        default: has_suffix = false; break;
    }
    if (has_suffix) value.pop_back();

    char *end_ptr = nullptr;
    double parsed = std::strtod(value.c_str(), &end_ptr);
    if (end_ptr == value.c_str() || *end_ptr != '\0') return false;
    out = parsed * scale;
    return true;
}

bool extract_param_value(const std::vector<std::string> &tokens, const std::string &key,
                         double &out, size_t start = 0) {
    std::string key_lower = to_lower_copy(key);
    for (size_t i = start; i < tokens.size(); i++) {
        std::string tok = tokens[i];
        while (!tok.empty() && (tok.back() == ',' || tok.back() == ')')) tok.pop_back();
        std::string lower = to_lower_copy(tok);
        std::string prefix = key_lower + "=";
        if (lower.rfind(prefix, 0) == 0) {
            return parse_spice_number(tok.substr(prefix.size()), out);
        }
        if (lower == key_lower && i + 2 < tokens.size() && tokens[i + 1] == "=") {
            return parse_spice_number(tokens[i + 2], out);
        }
    }
    return false;
}

Sky130ModelBins collect_sky130_model_bins(const std::vector<std::string> &lines) {
    Sky130ModelBins bins;
    for (const std::string &line : lines) {
        std::string t = trim_copy(line);
        std::string lower = to_lower_copy(t);
        if (!starts_with_ci(lower, ".model")) continue;

        std::vector<std::string> tokens = split_tokens(t);
        if (tokens.size() < 3) continue;

        std::string model_name = tokens[1];
        std::string model_lower = to_lower_copy(model_name);
        if (model_lower.find("sky130_fd_pr__") == std::string::npos ||
            model_lower.find("__model.") == std::string::npos) {
            continue;
        }

        size_t dot_pos = model_name.rfind('.');
        if (dot_pos == std::string::npos || dot_pos + 1 >= model_name.size()) continue;

        char *end_ptr = nullptr;
        long index = std::strtol(model_name.c_str() + dot_pos + 1, &end_ptr, 10);
        if (*end_ptr != '\0') continue;

        Sky130ModelBin bin;
        bin.name = model_name;
        bin.definition_line = t;
        bin.index = static_cast<int>(index);
        bin.has_bounds =
            extract_param_value(tokens, "lmin", bin.lmin, 3) &&
            extract_param_value(tokens, "lmax", bin.lmax, 3) &&
            extract_param_value(tokens, "wmin", bin.wmin, 3) &&
            extract_param_value(tokens, "wmax", bin.wmax, 3);

        bins[model_name.substr(0, dot_pos)].push_back(bin);
    }

    for (auto &entry : bins) {
        std::sort(entry.second.begin(), entry.second.end(),
            [](const Sky130ModelBin &a, const Sky130ModelBin &b) {
                return a.index < b.index;
            });
    }
    return bins;
}

const Sky130ModelBin *select_sky130_model_bin(const std::vector<Sky130ModelBin> &bins,
                                              double w, double l) {
    constexpr double eps = 1e-15;
    for (const Sky130ModelBin &bin : bins) {
        if (!bin.has_bounds) continue;
        if (l + eps >= bin.lmin && l - eps <= bin.lmax &&
            w + eps >= bin.wmin && w - eps <= bin.wmax) {
            return &bin;
        }
    }

    const Sky130ModelBin *best = nullptr;
    double best_score = std::numeric_limits<double>::infinity();
    for (const Sky130ModelBin &bin : bins) {
        if (!bin.has_bounds) {
            if (!best) best = &bin;
            continue;
        }
        double l_center = (bin.lmin + bin.lmax) * 0.5;
        double w_center = (bin.wmin + bin.wmax) * 0.5;
        double l_scale = std::max(std::abs(l_center), 1e-15);
        double w_scale = std::max(std::abs(w_center), 1e-15);
        double score = std::abs((l - l_center) / l_scale) +
                       std::abs((w - w_center) / w_scale);
        if (score < best_score) {
            best_score = score;
            best = &bin;
        }
    }
    return best;
}

std::string rewrite_sky130_mos_instance_for_web(const std::string &line,
                                                const Sky130ModelBins &bins,
                                                std::map<std::string, std::string> &selected_models,
                                                int &rewrite_count) {
    std::string t = trim_copy(line);
    if (t.empty() || std::tolower(static_cast<unsigned char>(t[0])) != 'x') return line;

    std::vector<std::string> tokens = split_tokens(line);
    if (tokens.size() < 7) return line;

    size_t model_pos = std::string::npos;
    for (size_t i = 1; i < tokens.size(); i++) {
        std::string lower = to_lower_copy(tokens[i]);
        if (lower.rfind("sky130_fd_pr__", 0) == 0 &&
            (lower.find("nfet") != std::string::npos || lower.find("pfet") != std::string::npos)) {
            model_pos = i;
            break;
        }
    }
    if (model_pos == std::string::npos || model_pos < 5) return line;

    std::string base_model = tokens[model_pos] + "__model";
    auto found = bins.find(base_model);
    if (found == bins.end() || found->second.empty()) return line;

    double w = 0.0;
    double l = 0.0;
    if (!extract_param_value(tokens, "w", w, model_pos + 1) ||
        !extract_param_value(tokens, "l", l, model_pos + 1)) {
        return line;
    }

    const Sky130ModelBin *selected = select_sky130_model_bin(found->second, w, l);
    if (!selected) return line;
    if (!selected->definition_line.empty()) selected_models[selected->name] = selected->definition_line;

    std::map<std::string, std::string> params = {
        {"w", ""}, {"l", ""}, {"ad", "0"}, {"as", "0"},
        {"pd", "0"}, {"ps", "0"}, {"nrd", "0"}, {"nrs", "0"}
    };

    for (size_t i = model_pos + 1; i < tokens.size(); i++) {
        std::string tok = tokens[i];
        size_t eq = tok.find('=');
        if (eq == std::string::npos) continue;
        std::string key = to_lower_copy(tok.substr(0, eq));
        if (params.find(key) != params.end()) params[key] = tok.substr(eq + 1);
    }

    std::ostringstream rebuilt;
    std::string instance = tokens[0];
    instance[0] = 'M';
    rebuilt << instance << ' '
            << tokens[model_pos - 4] << ' '
            << tokens[model_pos - 3] << ' '
            << tokens[model_pos - 2] << ' '
            << tokens[model_pos - 1] << ' '
            << selected->name;

    for (const std::string &key : {"l", "w", "ad", "as", "pd", "ps", "nrd", "nrs"}) {
        if (!params[key].empty()) rebuilt << ' ' << key << '=' << params[key];
    }

    rewrite_count++;
    return rebuilt.str();
}
#endif

std::vector<std::string> extract_lib_section(const std::vector<std::string> &lines,
                                             const std::string &section) {
    std::vector<std::string> extracted;
    bool inside = false;
    for (const std::string &line : lines) {
        std::string t = trim_copy(line);
        if (starts_with_ci(t, ".lib")) {
            std::istringstream iss(t);
            std::string directive, current_section;
            iss >> directive >> current_section;
            if (current_section == section) inside = true;
            continue;
        }
        if (inside && starts_with_ci(t, ".endl")) {
            break;
        }
        if (inside) extracted.push_back(line);
    }
    return extracted;
}

#ifndef __EMSCRIPTEN__
std::string dirname_for_path(const std::string &path) {
    return fs::path(path).parent_path().string();
}

std::string resolve_include_path(const std::string &raw, const fs::path &base_dir,
                                 const std::string &pdk_root) {
    return resolve_path_token(raw, base_dir, pdk_root);
}

std::string resolve_include_path(const std::string &raw, const std::string &base_dir,
                                 const std::string &pdk_root) {
    return resolve_path_token(raw, fs::path(base_dir), pdk_root);
}
#else
std::string dirname_for_path(const std::string &path) {
    return web_dirname(path);
}

std::string resolve_include_path(const std::string &raw, const std::string &base_dir,
                                 const std::string &pdk_root) {
    return resolve_path_token(raw, base_dir, pdk_root);
}
#endif

template <typename BaseDir>
void expand_includes_recursive(const std::vector<std::string> &logical_lines,
                               const BaseDir &base_dir,
                               const std::string &pdk_root,
                               std::vector<std::string> &out,
                               int depth) {
    if (depth > 32) {
        out.push_back("* ERROR: maximum include depth exceeded");
        return;
    }

    for (const std::string &orig : logical_lines) {
        std::string t = trim_copy(orig);
        std::string l = to_lower_copy(t);
        bool is_include = starts_with_ci(l, ".include");
        bool is_lib = starts_with_ci(l, ".lib");
        if (!is_include && !is_lib) {
            out.push_back(orig);
            continue;
        }

        std::istringstream iss(t);
        std::string directive, path_tok, section;
        iss >> directive >> path_tok;
        if (path_tok.empty()) {
            out.push_back(orig);
            continue;
        }
        if (is_lib) iss >> section;

        std::string resolved = resolve_include_path(unquote_copy(path_tok), base_dir, pdk_root);
        std::vector<std::string> child_physical;
        if (!read_file_lines(resolved, child_physical)) {
            out.push_back(orig);
            continue;
        }

        std::vector<std::string> child_logical = to_logical_lines(child_physical);
        if (is_lib && !section.empty()) {
            child_logical = extract_lib_section(child_logical, section);
            if (child_logical.empty()) {
                out.push_back("* WARNING: empty .lib section " + section + " from " + resolved);
                continue;
            }
        }

        out.push_back("* begin expanded " + directive + " " + resolved);
        expand_includes_recursive(child_logical, dirname_for_path(resolved), pdk_root, out, depth + 1);
        out.push_back("* end expanded " + directive + " " + resolved);
    }
}

} // namespace

// ─── Static instance ─────────────────────────────────────────────────────────

CircuitSimulator* CircuitSimulator::instance = nullptr;

// ─── ngspice callbacks ───────────────────────────────────────────────────────

static int ng_send_char(char *output, int /*id*/, void* /*user_data*/) {
    if (CircuitSimulator::instance)
        CircuitSimulator::instance->call_deferred("emit_signal", "ngspice_output", String(output));
    UtilityFunctions::print(String("[ngspice] ") + String(output));
    return 0;
}

static int ng_send_stat(char* /*status*/, int /*id*/, void* /*user_data*/) { return 0; }

static int ng_controlled_exit(int /*status*/, bool /*immediate*/, bool /*exit_on_quit*/,
                               int /*id*/, void* /*user_data*/) {
    UtilityFunctions::print("ngspice exit requested");
    return 0;
}

static int ng_send_data(pvecvaluesall data, int /*count*/, int /*id*/, void* /*user_data*/) {
    if (!CircuitSimulator::instance || data == nullptr) return 0;
    PackedFloat64Array sample;
    sample.resize(data->veccount);
    for (int i = 0; i < data->veccount; i++)
        sample.set(i, data->vecsa[i]->creal);
    CircuitSimulator::instance->ingest_sample(sample);
    return 0;
}

static int ng_send_init_data(pvecinfoall data, int /*id*/, void* /*user_data*/) {
    const int count = data ? data->veccount : 0;
    if (CircuitSimulator::instance && data) {
        PackedStringArray names;
        for (int i = 0; i < count; i++) {
            if (data->vecs[i] && data->vecs[i]->vecname)
                names.append(String(data->vecs[i]->vecname));
            else
                names.append(String());
        }
        CircuitSimulator::instance->ingest_signal_names(names);
    }
    UtilityFunctions::print(String("Simulation initialized with ") +
                            String::num_int64(count) + " vectors");
    return 0;
}

static int ng_bg_thread_running(bool running, int /*id*/, void* /*user_data*/) {
    if (CircuitSimulator::instance) {
        if (running)
            CircuitSimulator::instance->call_deferred("emit_signal", "simulation_started");
        else
            CircuitSimulator::instance->call_deferred("emit_signal", "simulation_finished");
    }
    return 0;
}

// ─── GDScript bindings ───────────────────────────────────────────────────────

void CircuitSimulator::_bind_methods() {
    ClassDB::bind_method(D_METHOD("run_continuous", "spice_path", "pdk_root"),
                         &CircuitSimulator::run_continuous, DEFVAL(""));
    ClassDB::bind_method(D_METHOD("stop_continuous"), &CircuitSimulator::stop_continuous);
    ClassDB::bind_method(D_METHOD("is_running"), &CircuitSimulator::is_running);
    ClassDB::bind_method(
        D_METHOD("xschem_to_spice", "schematic_path", "output_path", "xschemrc_path", "symbol_dirs"),
        &CircuitSimulator::xschem_to_spice,
        DEFVAL(""),
        DEFVAL(PackedStringArray())
    );

    ADD_SIGNAL(MethodInfo("simulation_started"));
    ADD_SIGNAL(MethodInfo("simulation_finished"));
    ADD_SIGNAL(MethodInfo("signal_names_ready",
        PropertyInfo(Variant::PACKED_STRING_ARRAY, "names")));
    ADD_SIGNAL(MethodInfo("simulation_data_ready",
        PropertyInfo(Variant::PACKED_FLOAT64_ARRAY, "sample")));
    ADD_SIGNAL(MethodInfo("ngspice_output",
        PropertyInfo(Variant::STRING, "message")));
}

// ─── Constructor / destructor ─────────────────────────────────────────────────

CircuitSimulator::CircuitSimulator() {
    initialized               = false;
#ifndef __EMSCRIPTEN__
    ngspice_handle            = nullptr;
    ng_Init                   = nullptr;
    ng_Command                = nullptr;
    ng_Circ                   = nullptr;
    ng_Running                = nullptr;
#endif
    continuous_stop_requested = false;
    continuous_running        = false;
    continuous_sample_count.store(0);
    continuous_sleep_ms       = 25;
    callback_time_index.store(-1);
    instance = this;
}

CircuitSimulator::~CircuitSimulator() {
    stop_continuous_thread();
    if (initialized) shutdown_ngspice();
    if (instance == this) instance = nullptr;
}

// ─── Desktop only: library loading ───────────────────────────────────────────

#ifndef __EMSCRIPTEN__
bool CircuitSimulator::load_ngspice_library() {
#ifdef _WIN32
    ngspice_handle = LoadLibraryA("ngspice.dll");
    if (!ngspice_handle) ngspice_handle = LoadLibraryA("bin/ngspice.dll");
    if (!ngspice_handle) {
        UtilityFunctions::printerr("Failed to load ngspice.dll");
        return false;
    }
    ng_Init    = (int (*)(SendChar*, SendStat*, ControlledExit*, SendData*, SendInitData*,
                          BGThreadRunning*, void*))
                  GetProcAddress(ngspice_handle, "ngSpice_Init");
    ng_Command = (int  (*)(char*))  GetProcAddress(ngspice_handle, "ngSpice_Command");
    ng_Circ    = (int  (*)(char**)) GetProcAddress(ngspice_handle, "ngSpice_Circ");
    ng_Running = (bool (*)())       GetProcAddress(ngspice_handle, "ngSpice_running");
#else
    // Linux / macOS
    std::vector<std::string> candidates;
#ifdef __APPLE__
    candidates = {
        "libngspice.dylib", "./libngspice.dylib", "./bin/libngspice.dylib",
        "/opt/homebrew/lib/libngspice.dylib", "/usr/local/lib/libngspice.dylib",
        "libngspice.so", "./libngspice.so"
    };
#else
    candidates = {
        "libngspice.so", "./libngspice.so", "./bin/libngspice.so",
        "/usr/lib/libngspice.so", "/usr/local/lib/libngspice.so"
    };
#endif
    String attempted, last_error;
    for (const std::string &c : candidates) {
        ngspice_handle = dlopen(c.c_str(), RTLD_NOW);
        if (ngspice_handle) {
            UtilityFunctions::print("Loaded ngspice from: " + String(c.c_str()));
            break;
        }
        if (!attempted.is_empty()) attempted += ", ";
        attempted += String(c.c_str());
        const char *err = dlerror();
        if (err) last_error = String(err);
    }
    if (!ngspice_handle) {
        UtilityFunctions::printerr("Failed to load ngspice. Tried: " + attempted);
        if (!last_error.is_empty()) UtilityFunctions::printerr("Last error: " + last_error);
        return false;
    }
    ng_Init    = (int (*)(SendChar*, SendStat*, ControlledExit*, SendData*, SendInitData*,
                          BGThreadRunning*, void*))
                  dlsym(ngspice_handle, "ngSpice_Init");
    ng_Command = (int  (*)(char*))  dlsym(ngspice_handle, "ngSpice_Command");
    ng_Circ    = (int  (*)(char**)) dlsym(ngspice_handle, "ngSpice_Circ");
    ng_Running = (bool (*)())       dlsym(ngspice_handle, "ngSpice_running");
#endif
    if (!ng_Init || !ng_Command || !ng_Circ) {
        UtilityFunctions::printerr("Failed to resolve required ngspice symbols");
        unload_ngspice_library();
        return false;
    }
    return true;
}

void CircuitSimulator::unload_ngspice_library() {
#ifdef _WIN32
    if (ngspice_handle) { FreeLibrary(ngspice_handle); ngspice_handle = nullptr; }
#else
    if (ngspice_handle) { dlclose(ngspice_handle);     ngspice_handle = nullptr; }
#endif
    ng_Init = nullptr; ng_Command = nullptr; ng_Circ = nullptr; ng_Running = nullptr;
}
#endif // !__EMSCRIPTEN__

// ─── Initialization / shutdown ───────────────────────────────────────────────

bool CircuitSimulator::initialize_ngspice() {
    if (initialized) return true;

    int ret;
#ifndef __EMSCRIPTEN__
    // Desktop: load library dynamically then call via function pointer.
    if (!load_ngspice_library()) return false;
    ret = ng_Init(ng_send_char, ng_send_stat, ng_controlled_exit,
                  ng_send_data, ng_send_init_data, ng_bg_thread_running, this);
#else
    // Web: symbol linked directly from preloaded side module.
    ret = ngSpice_Init(ng_send_char, ng_send_stat, ng_controlled_exit,
                       ng_send_data, ng_send_init_data, ng_bg_thread_running, this);
#endif

    if (ret != 0) {
        UtilityFunctions::printerr("ngSpice_Init failed: " + String::num_int64(ret));
#ifndef __EMSCRIPTEN__
        unload_ngspice_library();
#endif
        return false;
    }
    initialized = true;
    UtilityFunctions::print("ngspice initialized");
    return true;
}

void CircuitSimulator::shutdown_ngspice() {
    stop_continuous_thread();
    if (!initialized) return;

#ifndef __EMSCRIPTEN__
    if (ng_Command) {
        ng_Command((char*)"bg_halt");
        if (ng_Running)
            for (int i = 0; i < 50 && ng_Running(); i++)
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
        ng_Command((char*)"reset");
    }
    unload_ngspice_library();
#else
    ngSpice_Command((char*)"bg_halt");
    ngSpice_Command((char*)"reset");
#endif

    initialized = false;
    UtilityFunctions::print("ngspice shut down");
}

// ─── Main entry point ────────────────────────────────────────────────────────
// Converts an xschem schematic to a SPICE deck via the xschem2spice submodule.
Dictionary CircuitSimulator::xschem_to_spice(
    const String &schematic_path,
    const String &output_path,
    const String &xschemrc_path,
    const PackedStringArray &symbol_dirs
) {
    Dictionary result;
    result["ok"] = false;

    CharString schematic_utf8 = schematic_path.utf8();
    CharString output_utf8 = output_path.utf8();
    CharString xschemrc_utf8 = xschemrc_path.utf8();

#ifndef __EMSCRIPTEN__
    const fs::path schematic_fs_path = fs::absolute(fs::path(schematic_utf8.get_data())).lexically_normal();
    const fs::path output_fs_path = fs::absolute(fs::path(output_utf8.get_data())).lexically_normal();
    const fs::path output_dir = output_fs_path.parent_path();

    if (!fs::exists(schematic_fs_path)) {
        result["error"] = String("schematic file does not exist: ") + String(schematic_fs_path.string().c_str());
        return result;
    }

    std::error_code ec;
    if (!output_dir.empty()) {
        fs::create_directories(output_dir, ec);
        if (ec) {
            result["error"] = String("failed to create output directory: ") + String(ec.message().c_str());
            return result;
        }
    }

    FILE *out = std::fopen(output_fs_path.string().c_str(), "w");
#else
    const std::string schematic_fs_path(schematic_utf8.get_data());
    const std::string output_fs_path(output_utf8.get_data());

    FILE *test_schematic = std::fopen(schematic_fs_path.c_str(), "r");
    if (!test_schematic) {
        result["error"] = String("schematic file does not exist: ") + String(schematic_fs_path.c_str());
        return result;
    }
    std::fclose(test_schematic);

    FILE *out = std::fopen(output_fs_path.c_str(), "w");
#endif
    if (!out) {
#ifndef __EMSCRIPTEN__
        result["error"] = String("failed to open output file: ") + String(output_fs_path.string().c_str());
#else
        result["error"] = String("failed to open output file: ") + String(output_fs_path.c_str());
#endif
        return result;
    }

    xs_library_path library_path;
    xs_library_path_init(&library_path);

    if (xschemrc_path.length() > 0) {
        xs_library_path_load_xschemrc(&library_path, xschemrc_utf8.get_data());
    }

#ifndef __EMSCRIPTEN__
    const fs::path schematic_dir = schematic_fs_path.parent_path();
    if (!schematic_dir.empty()) {
        xs_library_path_add(&library_path, schematic_dir.string().c_str());
    }
#else
    const std::string schematic_dir = web_dirname(schematic_fs_path);
    if (!schematic_dir.empty()) {
        xs_library_path_add(&library_path, schematic_dir.c_str());
    }
#endif

    std::vector<CharString> symbol_dir_utf8;
    symbol_dir_utf8.reserve(symbol_dirs.size());
    for (int64_t i = 0; i < symbol_dirs.size(); i++) {
        String dir = symbol_dirs[i];
        if (dir.strip_edges().is_empty()) {
            continue;
        }
        symbol_dir_utf8.push_back(dir.utf8());
        xs_library_path_add(&library_path, symbol_dir_utf8.back().get_data());
    }

    xs_schematic schematic;
#ifndef __EMSCRIPTEN__
    int status = xs_parse_schematic(schematic_fs_path.string().c_str(), &schematic);
#else
    int status = xs_parse_schematic(schematic_fs_path.c_str(), &schematic);
#endif
    if (status == 0) {
        xs_netlister netlister;
        xs_netlister_init(&netlister, &library_path, 1);
        status = xs_netlister_resolve_symbols(&netlister, &schematic);
        if (status == 0) {
            status = xs_netlister_emit_spice(&netlister, &schematic, out);
        }
        xs_netlister_free(&netlister);
        xs_free_schematic(&schematic);
    }

    std::fclose(out);
    xs_library_path_free(&library_path);

    if (status != 0) {
#ifndef __EMSCRIPTEN__
        fs::remove(output_fs_path, ec);
#else
        std::remove(output_fs_path.c_str());
#endif
        result["error"] = String("xschem2spice failed to generate a SPICE netlist");
        return result;
    }

    result["ok"] = true;
#ifndef __EMSCRIPTEN__
    result["output_path"] = String(output_fs_path.string().c_str());
#else
    result["output_path"] = String(output_fs_path.c_str());
#endif
    return result;
}

// Main entry point.
bool CircuitSimulator::run_continuous(const String &spice_path, const String &pdk_root) {
    if (!initialized && !initialize_ngspice()) return false;

    stop_continuous_thread();

    CharString utf8 = spice_path.utf8();
    std::string path_str(utf8.get_data());
    std::string pdk_root_str(pdk_root.utf8().get_data());

#ifndef __EMSCRIPTEN__
    fs::path fs_path = fs::absolute(fs::path(path_str)).lexically_normal();
    fs::path base_dir = fs_path.parent_path();
#else
    pdk_root_str = WEB_SKY130_PDK_ROOT;
    UtilityFunctions::print("CircuitSimulator: using fixed web Sky130 PDK_ROOT " + String(pdk_root_str.c_str()));
    std::string fs_path = path_str;
    std::string base_dir = web_dirname(path_str);
#endif

    std::vector<std::string> physical_lines;
    if (!read_file_lines(fs_path, physical_lines)) {
        UtilityFunctions::printerr("Cannot read file: " + String(path_str.c_str()));
        return false;
    }

    std::vector<std::string> logical = to_logical_lines(physical_lines);
    std::vector<std::string> expanded_lines;
    expand_includes_recursive(logical, base_dir, pdk_root_str, expanded_lines, 0);

#ifdef __EMSCRIPTEN__
    Sky130ModelBins sky130_model_bins = collect_sky130_model_bins(expanded_lines);
    std::map<std::string, std::string> sky130_selected_model_lines;
    int sky130_model_rewrite_count = 0;
#endif

    std::vector<std::string> out_lines;
    bool inside_control = false;
    bool has_end        = false;
    bool has_tran       = false;

    for (const std::string &orig : expanded_lines) {
        std::string t = trim_copy(orig);
        std::string l = to_lower_copy(t);

        if (starts_with_ci(l, ".control")) { inside_control = true;  continue; }
        if (inside_control) {
            if (starts_with_ci(l, ".endc")) inside_control = false;
            continue;
        }

        std::string line = rewrite_include_or_lib(orig, base_dir, pdk_root_str);
        line = rewrite_input_file_path(line, base_dir, pdk_root_str);
        line = normalize_sky130_subckt_params(line);
#ifdef __EMSCRIPTEN__
        line = rewrite_sky130_mos_instance_for_web(line, sky130_model_bins, sky130_selected_model_lines,
                                                   sky130_model_rewrite_count);
#endif

        std::string lt = to_lower_copy(trim_copy(line));
#ifdef __EMSCRIPTEN__
        if (starts_with_ci(lt, ".save") || starts_with_ci(lt, ".print")) {
            UtilityFunctions::print("CircuitSimulator: web omitted storage/output directive " + String(line.c_str()));
            continue;
        }
#endif
        if (lt == ".end") { has_end = true; out_lines.push_back(line); continue; }

        if (starts_with_ci(lt, ".tran")) {
            has_tran = true;
#ifdef __EMSCRIPTEN__
            std::istringstream iss(t);
            std::string directive, step_tok;
            iss >> directive >> step_tok;
            if (step_tok.empty()) step_tok = "1n";
            std::string continuous_tran = ".tran " + step_tok + " 1e12";
            out_lines.push_back(continuous_tran);
            UtilityFunctions::print("CircuitSimulator: web continuous transient command " +
                                    String(continuous_tran.c_str()) +
                                    " (source: " + String(line.c_str()) + ")");
#else
            std::istringstream iss(t);
            std::string directive, step_tok;
            iss >> directive >> step_tok;
            if (step_tok.empty()) step_tok = "1n";
            out_lines.push_back(".tran " + step_tok + " 1e12");
#endif
            continue;
        }
        out_lines.push_back(line);
    }

    if (!has_tran) {
#ifdef __EMSCRIPTEN__
        if (has_end) out_lines.insert(out_lines.end() - 1, ".tran 1n 1e12");
        else         out_lines.push_back(".tran 1n 1e12");
        UtilityFunctions::print("CircuitSimulator: web inserted default continuous transient command .tran 1n 1e12");
#else
        if (has_end) out_lines.insert(out_lines.end() - 1, ".tran 1n 1000");
        else         out_lines.push_back(".tran 1n 1e12");
#endif
    }
    if (!has_end) out_lines.push_back(".end");

#ifdef __EMSCRIPTEN__
    if (!sky130_selected_model_lines.empty()) {
        std::vector<std::string> promoted_models;
        promoted_models.reserve(sky130_selected_model_lines.size() + 1);
        promoted_models.push_back("* browser-promoted Sky130 model bins");
        for (const auto &entry : sky130_selected_model_lines) {
            promoted_models.push_back(entry.second);
        }

        auto end_it = std::find_if(out_lines.begin(), out_lines.end(), [](const std::string &line) {
            return to_lower_copy(trim_copy(line)) == ".end";
        });
        out_lines.insert(end_it, promoted_models.begin(), promoted_models.end());
    }

    if (sky130_model_rewrite_count > 0) {
        UtilityFunctions::print("CircuitSimulator: selected explicit Sky130 model bins for " +
                                String::num_int64(sky130_model_rewrite_count) +
                                " browser MOS instance(s); promoted " +
                                String::num_int64(static_cast<int64_t>(sky130_selected_model_lines.size())) +
                                " model definition(s)");
    }
#endif

    std::vector<char*> circ;
    circ.reserve(out_lines.size() + 1);
    for (std::string &s : out_lines) circ.push_back(const_cast<char*>(s.c_str()));
    circ.push_back(nullptr);

#ifndef __EMSCRIPTEN__
    if (ng_Circ(circ.data()) != 0) {
#else
    if (ngSpice_Circ(circ.data()) != 0) {
#endif
        UtilityFunctions::printerr("ngSpice_Circ failed — check deck errors above");
        return false;
    }

#ifndef __EMSCRIPTEN__
    int esave_result = ng_Command((char*)"esave node");
    UtilityFunctions::print("CircuitSimulator: ngspice command esave node -> " + String::num_int64(esave_result));
    if (esave_result != 0) {
        UtilityFunctions::printerr("ngspice esave node failed");
    }
    int save_none_result = ng_Command((char*)"save none");
    UtilityFunctions::print("CircuitSimulator: ngspice command save none -> " + String::num_int64(save_none_result));
    if (save_none_result != 0) {
        UtilityFunctions::printerr("ngspice save none failed");
    }
#else
    int esave_result = ngSpice_Command((char*)"esave node");
    UtilityFunctions::print("CircuitSimulator: ngspice command esave node -> " + String::num_int64(esave_result));
    if (esave_result != 0) {
        UtilityFunctions::printerr("ngspice esave node failed");
    }
    int save_none_result = ngSpice_Command((char*)"save none");
    UtilityFunctions::print("CircuitSimulator: ngspice command save none -> " + String::num_int64(save_none_result));
    if (save_none_result != 0) {
        UtilityFunctions::printerr("ngspice save none failed");
    }
#endif

    continuous_sample_count.store(0);
    continuous_stop_requested = false;
    continuous_running        = true;

#ifndef __EMSCRIPTEN__
    // Desktop: run ngspice on a background thread via function pointer.
    continuous_thread = std::thread([this]() {
        std::lock_guard<std::mutex> lock(ng_command_mutex);
        if (ng_Command((char*)"bg_run") != 0) {
            UtilityFunctions::printerr("bg_run failed");
            continuous_running = false;
            return;
        }
        while (!continuous_stop_requested.load()) {
            if (!ng_Running || !ng_Running()) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(continuous_sleep_ms));
        }
        continuous_running = false;
    });
#elif defined(__EMSCRIPTEN_PTHREADS__)
    // Threaded web: keep ngspice off the browser/Godot main thread.
    continuous_thread = std::thread([this]() {
        {
            std::lock_guard<std::mutex> lock(ng_command_mutex);
            if (ngSpice_Command((char*)"bg_run") != 0) {
                UtilityFunctions::printerr("ngspice bg_run failed");
                continuous_running = false;
                return;
            }
        }
        while (!continuous_stop_requested.load()) {
            if (!ngSpice_running()) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(continuous_sleep_ms));
        }
        continuous_running = false;
    });
#else
    // Web: single-threaded — run synchronously, callbacks fire inline.
    if (ngSpice_Command((char*)"run") != 0) {
        UtilityFunctions::printerr("ngspice run failed");
        continuous_running = false;
        return false;
    }
    continuous_running = false;
#endif

    return true;
}

void CircuitSimulator::stop_continuous() { stop_continuous_thread(); }

bool CircuitSimulator::is_running() const {
#ifndef __EMSCRIPTEN__
    return continuous_running.load() || (initialized && ng_Running && ng_Running());
#else
    return continuous_running.load() || (initialized && ngSpice_running());
#endif
}

// ─── Internal thread management ──────────────────────────────────────────────

void CircuitSimulator::stop_continuous_thread() {
    continuous_stop_requested = true;
#ifndef __EMSCRIPTEN__
    if (initialized && ng_Command) {
        std::unique_lock<std::mutex> lock(ng_command_mutex, std::try_to_lock);
        if (lock.owns_lock()) ng_Command((char*)"bg_halt");
    }
    if (continuous_thread.joinable()) continuous_thread.join();
#elif defined(__EMSCRIPTEN_PTHREADS__)
    if (initialized) {
        std::unique_lock<std::mutex> lock(ng_command_mutex, std::try_to_lock);
        if (lock.owns_lock()) ngSpice_Command((char*)"bg_halt");
    }
    if (continuous_thread.joinable()) continuous_thread.join();
#else
    if (initialized && continuous_running.load()) ngSpice_Command((char*)"halt");
#endif
    continuous_running = false;
}

// ─── Callback ingestion ───────────────────────────────────────────────────────

void CircuitSimulator::ingest_signal_names(const PackedStringArray &names) {
    {
        std::lock_guard<std::mutex> lock(names_mutex);
        callback_signal_names = names;
        callback_time_index.store(-1);
        for (int i = 0; i < names.size(); i++) {
            if (names[i].to_lower() == "time") {
                callback_time_index.store(i);
                break;
            }
        }
    }
    call_deferred("emit_signal", "signal_names_ready", names);
}

void CircuitSimulator::ingest_sample(const PackedFloat64Array &sample) {
    const int64_t count = continuous_sample_count.fetch_add(1) + 1;
    if (count % SIMULATION_DATA_EMIT_STRIDE == 0) {
        call_deferred("emit_signal", "simulation_data_ready", sample);
    }
}
