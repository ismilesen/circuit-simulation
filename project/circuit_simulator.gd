extends CircuitSimulator

func _ready():
	if initialize_ngspice():
		print("ngspice ready!")
	else:
		print("Failed to initialize ngspice")
