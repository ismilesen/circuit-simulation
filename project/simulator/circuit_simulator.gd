extends CircuitSimulator

func _ready():
	if OS.has_feature("web"):
		print("Web build: deferring ngspice initialization until run is requested.")
		return

	if initialize_ngspice():
		print("ngspice ready!")
	else:
		print("Failed to initialize ngspice")
