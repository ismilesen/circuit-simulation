#include "circuit_sim.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>
#include <vector>
#include <string>

using namespace godot;

// Static instance for callbacks
CircuitSimulator* CircuitSimulator::instance = nullptr;

// Callback functions for ngspice
static int ng_send_char(char *output, int id, void *user_data) {
    if (CircuitSimulator::instance) {
        CircuitSimulator::instance->emit_signal("ngspice_output", String(output));
    }
    UtilityFunctions::print(String("[ngspice] ") + String(output));
    return 0;
}

static int ng_send_stat(char *status, int id, void *user_data) {
    // Status updates during simulation
    return 0;
}

static int ng_controlled_exit(int status, bool immediate, bool exit_on_quit, int id, void *user_data) {
    UtilityFunctions::print("ngspice exit requested");
    return 0;
}

static int ng_send_data(pvecvaluesall data, int count, int id, void *user_data) {
    // Called during simulation with new data points
    if (CircuitSimulator::instance) {
        Dictionary dict;
        for (int i = 0; i < data->veccount; i++) {
            pvecvalues vec = data->vecsa[i];
            dict[String(vec->name)] = vec->creal;
        }
        CircuitSimulator::instance->emit_signal("simulation_data_ready", dict);
    }
    return 0;
}

static int ng_send_init_data(pvecinfoall data, int id, void *user_data) {
    // Called before simulation with vector info
    UtilityFunctions::print(String("Simulation initialized with ") + String::num_int64(data->veccount) + " vectors");
    return 0;
}

static int ng_bg_thread_running(bool running, int id, void *user_data) {
    if (CircuitSimulator::instance) {
        if (running) {
            CircuitSimulator::instance->emit_signal("simulation_started");
        } else {
            CircuitSimulator::instance->emit_signal("simulation_finished");
        }
    }
    return 0;
}

// Callback for interactive voltage source control
static int ng_get_vsrc_data(double *voltage, double time, char *node_name, int id, void *user_data) {
    if (CircuitSimulator::instance) {
        *voltage = CircuitSimulator::instance->get_voltage_source(String(node_name));
    }
    return 0;
}

void CircuitSimulator::_bind_methods() {
    // Initialization methods
    ClassDB::bind_method(D_METHOD("initialize_ngspice"), &CircuitSimulator::initialize_ngspice);
    ClassDB::bind_method(D_METHOD("shutdown_ngspice"), &CircuitSimulator::shutdown_ngspice);
    ClassDB::bind_method(D_METHOD("is_initialized"), &CircuitSimulator::is_initialized);

    // Circuit loading
    ClassDB::bind_method(D_METHOD("load_netlist", "netlist_path"), &CircuitSimulator::load_netlist);
    ClassDB::bind_method(D_METHOD("load_netlist_string", "netlist_content"), &CircuitSimulator::load_netlist_string);
    ClassDB::bind_method(D_METHOD("get_current_netlist"), &CircuitSimulator::get_current_netlist);

    // Simulation control
    ClassDB::bind_method(D_METHOD("run_simulation"), &CircuitSimulator::run_simulation);
    ClassDB::bind_method(D_METHOD("run_transient", "step", "stop", "start"), &CircuitSimulator::run_transient, DEFVAL(0.0));
    ClassDB::bind_method(D_METHOD("run_dc", "source", "start", "stop", "step"), &CircuitSimulator::run_dc);
    ClassDB::bind_method(D_METHOD("stop_simulation"), &CircuitSimulator::stop_simulation);
    ClassDB::bind_method(D_METHOD("is_running"), &CircuitSimulator::is_running);

    // Data retrieval
    ClassDB::bind_method(D_METHOD("get_voltage", "node_name"), &CircuitSimulator::get_voltage);
    ClassDB::bind_method(D_METHOD("get_current", "source_name"), &CircuitSimulator::get_current);
    ClassDB::bind_method(D_METHOD("get_time_vector"), &CircuitSimulator::get_time_vector);
    ClassDB::bind_method(D_METHOD("get_all_vectors"), &CircuitSimulator::get_all_vectors);
    ClassDB::bind_method(D_METHOD("get_all_vector_names"), &CircuitSimulator::get_all_vector_names);

    // Interactive control
    ClassDB::bind_method(D_METHOD("set_voltage_source", "source_name", "voltage"), &CircuitSimulator::set_voltage_source);
    ClassDB::bind_method(D_METHOD("get_voltage_source", "source_name"), &CircuitSimulator::get_voltage_source);

    // Signals
    ADD_SIGNAL(MethodInfo("simulation_started"));
    ADD_SIGNAL(MethodInfo("simulation_finished"));
    ADD_SIGNAL(MethodInfo("simulation_data_ready", PropertyInfo(Variant::DICTIONARY, "data")));
    ADD_SIGNAL(MethodInfo("ngspice_output", PropertyInfo(Variant::STRING, "message")));
}

