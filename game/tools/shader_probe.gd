extends SceneTree

## Compile one shader on a real graphics context and report what the engine
## made of it. Driven by tools/validators/check_shaders.py; not part of the
## game, and never loaded by main.tscn.
##
##     godot --path game --rendering-driver opengl3 \
##         --script res://tools/shader_probe.gd -- /abs/path/to/x.gdshader
##
## It prints these machine-readable lines and exits:
##
##     PROBE_UNIFORMS <name,name,...>
##     PROBE_PIXELS   <mean r> <mean g> <mean b>
##     PROBE_DONE
##
## One shader per run, and the shader's path appears on none of those lines.
## Both are deliberate. Godot's diagnostics go to stderr and these markers go
## to stdout; joined into one pipe their relative order is whoever flushed
## first, so a run carrying two shaders could not reliably say which of them an
## error belonged to. And a path printed on a marker line is a path that may
## contain a space, at which point the checker splitting that line on spaces
## reads the first uniform name as part of the directory it came from.
##
## Anything Godot itself has to say about the shader lands on stderr in
## between, and that is the checker's primary signal. PROBE_UNIFORMS is a
## corroborating one: a shader Godot's own parser rejected exposes no uniforms
## at all, so comparing that list against the `uniform` lines in the source
## catches a parse failure even if the wording of the diagnostic changes under
## us. It proves nothing about the *driver* stage, because the list is filled
## in by the parser before any GLSL is generated, so it supplements the
## diagnostics rather than replacing them.
##
## PROBE_PIXELS is for a human reading the log, and is deliberately not
## asserted on. The received wisdom is that a broken spatial shader draws
## magenta and could therefore be caught by looking at the picture; on Godot
## 4.7's Compatibility renderer it does not. It draws as an ordinary lit grey,
## whose variation across the quad measured *lower* than the water shader's
## own. There is no threshold that separates them, so the check is not made.

## Frames to run before reading the viewport back.
##
## Not one. The Compatibility renderer compiles a shader's GLSL variants
## lazily, the first time something is actually drawn with them, so the frame
## that triggers the compile is not necessarily the frame that shows its
## result. Six is comfortably past that and still well under a second.
const WARMUP_FRAMES := 6

## Side of the square the shader is rendered into. Small on purpose: nothing
## here judges the picture, the draw exists only to make the backend compile
## the thing.
const PROBE_SIZE := 64

var _view: SubViewport = null
var _frames := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("shader_probe: expected exactly one shader path, got %d"
				% args.size())
		quit(2)
		return

	# Read the source off disk rather than load()ing a res:// path, for two
	# reasons. The checker has to be able to aim this at a scratch copy of a
	# shader — that is how it proves it can fail — without editing anything
	# under game/shaders/. And load() would hand back whatever Godot has in its
	# resource cache, so a shader could be checked without its current text
	# ever being compiled.
	#
	# The price is that this Shader has no resource path, so a relative
	# `#include` has nothing to resolve against. The checker refuses a shader
	# containing one rather than compile it in a context the game never uses.
	var f := FileAccess.open(args[0], FileAccess.READ)
	if f == null:
		push_error("shader_probe: cannot read %s" % args[0])
		quit(2)
		return
	var source := f.get_as_text()
	f.close()

	var shader := Shader.new()
	# This is the line Godot reports a broken shader on: assigning the code
	# runs the engine's own shader parser, and under the GLES3 driver it also
	# hands the result to the backend.
	shader.code = source

	var names := PackedStringArray()
	for u in shader.get_shader_uniform_list():
		names.append(str(u["name"]))
	print("PROBE_UNIFORMS ", ",".join(names))

	var material := ShaderMaterial.new()
	material.shader = shader
	_view = _make_view(material)
	root.add_child(_view)


## A small off-screen render of one quad wearing the material, lit and on a
## known background. The draw is the point, not the image: the Compatibility
## backend does not build a shader's GLSL until something is drawn with it, so
## a check that only assigned the code would exercise Godot's own parser and
## stop short of the driver.
func _make_view(material: ShaderMaterial) -> SubViewport:
	var view := SubViewport.new()
	view.size = Vector2i(PROBE_SIZE, PROBE_SIZE)
	# Without this the SubViewport shares the *parent* viewport's World3D. That
	# is not a detail: with the world shared, the camera, the light and the
	# quad all go into one scene and the readback is of whatever was added
	# last, so a broken shader can be handed the pixels of a working one.
	view.own_world_3d = true
	view.transparent_bg = false
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	# A fixed environment rather than Godot's default sky, so that the logged
	# average colour means something: the sky would otherwise show through a
	# transparent surface like the water and dominate the ambient term, and two
	# runs of the same shader could be compared only by eye.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1.0, 1.0, 1.0)
	env.ambient_light_energy = 1.0

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 1.0
	cam.position = Vector3(0.0, 0.0, 2.0)
	cam.environment = env
	view.add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.7, 0.4, 0.0)
	view.add_child(light)

	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	# Four metres across, filling a camera one metre wide, so the quad's world
	# coordinates sweep several metres behind the visible square. Both shaders
	# key everything off world position, and on a quad small enough to sit
	# inside a single noise cell the log would show one flat colour that said
	# nothing about whether the shader had run.
	mesh.size = Vector2(4.0, 4.0)
	quad.mesh = mesh
	quad.material_override = material
	view.add_child(quad)

	return view


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < WARMUP_FRAMES:
		return false
	if _view != null:
		_report(_view.get_texture().get_image())
	print("PROBE_DONE")
	return true


## The average colour of the render, logged so that a person looking at a
## failure can see what did get drawn.
func _report(img: Image) -> void:
	var n := float(img.get_width() * img.get_height())
	var total := Vector3.ZERO
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			total += Vector3(c.r, c.g, c.b)
	var mean := total / n
	print("PROBE_PIXELS %.4f %.4f %.4f" % [mean.x, mean.y, mean.z])
