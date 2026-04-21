extends Node

var sim: CircuitSimulator
var signal_names: PackedStringArray
var sample_counter: int = 0
const PRINT_STRIDE: int = 64

func _ready():
	sim = CircuitSimulator.new()
	add_child(sim)
	
	sim.simulation_started.connect(_on_simulation_started)
	sim.simulation_finished.connect(_on_simulation_finished)
	sim.continuous_transient_started.connect(_on_continuous_started)
	sim.continuous_transient_stopped.connect(_on_continuous_stopped)
	sim.continuous_transient_frame.connect(_on_frame)
	sim.simulation_data_ready.connect(_on_data_ready)
	sim.ngspice_output.connect(func(msg): print("[ngspice] ", msg))

	if not sim.initialize_ngspice():
		push_error("Failed to initialize ngspice")
		return

	if not sim.load_netlist("C:/Users/Manuel/Desktop/UCSC/Coursework/115B/Circuit/Circuit-Visualization/project/circuits/test_circuit.spice"):
		push_error("Failed to load netlist")
		return

	signal_names = sim.get_continuous_memory_signal_names()
	print("Signal names at load time: ", signal_names)

	sim.start_continuous_transient(1e-9, 1e6)

func _on_simulation_started():
	print("Simulation started")
	signal_names = sim.get_continuous_memory_signal_names()
	print("Signal names after start: ", signal_names)

func _on_simulation_finished():
	print("Simulation finished")

func _on_continuous_started():
	print("Continuous transient started")

func _on_continuous_stopped():
	print("Continuous transient stopped")

func _on_data_ready(sample: PackedFloat64Array):
	if signal_names.is_empty():
		signal_names = sim.get_continuous_memory_signal_names()
	
	sample_counter += 1
	if sample_counter % PRINT_STRIDE != 0:
		return
	print("--- Sample %d ---" % sample_counter)
	for i in range(sample.size()):
		var name = signal_names[i] if i < signal_names.size() else "vec_%d" % i
		print("  %s = %f" % [name, sample[i]])

func _on_frame(frame: Dictionary):
	print("Frame | time=", frame.get("time"), 
		  " sample_count=", frame.get("sample_count"),
		  " step=", frame.get("step"))

func _input(event):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			print("Stopping continuous transient...")
			sim.stop_continuous_transient()