CircuitSimulator::CircuitSimulator() {
    initialized = false;
    current_netlist = "";
    ngspice_handle = nullptr;
    ng_Init = nullptr;
    ng_Init_Sync = nullptr;
    ng_Command = nullptr;
    ng_GetVecInfo = nullptr;
    ng_CurPlot = nullptr;
    ng_AllPlots = nullptr;
    ng_AllVecs = nullptr;
    ng_Circ = nullptr;
    ng_Running = nullptr;
    instance = this;
}

CircuitSimulator::~CircuitSimulator() {
    if (initialized) {
        shutdown_ngspice();
    }
    if (instance == this) {
        instance = nullptr;
    }
}

bool CircuitSimulator::load_ngspice_library() {
#ifdef _WIN32
    ngspice_handle = LoadLibraryA("ngspice.dll");
    if (!ngspice_handle) {
        // Try loading from bin folder
        ngspice_handle = LoadLibraryA("bin/ngspice.dll");
    }
    if (!ngspice_handle) {
        UtilityFunctions::printerr("Failed to load ngspice.dll");
        return false;
    }

    ng_Init = (int (*)(SendChar*, SendStat*, ControlledExit*, SendData*, SendInitData*, BGThreadRunning*, void*))
        GetProcAddress(ngspice_handle, "ngSpice_Init");
    ng_Init_Sync = (int (*)(GetVSRCData*, GetISRCData*, GetSyncData*, int*, void*))
        GetProcAddress(ngspice_handle, "ngSpice_Init_Sync");
    ng_Command = (int (*)(char*))
        GetProcAddress(ngspice_handle, "ngSpice_Command");
    ng_GetVecInfo = (pvector_info (*)(char*))
        GetProcAddress(ngspice_handle, "ngGet_Vec_Info");
    ng_CurPlot = (char* (*)())
        GetProcAddress(ngspice_handle, "ngSpice_CurPlot");
    ng_AllPlots = (char** (*)())
        GetProcAddress(ngspice_handle, "ngSpice_AllPlots");
    ng_AllVecs = (char** (*)(char*))
        GetProcAddress(ngspice_handle, "ngSpice_AllVecs");
    ng_Circ = (int (*)(char**))
        GetProcAddress(ngspice_handle, "ngSpice_Circ");
    ng_Running = (bool (*)())
        GetProcAddress(ngspice_handle, "ngSpice_running");
#else
    ngspice_handle = dlopen("libngspice.so", RTLD_NOW);
    if (!ngspice_handle) {
        ngspice_handle = dlopen("./libngspice.so", RTLD_NOW);
    }
    if (!ngspice_handle) {
        UtilityFunctions::printerr("Failed to load libngspice.so: " + String(dlerror()));
        return false;
    }

    ng_Init = (int (*)(SendChar*, SendStat*, ControlledExit*, SendData*, SendInitData*, BGThreadRunning*, void*))
        dlsym(ngspice_handle, "ngSpice_Init");
    ng_Init_Sync = (int (*)(GetVSRCData*, GetISRCData*, GetSyncData*, int*, void*))
        dlsym(ngspice_handle, "ngSpice_Init_Sync");
    ng_Command = (int (*)(char*))
        dlsym(ngspice_handle, "ngSpice_Command");
    ng_GetVecInfo = (pvector_info (*)(char*))
        dlsym(ngspice_handle, "ngGet_Vec_Info");
    ng_CurPlot = (char* (*)())
        dlsym(ngspice_handle, "ngSpice_CurPlot");
    ng_AllPlots = (char** (*)())
        dlsym(ngspice_handle, "ngSpice_AllPlots");
    ng_AllVecs = (char** (*)(char*))
        dlsym(ngspice_handle, "ngSpice_AllVecs");
    ng_Circ = (int (*)(char**))
        dlsym(ngspice_handle, "ngSpice_Circ");
    ng_Running = (bool (*)())
        dlsym(ngspice_handle, "ngSpice_running");
#endif

    if (!ng_Init || !ng_Command) {
        UtilityFunctions::printerr("Failed to load required ngspice functions");
        unload_ngspice_library();
        return false;
    }

    return true;
}

