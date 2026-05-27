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
#include <map>       // NEW: needed for switch_voltages
#include <mutex>
#include <string>    // NEW: needed for std::string keys in switch_voltages
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
    int ngSpice_Init_Sync(GetVSRCData*, GetISRCData*, GetSyncData*, int*, void*);
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
    // NEW: ngSpice_Init_Sync registers the GetVSRCData callback that ngspice
    // calls every timestep for every EXTERNAL voltage source in the netlist.
    // This pointer may be null on older ngspice builds — we soft-fail and warn.
    int  (*ng_InitSync)(GetVSRCData*, GetISRCData*, GetSyncData*, int*, void*);
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

    // ── Switch / EXTERNAL voltage source state ────────────────────────────────
    //
    // When the netlist contains a line like:
    //   VBUTTON1 OUT VGND external
    // ngspice calls ng_get_vsrc_data() each timestep, passing the source name
    // in lowercase (e.g. "vbutton1") and expecting a voltage written into *value.
    //
    // We maintain a map from lowercase source name → current voltage.
    // The map itself is protected by switch_mutex for insertions/lookups;
    // individual values are stored as doubles guarded by the same mutex (a plain
    // double is sufficient here because writes always happen on the main/UI
    // thread while reads happen on the ngspice callback thread, and double
    // writes are atomic on all our target architectures when the value is
    // properly aligned — but we take the mutex anyway for correctness).
    //
    // Lifecycle:
    //   1. run_continuous() scans the expanded netlist for EXTERNAL V sources
    //      and pre-populates switch_voltages with 0.0 for each one.
    //   2. set_switch_voltage() (callable from GDScript) updates the value live
    //      while the simulation is running; the next timestep picks it up.
    //   3. stop_continuous_thread() / new run_continuous() clears the map.


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

    // NEW: Set the voltage for a named EXTERNAL source while the simulation is
    // running.  `source_name` is the SPICE element name (e.g. "VBUTTON1");
    // matching is case-insensitive.  `voltage` is in volts (0.0 = off, 1.8 = on
    // for Sky130 logic).  Has no effect if the source name is not in the current
    // netlist.  Safe to call from the main thread while bg_run is active.
    void set_switch_voltage(const String &source_name, double voltage);

    void ingest_signal_names(const PackedStringArray &names);
    void ingest_sample(const PackedFloat64Array &sample);

    static CircuitSimulator* instance;

    std::map<std::string, double> switch_voltages;
    mutable std::mutex switch_mutex;

protected:
    static void _bind_methods();
    
};

} // namespace godot

#endif // CIRCUIT_SIM_H