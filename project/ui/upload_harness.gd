extends Node

const SIM_SCRIPT_PATH := "res://simulator/circuit_simulator.gd"
const UI_SCENE_PATH := "res://ui/upload_panel.tscn"

var sim_instance: Node = null

func _ready() -> void:
	_instance_simulator_scene()
	_instance_ui()

func _instance_simulator_scene() -> void:
	var sim_script := load(SIM_SCRIPT_PATH)
	if not (sim_script is Script):
		push_error("Could not load %s" % SIM_SCRIPT_PATH)
		return

	sim_instance = (sim_script as Script).new()
	if sim_instance == null:
		push_error("Could not instantiate %s" % SIM_SCRIPT_PATH)
		return

	sim_instance.name = "CircuitSimulator"
	add_child(sim_instance)

func _instance_ui() -> void:
	var ui_packed := load(UI_SCENE_PATH)
	if ui_packed == null:
		push_error("Could not load %s" % UI_SCENE_PATH)
		return

	if not has_node("UILayer"):
		push_error("UploadHarness is missing a node named 'UILayer' (CanvasLayer).")
		return

	var ui := (ui_packed as PackedScene).instantiate()
	$UILayer.add_child(ui)

	# Wire simulator_path (relative path from panel to simulator)
	if ("simulator_path" in ui) and sim_instance != null:
		ui.set("simulator_path", ui.get_path_to(sim_instance))
