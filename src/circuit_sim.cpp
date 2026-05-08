#include "circuit_sim.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <chrono>
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

using namespace godot;

// ─── File / string utilities ────────────────────────────────────────────────

namespace {

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
    if (!f.is_open()) return false;
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        out.push_back(line);
    }
    return true;
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

std::string resolve_path_token(const std::string &raw, const std::string &base_dir,
                                const std::string &pdk_root) {
    std::string expanded = expand_pdk_root(raw, pdk_root);
    if (expanded.empty()) return expanded;
    if (expanded[0] != '/') expanded = base_dir + "/" + expanded;
    return expanded;
}

bool read_file_lines(const std::string &path, std::vector<std::string> &out) {
    std::ifstream f(path);
    if (!f.is_open()) return false;
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
    std::string fs_path = path_str;
    std::string base_dir = web_dirname(path_str);
#endif

    std::vector<std::string> physical_lines;
    if (!read_file_lines(fs_path, physical_lines)) {
        UtilityFunctions::printerr("Cannot read file: " + String(path_str.c_str()));
        return false;
    }

    std::vector<std::string> logical = to_logical_lines(physical_lines);
    std::vector<std::string> out_lines;
    bool inside_control = false;
    bool has_end        = false;
    bool has_tran       = false;

    for (const std::string &orig : logical) {
        std::string t = trim_copy(orig);
        std::string l = to_lower_copy(t);

        if (starts_with_ci(l, ".control")) { inside_control = true;  continue; }
        if (inside_control) {
            if (starts_with_ci(l, ".endc")) inside_control = false;
            continue;
        }

        std::string line = rewrite_include_or_lib(orig, base_dir, pdk_root_str);
        line = rewrite_input_file_path(line, base_dir, pdk_root_str);

        std::string lt = to_lower_copy(trim_copy(line));
        if (lt == ".end") { has_end = true; out_lines.push_back(line); continue; }

        if (starts_with_ci(lt, ".tran")) {
            has_tran = true;
            std::istringstream iss(t);
            std::string directive, step_tok;
            iss >> directive >> step_tok;
            if (step_tok.empty()) step_tok = "1n";
            out_lines.push_back(".tran " + step_tok + " 1e12");
            continue;
        }
        out_lines.push_back(line);
    }

    if (!has_tran) {
        if (has_end) out_lines.insert(out_lines.end() - 1, ".tran 1n 1000");
        else         out_lines.push_back(".tran 1n 1e12");
    }
    if (!has_end) out_lines.push_back(".end");

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
#else
    if (initialized) ngSpice_Command((char*)"halt");
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
    if (count % 64 == 0) {
        call_deferred("emit_signal", "simulation_data_ready", sample);
    }
}