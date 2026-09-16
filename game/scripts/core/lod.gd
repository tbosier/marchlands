class_name LOD
extends RefCounted

## Wires the generated LOD chain up to Godot's own distance culling.
##
## The asset pipeline has produced lod0/lod1/lod2 for every building and tree
## since the beginning, and the game was rendering lod0 at every distance —
## three meshes' worth of work authored and none of it used. Rather than switch
## meshes from script each frame, each LOD MeshInstance3D is given a visibility
## range and the renderer picks one natively. The swap is a hard cut, not a
## fade — see _set_range for why — so the bands below are chosen to put the cut
## where the player is least likely to be looking.
##
## Ranges are in metres from the camera and deliberately generous: the camera
## pulls back to 340 m, and popping is far more objectionable than a few extra
## triangles.
##
## The first band has to clear the camera's *resting* distance, not merely its
## closest. RTSCamera starts at 95 m, so a 70 m band meant every building in a
## default session rendered at lod1 — the player never once saw the detail the
## pipeline spends its triangles on. The band now sits comfortably past the
## opening view, and the levels themselves are authored by detail tier rather
## than decimated, so a distant building is a plainer building, not a broken
## one.

const BUILDING_BANDS := [150.0, 300.0]     ## lod0 -> lod1 -> lod2
## Vegetation's first band had the same problem the buildings' band once had,
## one step further in: RTSCamera rests at 95 m and opens a march at 78 m, so
## an 80 m band put the swap line inside the opening shot — the worst possible
## place for it, since a pan then drags the seam across the middle of the
## screen rather than along its edge. It now clears the resting distance. The
## extra near geometry is affordable because trees are multimeshed — the cost
## is vertices, not draw calls, and a tree is a few hundred triangles.
const VEGETATION_BANDS := [105.0, 235.0]

## The distance past which a *band* stops casting into the shadow map.
##
## It is compared against a band's near edge, not against a running distance,
## so it only ever bites where a band happens to begin beyond it: with the
## building bands below that is lod2, at 300 m, and lod1 keeps casting the
## whole way there. Scattered vegetation does not use this at all — see
## apply_to_multimesh, which drops the far tier's shadows outright.
const SHADOW_CUTOFF := 250.0


## Apply bands to a building's LOD children, which the registry named
## `<asset>_lod0` … `<asset>_lod2`.
static func apply(root: Node3D, bands: Array = BUILDING_BANDS) -> void:
	var levels: Array[MeshInstance3D] = []
	for level in 3:
		var found := _find_lod(root, level)
		if found != null:
			levels.append(found)

	if levels.size() <= 1:
		return

	for i in levels.size():
		var mi := levels[i]
		var begin := 0.0 if i == 0 else float(bands[i - 1])
		var end := 0.0
		if i < bands.size():
			end = float(bands[i])
		_set_range(mi, begin, end)


static func _find_lod(root: Node3D, level: int) -> MeshInstance3D:
	var suffix := "_lod%d" % level
	for child in root.get_children():
		if child is MeshInstance3D and String(child.name).ends_with(suffix):
			return child
	return null


static func _set_range(mi: GeometryInstance3D, begin: float,
					   end: float) -> void:
	mi.visibility_range_begin = begin
	mi.visibility_range_end = end
	# A hard swap, not a cross-fade, and both margins are zero so the two
	# levels never overlap. The fade modes draw both meshes together across the
	# width of the margin, which puts two near-identical surfaces in the same
	# place fighting over the depth buffer; and on the Compatibility renderer
	# the documented support for those modes is not something to rely on
	# without measuring it. A clean cut at a well-chosen distance is cheaper
	# and, in practice, less visible than a bad dissolve.
	mi.visibility_range_begin_margin = 0.0
	mi.visibility_range_end_margin = 0.0
	mi.visibility_range_fade_mode = \
			GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	# Distant geometry in the shadow map is most of the cost of a large scene
	# and little of the benefit. Note that the shadow does go out on the same
	# frame the mesh swaps, because both are driven by the same band edge —
	# there is no way to separate them without a second instance.
	if begin >= SHADOW_CUTOFF:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## MultiMesh cannot vary LOD per instance, so scattered vegetation instead gets
## one MultiMeshInstance3D per level covering a distance band.
static func apply_to_multimesh(near: MultiMeshInstance3D,
							   far: MultiMeshInstance3D,
							   split: float = VEGETATION_BANDS[0]) -> void:
	_set_range(near, 0.0, split)
	_set_range(far, split, 0.0)
	# Every tree past the split stops casting. That is a real compromise and
	# not a free one: a wood's shadows end at the split rather than fading out
	# with distance. It buys the largest single saving in the frame — a forest
	# is tens of thousands of instances — and the fog now carries enough of the
	# distance that the seam is much less obvious than it was.
	far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
