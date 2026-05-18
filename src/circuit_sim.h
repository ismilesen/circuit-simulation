#ifndef CIRCUIT_SIM_H
#define CIRCUIT_SIM_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <thread>

// Platform-specific dynamic loading headers (desktop only).
// On web, ngspice symbols are resolved at link time from the preloaded side module.
#ifndef __EMSCRIPTEN__
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif
#endif

#include "ngspice_types.h"

// Web only: declare ngspice symbols directly so the linker resolves them
// from the preloaded Emscripten side module (libngspice.so).
// On Windows/Linux these are loaded at runtime via LoadLibrary/dlopen instead.
#ifdef __EMSCRIPTEN__
extern "C" {
    int ngSpice_Init(SendChar*, SendStat*, ControlledExit*, SendData*, SendInitData*,
                     BGThreadRunning*, void*);
    int ngSpice_Command(char*);
    int ngSpice_Circ(char**);
    bool ngSpice_running();
}
#endif

namespace godot {

class CircuitSimulator : public Node {
    GDCLASS(CircuitSimulator, Node)

private:
    bool initialized;
    String current_netlist;

    // ── Desktop only: dynamic library handle and function pointers ────────────
    // On web, ngspice symbols are linked directly (see extern "C" above).
#ifndef __EMSCRIPTEN__
#ifdef _WIN32
    HMODULE ngspice_handle;
#else
    void* ngspice_handle;
#endif
    int  (*ng_Init)(SendChar*, SendStat*, ControlledExit*, SendData*, SendInitData*,
                    BGThreadRunning*, void*);
    int  (*ng_Command)(char*);
    int  (*ng_Circ)(char**);
    bool (*ng_Running)();

    bool load_ngspice_library();
    void unload_ngspice_library();
#endif
    // ─────────────────────────────────────────────────────────────────────────

    std::mutex ng_command_mutex;

    // Continuous transient state
    std::thread continuous_thread;
    std::atomic<bool> continuous_stop_requested;
    std::atomic<bool> continuous_running;
    std::atomic<int64_t> continuous_sample_count;
    int64_t continuous_sleep_ms;
    void stop_continuous_thread();

    // Vector name cache populated by ng_send_init_data
    PackedStringArray callback_signal_names;
    std::atomic<int32_t> callback_time_index;
    mutable std::mutex names_mutex;

protected:
    static void _bind_methods();

public:
    CircuitSimulator();
    ~CircuitSimulator();

    bool initialize_ngspice();
    void shutdown_ngspice();

    bool run_continuous(const String &spice_path, const String &pdk_root = "");
    void stop_continuous();
    bool is_running() const;

    Dictionary xschem_to_spice(
        const String &schematic_path,
        const String &output_path,
        const String &xschemrc_path = "",
        const PackedStringArray &symbol_dirs = PackedStringArray()
    );

    void ingest_signal_names(const PackedStringArray &names);
    void ingest_sample(const PackedFloat64Array &sample);

    static CircuitSimulator* instance;
};

} // namespace godot

#endif // CIRCUIT_SIM_H
