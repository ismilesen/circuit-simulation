class_name SymbolDefinition

## Geometry data parsed from a .sym file.

var lines: Array[Line] = []
var boxes: Array[Box] = []
var polygons: Array[Polygon] = []
var arcs: Array[Arc] = []
var texts: Array[Text] = []

## From K block — component type (e.g. "nmos", "pmos", "label", "ipin").
var type: String = ""
## From K block — default attribute template.
var template: String = ""


class Line:
	var layer: int = 0
	var p1: Vector2
	var p2: Vector2


class Box:
	var layer: int = 0
	var p1: Vector2
	var p2: Vector2
	## Pin name from attributes (e.g. "D", "G", "S", "B").
	var pin_name: String = ""
	## Pin direction from attributes (e.g. "in", "inout").
	var dir: String = ""

	## Center of the bounding box.
	func center() -> Vector2:
		return (p1 + p2) / 2.0


class Polygon:
	var layer: int = 0
	var points: Array[Vector2] = []
	var fill: bool = false


class Arc:
	var layer: int = 0
	var cx: float = 0.0
	var cy: float = 0.0
	var radius: float = 0.0
	var start_angle: float = 0.0
	var sweep_angle: float = 360.0


class Text:
	var text: String = ""
	var x: float = 0.0
	var y: float = 0.0
	var rotation: int = 0
	var mirror: int = 0
	var size_x: float = 0.2
	var size_y: float = 0.2
	var layer: int = -1
