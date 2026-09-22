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


# --- Actors -----------------------------------------------------------------

## Citizens and soldiers get no visibility range of their own: they are a
## handful of small meshes each, the renderer already culls them, and hiding a
## person the player has selected would be worse than drawing him. What they do
## get is a budget on the *procedural* animation, which is script work the
## renderer cannot cull for us.
##
## `Citizen.update_animation()` writes six Node3D rotations and two positions
## per person per frame, and `Soldier` adds up to five more on top. Each one
## dirties a transform the engine then propagates down the limb. At 1,400
## soldiers this is a large part of the ~30 ms the unit tick costs in a ~73 ms
## frame, and almost none of it survives to the screen: the camera's 47 degrees
## of vertical field of view make its screen 82 m tall at its resting 95 m, so
## a 1.8 m person stands about 23 pixels high on a 1080-line display and his
## arm is one or two pixels wide. That swing is not resolvable frame to frame.
##
## The bands below therefore thin the *rate* of the animation with distance
## rather than the pose itself. Nothing is ever frozen outright — the furthest
## band still updates — because a motionless crowd on the horizon reads as a
## bug in a way that a slightly coarse one does not, and because a hard stop
## would leave a limb stuck in mid-stride for as long as the camera stayed
## back. Only presentation is affected: an actor's position, health, path and
## everything written to a save are computed identically at every distance, and
## `Soldier._refresh_condition()` — which is where death, severed limbs and
## dropped weapons take effect — is never gated on distance at all.
##
## Frustum culling was considered here and rejected. Testing the actor's origin
## against the camera frustum would cull people whose heads are still on
## screen, and would do it at the screen edge, which is exactly where a pan
## drags the seam through the player's attention — the same objection that
## puts the vegetation band past the opening shot rather than inside it.
## Distance has no edge to pop across.
##
## Near edges of the bands, in metres. The first clears the pushed-in view
## where faces are legible; the second clears both the camera's resting 95 m
## and the 78 m a march opens at, so the common overview runs at half rate.
const ACTOR_ANIMATION_BANDS := [55.0, 130.0, 260.0]
## How many frames apart an actor in each band is posed. One entry more than
## BANDS: the last covers everything beyond the last edge.
const ACTOR_ANIMATION_STRIDES := [1, 2, 4, 8]
## The lerp weight that goes with each stride.
##
## `_set_part()` smooths at a fixed 0.35 per frame, which is a rate, not a
## step: posing a limb every fourth frame at 0.35 would make a distant soldier
## converge four times slower and wade through his own walk cycle. These are
## the weights that reach the same place in one step that `stride` steps of
## 0.35 would have, i.e. `1 - 0.65 ** stride`, so thinning the rate costs
## smoothness and not amplitude.
##
## Exactly so only for a target that is standing still; the walk cycle's target
## moves between frames, so these are the right approximation rather than an
## identity. A strided limb lands very near where the unstrided one would have
## and gets there in one jump instead of several, which is the trade.
const ACTOR_ANIMATION_WEIGHTS := [0.35, 0.5775, 0.82149375, 0.96813552]

## Cached once per process frame and shared by every actor. Asking the viewport
## for its camera 1,400 times a frame, and reading a global transform off it
## each time, would eat a good part of what the bands save. The camera position
## is copied rather than the Camera3D kept, so a camera freed between frames
## cannot be dereferenced here.
static var _camera_frame := -1
static var _camera_origin := Vector3.ZERO
static var _camera_present := false