void CircuitSimulator::unload_ngspice_library() {
#ifdef _WIN32
    if (ngspice_handle) {
        FreeLibrary(ngspice_handle);
        ngspice_handle = nullptr;
    }
#else
    if (ngspice_handle) {
        dlclose(ngspice_handle);
        ngspice_handle = nullptr;
    }
#endif
}

bool CircuitSimulator::initialize_ngspice() {
    if (initialized) {
        UtilityFunctions::print("ngspice already initialized");
        return true;
    }

    if (!load_ngspice_library()) {
        return false;
    }

    int ret = ng_Init(
        ng_send_char,
        ng_send_stat,
        ng_controlled_exit,
        ng_send_data,
        ng_send_init_data,
        ng_bg_thread_running,
        this
    );

    if (ret != 0) {
        UtilityFunctions::printerr("ngSpice_Init failed with code: " + String::num_int64(ret));
        unload_ngspice_library();
        return false;
    }

    // Set up voltage source callback for interactive control
    if (ng_Init_Sync) {
        ng_Init_Sync(ng_get_vsrc_data, nullptr, nullptr, nullptr, this);
    }

    initialized = true;
    UtilityFunctions::print("ngspice initialized successfully");
    return true;
}

void CircuitSimulator::shutdown_ngspice() {
    if (!initialized) {
        return;
    }

    if (ng_Command) {
        ng_Command((char*)"quit");
    }

    unload_ngspice_library();
    initialized = false;
    UtilityFunctions::print("ngspice shut down");
}

bool CircuitSimulator::is_initialized() const {
    return initialized;
}

bool CircuitSimulator::load_netlist(const String &netlist_path) {
    if (!initialized) {
        UtilityFunctions::printerr("ngspice not initialized");
        return false;
    }

    CharString path_utf8 = netlist_path.utf8();
    std::string cmd = "source " + std::string(path_utf8.get_data());
    int ret = ng_Command((char*)cmd.c_str());

    if (ret != 0) {
        UtilityFunctions::printerr("Failed to load netlist: " + netlist_path);
        return false;
    }

    current_netlist = netlist_path;
    UtilityFunctions::print("Loaded netlist: " + netlist_path);
    return true;
}

bool CircuitSimulator::load_netlist_string(const String &netlist_content) {
    if (!initialized) {
        UtilityFunctions::printerr("ngspice not initialized");
        return false;
    }

    if (!ng_Circ) {
        UtilityFunctions::printerr("ngSpice_Circ not available");
        return false;
    }

    // Split netlist into lines
    PackedStringArray lines = netlist_content.split("\n");
    std::vector<char*> circ_lines;
    std::vector<std::string> line_storage;

    for (int i = 0; i < lines.size(); i++) {
        line_storage.push_back(std::string(lines[i].utf8().get_data()));
        circ_lines.push_back((char*)line_storage.back().c_str());
    }
    circ_lines.push_back(nullptr);  // Null terminator

    int ret = ng_Circ(circ_lines.data());

    if (ret != 0) {
        UtilityFunctions::printerr("Failed to load netlist from string");
        return false;
    }

    current_netlist = netlist_content;
    UtilityFunctions::print("Loaded netlist from string");
    return true;
}

String CircuitSimulator::get_current_netlist() const {
    return current_netlist;
}

bool CircuitSimulator::run_simulation() {
    if (!initialized) {
        UtilityFunctions::printerr("ngspice not initialized");
        return false;
    }

    int ret = ng_Command((char*)"bg_run");
    return ret == 0;
}

