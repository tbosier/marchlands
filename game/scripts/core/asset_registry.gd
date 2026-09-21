class_name AssetRegistry
extends RefCounted

## Loads the Blender-generated assets and the manifests that describe them.
##
## The manifest is the contract between the asset pipeline and the game: the
## game never hardcodes a building's size, height or entrance offset, it reads
## what the generator actually produced. Regenerate an asset larger and the
## placement footprint follows automatically.

const ROOT := "res://assets/generated"
const NativeWell = preload("res://scripts/sim/well_visual.gd")
const FOLDERS := {
	"building": "buildings",
	"prop": "props",
	"vegetation": "vegetation",
	"resource_node": "vegetation",
	"character": "characters",
}

var manifests: Dictionary = {}      # asset_id -> Dictionary
var _scenes: Dictionary = {}        # asset_id -> PackedScene
var _meshes: Dictionary = {}        # "asset_id:lod" -> Mesh
var missing: Array[String] = []


func load_all() -> void:
	for folder in ["buildings", "props", "vegetation", "characters"]:
		var dir := DirAccess.open("%s/%s" % [ROOT, folder])
		if dir == null:
			push_warning("AssetRegistry: missing folder %s/%s" % [ROOT, folder])
			continue
		for file in dir.get_files():
			if not file.ends_with(".json"):
				continue
			var path := "%s/%s/%s" % [ROOT, folder, file]
			var text := FileAccess.get_file_as_string(path)
			var data: Variant = JSON.parse_string(text)
			if typeof(data) != TYPE_DICTIONARY:
				push_warning("AssetRegistry: bad manifest %s" % path)
				continue
			manifests[data["asset_id"]] = data
	manifests["well"] = NativeWell.METADATA.duplicate(true)


func has(asset_id: String) -> bool:
	return manifests.has(asset_id)


func manifest(asset_id: String) -> Dictionary:
	return manifests.get(asset_id, {})


func footprint(asset_id: String) -> Vector2:
	var m: Dictionary = manifest(asset_id)
	if m.is_empty():
		return Vector2(4, 4)
	var f: Array = m.get("footprint_m", [4, 4])
	if f.size() < 2:
		return Vector2(4, 4)
	return Vector2(f[0], f[1])


func height(asset_id: String) -> float:
	var m: Dictionary = manifest(asset_id)
	return float(m.get("height_m", 3.0))


## An attachment point in the asset's local space, converted from the
## exporter's Z-up coordinates to Godot's Y-up.
func attachment(asset_id: String, name: String) -> Vector3:
	var m: Dictionary = manifest(asset_id)
	var atts: Dictionary = m.get("attachments", {})
	if not atts.has(name):
		return Vector3.ZERO
	var a: Array = atts[name]
	return Vector3(a[0], a[2], -a[1])


func has_attachment(asset_id: String, name: String) -> bool:
	var m: Dictionary = manifest(asset_id)
	return m.get("attachments", {}).has(name)


func _scene_path(asset_id: String) -> String:
	var m: Dictionary = manifest(asset_id)
	var folder: String = FOLDERS.get(m.get("category", "prop"), "props")
	return "%s/%s/%s.glb" % [ROOT, folder, asset_id]


func scene(asset_id: String) -> PackedScene:
	if _scenes.has(asset_id):
		return _scenes[asset_id]
	if asset_id == "well":
		_scenes[asset_id] = NativeWell.packed_scene()
		return _scenes[asset_id]
	var path := _scene_path(asset_id)
	if not ResourceLoader.exists(path):
		if not missing.has(asset_id):
			missing.append(asset_id)
		return null
	var res: PackedScene = load(path)
	_scenes[asset_id] = res
	return res


## Godot's glTF importer wraps the file's root node in a scene root of its own,
## so the asset's real hierarchy sits one level down. Everything here works on
## the inner node, which is the one whose transform the exporter authored.
func _unwrap(node: Node3D, asset_id: String) -> Node3D:
	if String(node.name) == asset_id:
		return node
	for child in node.get_children():
		if child is Node3D and String(child.name) == asset_id:
			node.remove_child(child)
			node.queue_free()
			_clear_owner(child)
			return child
	_clear_owner(node)
	return node


func _clear_owner(node: Node) -> void:
	node.owner = null
	for child in node.get_children():
		_clear_owner(child)


## Instantiate an asset, keeping only the one visual mesh the caller asked for.
## `lod` picks which.
func instantiate(asset_id: String, lod: int = 0) -> Node3D:
	var packed := scene(asset_id)
	if packed == null:
		return _placeholder(asset_id)
	var node := _unwrap(packed.instantiate(), asset_id)
	var kept := false
	for child in node.get_children():
		var n := String(child.name)
		if n.contains("_lod"):
			if n.ends_with("_lod%d" % lod):
				kept = true
			else:
				node.remove_child(child)
				child.queue_free()
	if not kept and lod > 0:
		# Asset has no LOD at that level: fall back, and free the tree that was
		# built looking for it rather than leaving it parentless in memory.
		node.queue_free()
		return instantiate(asset_id, 0)
	if node.get_child_count() == 0:
		# Every child was stripped and nothing replaced them, so this would
		# return an empty node rather than the asset. Note the test is for an
		# empty result, not for `kept`: a character is a set of named limb
		# parts with no `_lod` child at all, and keying this on `kept` turned
		# every citizen in the march into a placeholder box.
		node.queue_free()
		return _placeholder(asset_id)
	return node


## A single merged mesh for an asset, for use in MultiMeshInstance3D. Returns
## null if the asset has no mesh at the requested LOD.
func mesh(asset_id: String, lod: int = 0) -> Mesh:
	var key := "%s:%d" % [asset_id, lod]
	if _meshes.has(key):
		return _meshes[key]
	var packed := scene(asset_id)
	if packed == null:
		return null
	var node := _unwrap(packed.instantiate(), asset_id)
	var found: Mesh = null
	for child in node.get_children():
		if child is MeshInstance3D and String(child.name).ends_with("_lod%d" % lod):
			found = child.mesh
			break
	node.free()
	_meshes[key] = found
	return found


## Instantiate keeping the whole LOD chain, with distance bands applied, so the
## renderer swaps between the meshes the pipeline generated.
func instantiate_with_lods(asset_id: String,
						   bands: Array = LOD.BUILDING_BANDS) -> Node3D:
	var packed := scene(asset_id)
	if packed == null:
		return _placeholder(asset_id)
	var node := _unwrap(packed.instantiate(), asset_id)
	LOD.apply(node, bands)
	return node


## Visible stand-in so a missing asset is obvious rather than invisible.
func _placeholder(asset_id: String) -> Node3D:
	var root := Node3D.new()
	root.name = "%s_placeholder" % asset_id
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	var f := footprint(asset_id)
	var h := height(asset_id)
	box.size = Vector3(maxf(f.x, 1.0), maxf(h, 1.0), maxf(f.y, 1.0))
	mi.mesh = box
	mi.position.y = box.size.y * 0.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.2, 0.6)
	mi.material_override = mat
	root.add_child(mi)
	return root