## The lerp weight `actor` should drive its limbs with this frame, or 0.0 when
## this frame's pose can be skipped.
##
## `id` staggers the strided bands, spreading the actors that share a stride
## evenly over the `stride` frames of its cycle rather than letting them all
## come due together — the same reason `Citizen`'s path cache spreads its
## renewals, and for the same measured reason: work that lands evenly costs its
## average, and work that lands together costs its total. Ids congruent modulo
## the stride still share a frame, which is the point: it is a fixed fraction
## of the band each frame, not a fixed set of people.
##
## WITH NO CAMERA — the frames before a viewport has one — every actor is posed
## at full rate, exactly as before this existed.
##
## A headless run is NOT that case, though this comment claimed it was.
## `game.gd` builds the camera rig unconditionally in `_ready`, so `--headless`
## has a live Camera3D like any other run, and headless actors are banded and
## skipped by exactly the rule below. Measured headless, with actors 200 m from
## the rig and so in the stride-4 band: consecutive ids come back 0.0, 0.0, 0.0,
## 0.82149375 rather than 0.35 for every one of them.
##
## Headless is also where the stride is least like a stride.
## `Engine.get_process_frames()` does not advance inside a synchronous
## simulation loop — a test stepping the simulation a thousand times stays on
## one process frame — so `_camera_frame` is constant for the whole loop and the
## staggering picks the same ids every step: an actor whose id is not congruent
## is skipped for the entire run rather than one frame in `stride`. The pose
## that results is stale rather than wrong, and no assertion in the suite reads
## a limb rotation -- the injury tests check which limbs are *visible* -- but a
## test that did would have to drive real process frames to see one move.
static func animation_step(actor: Node3D, id: int) -> float:
	_refresh_camera(actor)
	if not _camera_present:
		return ACTOR_ANIMATION_WEIGHTS[0]

	var away := _camera_origin.distance_squared_to(actor.global_position)
	var band := ACTOR_ANIMATION_BANDS.size()
	for i in ACTOR_ANIMATION_BANDS.size():
		var edge: float = ACTOR_ANIMATION_BANDS[i]
		if away < edge * edge:
			band = i
			break

	var stride: int = ACTOR_ANIMATION_STRIDES[band]
	if stride > 1 and posmod(_camera_frame + id, stride) != 0:
		return 0.0
	return ACTOR_ANIMATION_WEIGHTS[band]


## Take the camera's position for this process frame, once, for everybody.
##
## Process frames and not simulation steps: this is presentation, and a
## fast-forwarded game that takes several simulation steps inside one frame
## draws the result once. All the steps in a frame therefore agree about where
## the camera is, and the last one's pose is the one that is seen.
##
## One cache for the whole tree, not one per viewport: if a frame ever mixes
## actors from two viewports, they all use whichever camera was asked for
## first. The consequence is that some of them are posed from the wrong band —
## a wrong *rate*, never a wrong pose — so this is left simple rather than
## keyed by viewport.
##
## An actor with no viewport is the one asker that must NOT win the cache. It is
## outside the tree — reparented, or on its way to being freed — and knows
## nothing about the camera; answering "no camera" for the whole frame made
## every actor behind it in that frame fall back to full-rate animation, which
## is the entire cost the bands exist to avoid, on whichever frames a detached
## person happened to be asked first. So the frame is claimed only once a
## viewport has actually answered, and the detached actor is posed from the
## previous frame's camera instead. That is one frame of staleness in a camera
## position, and it can change nothing but that actor's animation *rate*, and
## then only if it is sitting on a band edge — the same class of error the
## one-cache-for-two-viewports paragraph above already accepts. Before any
## viewport has ever answered, `_camera_present` is still false and everything
## is posed at full rate, exactly as documented above.
##
## The retry is not free for a session that genuinely has no viewport at all:
## every actor then pays `get_viewport()` each frame instead of one of them
## paying it. That is a null check and a tree walk of a couple of pointers, not
## the global transform read this cache was built to avoid, and a session with
## no viewport is drawing nothing anyway.
static func _refresh_camera(actor: Node3D) -> void:
	var frame := int(Engine.get_process_frames())
	if frame == _camera_frame:
		return
	var viewport := actor.get_viewport()
	if viewport == null:
		return
	_camera_frame = frame
	var camera := viewport.get_camera_3d()
	_camera_present = camera != null
	if camera != null:
		_camera_origin = camera.global_position
