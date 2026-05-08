extends Node

## Scene bootstrap: finds or instantiates the CircuitSimulator GDExtension node,
## then instantiates and wires up the upload UI.

const SIM_SCRIPT_PATH := "res://simulator/circuit_simulator.gd"
const UI_SCENE_PATH := "res://ui/upload_panel.tscn"

var sim_instance: Node = null

func _ready() -> void:
	_find_or_instance_simulator()
	_instance_ui()

func _find_or_instance_simulator() -> void:
	# 1. Find an existing simulator already in the tree (registered by the GDExtension).
	var root := get_tree().root
	for c in root.find_children("*", "", true, false):
		if c is Node and (c as Node).has_method("run_continuous"):
			sim_instance = c as Node
			return

	# 2. GDScript fallback — safe to instantiate because GDScript nodes
	#    do not go through the GDExtension registration path.
	var sim_script: Resource = load(SIM_SCRIPT_PATH)
	if sim_script is GDScript:
		var created: Variant = (sim_script as GDScript).new()
		if created is Node:
			sim_instance = created as Node
			add_child(sim_instance)
			return

	push_warning("UploadHarness: no simulator found — simulation will be unavailable.")

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

	if ("simulator_path" in ui) and sim_instance != null:
		ui.set("simulator_path", ui.get_path_to(sim_instance))
