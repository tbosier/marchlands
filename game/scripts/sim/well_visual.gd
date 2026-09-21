class_name WellVisual
extends RefCounted

## A small native asset, using the same scene/footprint contract as the GLBs.
## Primitive geometry is merged into material surfaces, avoiding one draw per
## stone. The scene is cached by AssetRegistry and shared by placed wells.
const METADATA := {
	"asset_id": "well", "category": "building", "footprint_m": [5, 5], "height_m": 4.2,
	"attachments": {"att_entrance": [0, -3.6, 0], "att_cart_bay": [0, -3.6, 0]},
}


static func _material(color: Color, label: String) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.resource_name = label
	material.albedo_color = color
	material.roughness = 0.9
	return material


static func _append(groups: Dictionary, material: Material, mesh: Mesh,
		at: Vector3, rotation: Vector3 = Vector3.ZERO) -> void:
	if not groups.has(material):
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		groups[material] = surface
	var transform := Transform3D(Basis.from_euler(rotation), at)
	groups[material].append_from(mesh, 0, transform)


static func _box(groups: Dictionary, material: Material, size: Vector3,
		at: Vector3, rotation: Vector3 = Vector3.ZERO) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	_append(groups, material, mesh, at, rotation)


static func _cylinder(groups: Dictionary, material: Material, radius: float,
		height: float, at: Vector3, rotation: Vector3 = Vector3.ZERO) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 12
	mesh.rings = 1
	_append(groups, material, mesh, at, rotation)


static func packed_scene() -> PackedScene:
	var groups := {}
	var stone := _material(Color(0.47, 0.46, 0.42), "well_stone")
	var pale := _material(Color(0.56, 0.54, 0.48), "well_stone_pale")
	var dark := _material(Color(0.38, 0.38, 0.35), "well_stone_dark")
	var wood := _material(Color(0.31, 0.20, 0.12), "well_timber")
	var roof := _material(Color(0.43, 0.25, 0.14), "roof_shingles")
	var rope := _material(Color(0.64, 0.55, 0.36), "well_rope")
	var water := _material(Color(0.045, 0.13, 0.15), "well_water")
	water.roughness = 0.2
	var tones := [stone, pale, dark]
	for course in 3:
		for i in 12:
			var angle := TAU * float(i) / 12.0 + (PI / 12.0 if course % 2 else 0.0)
			_box(groups, tones[(i + course) % tones.size()], Vector3(0.65, 0.38, 0.46),
				Vector3(cos(angle) * 1.15, 0.20 + course * 0.39, sin(angle) * 1.15),
				Vector3(0, PI * 0.5 - angle, 0))
	for i in 12:
		var angle := TAU * float(i) / 12.0
		_box(groups, pale, Vector3(0.69, 0.16, 0.54),
			Vector3(cos(angle) * 1.15, 1.26, sin(angle) * 1.15), Vector3(0, PI * 0.5 - angle, 0))
	_cylinder(groups, water, 0.92, 0.07, Vector3(0, 0.09, 0))
	for x in [-1.8, 1.8]:
		_box(groups, wood, Vector3(0.24, 3.25, 0.28), Vector3(x, 1.625, 0))
	_box(groups, wood, Vector3(4.0, 0.20, 0.26), Vector3(0, 3.20, 0))
	for side in [-1.0, 1.0]:
		_box(groups, roof, Vector3(4.4, 0.16, 1.90), Vector3(0, 3.58, side * 0.77),
			Vector3(side * 0.52, 0, 0))
		_box(groups, wood, Vector3(4.48, 0.17, 0.16), Vector3(0, 3.13, side * 1.60))
	_box(groups, wood, Vector3(4.5, 0.18, 0.18), Vector3(0, 4.08, 0))
	_cylinder(groups, wood, 0.14, 3.95, Vector3(0, 2.37, 0), Vector3(0, 0, PI * 0.5))
	_box(groups, wood, Vector3(0.15, 0.58, 0.15), Vector3(2.0, 2.14, 0))
	_cylinder(groups, wood, 0.07, 0.40, Vector3(2.17, 1.88, 0), Vector3(0, 0, PI * 0.5))
	_cylinder(groups, rope, 0.025, 1.32, Vector3(0, 1.63, 0))
	_cylinder(groups, wood, 0.29, 0.43, Vector3(0, 0.78, 0))
	_cylinder(groups, dark, 0.30, 0.04, Vector3(0, 0.97, 0))
	var handle := TorusMesh.new()
	handle.inner_radius = 0.24
	handle.outer_radius = 0.275
	handle.rings = 12
	handle.ring_segments = 6
	_append(groups, dark, handle, Vector3(0, 1.11, 0), Vector3(PI * 0.5, 0, 0))
	var mesh := ArrayMesh.new()
	for material in groups:
		groups[material].commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	var root := Node3D.new()
	root.name = "well"
	var visual := MeshInstance3D.new()
	visual.name = "well_lod0"
	visual.mesh = mesh
	root.add_child(visual)
	visual.owner = root
	var scene := PackedScene.new()
	scene.pack(root)
	root.free()
	return scene