bool CircuitSimulator::run_transient(double step, double stop, double start) {
    if (!initialized) {
        UtilityFunctions::printerr("ngspice not initialized");
        return false;
    }

    char cmd[256];
    snprintf(cmd, sizeof(cmd), "tran %g %g %g", step, stop, start);
    int ret = ng_Command(cmd);

    return ret == 0;
}

bool CircuitSimulator::run_dc(const String &source, double start, double stop, double step) {
    if (!initialized) {
        UtilityFunctions::printerr("ngspice not initialized");
        return false;
    }

    CharString source_utf8 = source.utf8();
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "dc %s %g %g %g", source_utf8.get_data(), start, stop, step);
    int ret = ng_Command(cmd);

    return ret == 0;
}

void CircuitSimulator::stop_simulation() {
    if (!initialized) {
        return;
    }

    ng_Command((char*)"bg_halt");
    UtilityFunctions::print("Simulation stopped");
}

bool CircuitSimulator::is_running() const {
    if (!initialized || !ng_Running) {
        return false;
    }
    return ng_Running();
}

Array CircuitSimulator::get_voltage(const String &node_name) {
    Array result;

    if (!initialized || !ng_GetVecInfo) {
        return result;
    }

    CharString name_utf8 = (String("v(") + node_name + ")").utf8();
    pvector_info vec = ng_GetVecInfo((char*)name_utf8.get_data());

    if (vec && vec->v_realdata) {
        for (int i = 0; i < vec->v_length; i++) {
            result.append(vec->v_realdata[i]);
        }
    }

    return result;
}

Array CircuitSimulator::get_current(const String &source_name) {
    Array result;

    if (!initialized || !ng_GetVecInfo) {
        return result;
    }

    CharString name_utf8 = (String("i(") + source_name + ")").utf8();
    pvector_info vec = ng_GetVecInfo((char*)name_utf8.get_data());

    if (vec && vec->v_realdata) {
        for (int i = 0; i < vec->v_length; i++) {
            result.append(vec->v_realdata[i]);
        }
    }

    return result;
}

Array CircuitSimulator::get_time_vector() {
    Array result;

    if (!initialized || !ng_GetVecInfo) {
        return result;
    }

    pvector_info vec = ng_GetVecInfo((char*)"time");

    if (vec && vec->v_realdata) {
        for (int i = 0; i < vec->v_length; i++) {
            result.append(vec->v_realdata[i]);
        }
    }

    return result;
}

Dictionary CircuitSimulator::get_all_vectors() {
    Dictionary result;

    if (!initialized || !ng_CurPlot || !ng_AllVecs || !ng_GetVecInfo) {
        return result;
    }

    char* cur_plot = ng_CurPlot();
    if (!cur_plot) {
        return result;
    }

    char** all_vecs = ng_AllVecs(cur_plot);
    if (!all_vecs) {
        return result;
    }

    for (int i = 0; all_vecs[i] != nullptr; i++) {
        pvector_info vec = ng_GetVecInfo(all_vecs[i]);
        if (vec && vec->v_realdata) {
            Array data;
            for (int j = 0; j < vec->v_length; j++) {
                data.append(vec->v_realdata[j]);
            }
            result[String(all_vecs[i])] = data;
        }
    }

    return result;
}

PackedStringArray CircuitSimulator::get_all_vector_names() {
    PackedStringArray result;

    if (!initialized || !ng_CurPlot || !ng_AllVecs) {
        return result;
    }

    char* cur_plot = ng_CurPlot();
    if (!cur_plot) {
        return result;
    }

    char** all_vecs = ng_AllVecs(cur_plot);
    if (!all_vecs) {
        return result;
    }

    for (int i = 0; all_vecs[i] != nullptr; i++) {
        result.append(String(all_vecs[i]));
    }

    return result;
}

void CircuitSimulator::set_voltage_source(const String &source_name, double voltage) {
    voltage_sources[source_name] = voltage;
    UtilityFunctions::print("Set " + source_name + " to " + String::num(voltage) + "V");
}

double CircuitSimulator::get_voltage_source(const String &source_name) {
    if (voltage_sources.has(source_name)) {
        return (double)voltage_sources[source_name];
    }
    return 0.0;
}
