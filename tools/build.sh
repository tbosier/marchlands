#!/usr/bin/env bash
# Marchlands build / verify pipeline.
#
#   tools/build.sh assets      regenerate every asset from its generator
#   tools/build.sh validate    check generated assets against the style spec
#   tools/build.sh shaders     compile the shaders on a real GL driver
#   tools/build.sh test        assets + regressions + scenarios + rendering + endurance
#   tools/build.sh previews    render turntable previews
#   tools/build.sh icons       render the build-tray icons
#   tools/build.sh sync        copy generated assets into the Godot project
#   tools/build.sh import      let Godot import the assets
#   tools/build.sh run         play the game
#   tools/build.sh harness S   run scripted scenario S headlessly + screenshot
#   tools/build.sh all         assets -> validate -> sync -> import -> shaders
#
# Blender and Godot are looked for on PATH first (`pacman -S blender godot`),
# then in tools/vendor/ for a self-contained checkout.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

find_tool() {
	local name="$1"
	if command -v "$name" >/dev/null 2>&1; then
		command -v "$name"
	elif [[ -x "$ROOT/tools/vendor/$name" ]]; then
		echo "$ROOT/tools/vendor/$name"
	else
		echo ""
	fi
}

BLENDER="${BLENDER:-$(find_tool blender)}"
GODOT="${GODOT:-$(find_tool godot)}"

# Every Godot invocation goes through godot_env.sh, which redirects Godot's
# config, cache and data directories into .godot-home/. Calling the binary
# directly works right up until it silently writes editor settings into the
# user's ~/.config — which is the one thing a self-contained checkout must not
# do, and which fails outright on a machine where that path is not writable.
godot() {
	GODOT="$GODOT" "$ROOT/tools/godot_env.sh" "$@"
}

require() {
	if [[ -z "${!1}" ]]; then
		echo "error: $1 not found. Install it (pacman -S ${2}) or place a" >&2
		echo "       binary at tools/vendor/${2}." >&2
		exit 1
	fi
}

# Run a Blender pipeline step, keeping its exit status and its stderr.
#
# Three things have to be true at once and each of them was once false:
#
#   * a failed or missing Blender must not be swallowed by the pipe (pipefail,
#     set globally at the top of this file);
#   * the failure message must actually be reached — the pipeline has to run
#     inside `if !`, or `set -e` kills the script at the pipe itself and the
#     diagnostic below it is dead code;
#   * stderr must not be folded into the grep. Filtering combined output threw
#     away every line of the generator's traceback, so a broken asset reported
#     which asset had failed and never why.
run_blender_step() {
	local what="$1" script="$2" filter="$3"
	shift 3
	# --python-exit-code, or Blender reports success after a script raises:
	# its Python exception exit code defaults to zero, so a generator that
	# threw would print a traceback and still leave the build green.
	local status=0
	if ! "$BLENDER" -b --python-exit-code 1 -P "$script" -- "$@" \
			| { grep -E "$filter" || true; }; then
		status=${PIPESTATUS[0]}
		[[ $status -eq 0 ]] && status=1
	fi
	if [[ $status -ne 0 ]]; then
		echo "error: $what failed (exit $status)" >&2
		exit "$status"
	fi
}

cmd_assets() {
	require BLENDER blender
	echo "==> generating assets"
	run_blender_step "asset generation" tools/blender/generate_assets.py \
		'^  (OK|FAIL)|^=== |^failed' "$@"
}

cmd_validate() {
	echo "==> validating assets"
	python3 tools/validators/validate_assets.py "$@"
}

cmd_shaders() {
	require GODOT godot
	echo "==> compiling shaders"
	# A separate target because the harness cannot do this job. Break a shader
	# and run any of the eighteen scenarios headlessly: Godot prints SHADER
	# ERROR, then exits 0, and the scenario prints ALL CHECKS PASSED. The
	# diagnostic is there and nothing whatever reads it. (Measured, not
	# assumed — with water.gdshader broken, smoke.json still passes.)
	#
	# So this runs the shaders past a real GL driver instead, which headless
	# never does at any point, and reads what the engine says about them. The
	# checker exits non-zero itself, which is the only reason this does not
	# need the `if !` dance the Blender steps do.
	#
	# GODOT is exported rather than left to the checker's own search, so that a
	# `GODOT=... tools/build.sh shaders` picks the same binary here as anywhere
	# else in this file. The checker still starts Godot through godot_env.sh,
	# so Godot itself writes nothing outside .godot-home/ — though xvfb-run,
	# which is not ours and sits outside that wrapper, does make a short-lived
	# authority file under TMPDIR.
	GODOT="$GODOT" python3 tools/validators/check_shaders.py "$@"
}

cmd_previews() {
	require BLENDER blender
	echo "==> rendering previews"
	# `| grep … || true` used to mask the whole pipeline: Blender could die
	# three previews in, and this still exited 0 and rebuilt the contact sheet
	# out of whatever PNGs happened to be on disk. That is how the committed
	# sheet came to be missing five assets.
	run_blender_step "preview render" tools/blender/render_previews.py \
		' -> ' "$@"
	python3 tools/validators/contact_sheet.py
}

cmd_icons() {
	require BLENDER blender
	echo "==> rendering build-tray icons"
	run_blender_step "icon render" tools/blender/render_icons.py ' -> ' "$@"
}

cmd_sync() {
	echo "==> syncing assets into the Godot project"
	mkdir -p game/assets/generated
	rsync -a --delete \
		--exclude '*.import' \
		assets/generated/ game/assets/generated/
	if [[ -d assets/icons ]]; then
		mkdir -p game/assets/icons
		# --delete here too, or an icon removed upstream lingers in the Godot
		# project for ever, exactly as a stale mesh would.
		rsync -a --delete --exclude '*.import' \
			assets/icons/ game/assets/icons/
	fi
	echo "    $(find game/assets/generated -name '*.glb' | wc -l) glb files, \
$(find game/assets/icons -name '*.png' 2>/dev/null | wc -l) icons"
}

cmd_import() {
	require GODOT godot
	echo "==> importing into Godot"
	local status=0
	if ! godot --headless --path game --import --quit-after 600 2>&1 \
			| { grep -viE '^$|WARNING|Godot Engine v|^Editor|opengl|vulkan' \
				|| true; }; then
		status=${PIPESTATUS[0]}
		[[ $status -eq 0 ]] && status=1
	fi
	if [[ $status -ne 0 ]]; then
		echo "error: Godot import failed (exit $status)" >&2
		exit "$status"
	fi
}

cmd_run() {
	require GODOT godot
	godot --path game "$@"
}

cmd_test() {
	require GODOT godot
	GODOT="$GODOT" python3 tools/verify.py "$@"
}

cmd_harness() {
	require GODOT godot
	local script="${1:-tools/scenes/first_road.json}"
	shift || true
	mkdir -p artifacts
	echo "==> running harness: $script"
	godot --path game --resolution 1600x900 "$@" -- "--harness=$script"
}

cmd_all() {
	cmd_assets
	cmd_validate
	cmd_sync
	cmd_import
	cmd_shaders
	echo "==> done"
}

case "${1:-all}" in
	assets)   shift; cmd_assets "$@" ;;
	validate) shift; cmd_validate "$@" ;;
	shaders)  shift; cmd_shaders "$@" ;;
	test)     shift; cmd_test "$@" ;;
	previews) shift; cmd_previews "$@" ;;
	icons)    shift; cmd_icons "$@" ;;
	sync)     shift; cmd_sync ;;
	import)   shift; cmd_import ;;
	run)      shift; cmd_run "$@" ;;
	harness)  shift; cmd_harness "$@" ;;
	all)      cmd_all ;;
	*)
		sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
		exit 1
		;;
esac
