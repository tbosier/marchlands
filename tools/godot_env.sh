#!/usr/bin/env bash
# Run Godot with its config/cache/user directories inside the repo.
#
# Keeps a checkout self-contained (nothing lands in ~/.config or ~/.local) and
# means the harness's screenshots and logs are always findable at a known path.
# Everything it creates lives under .godot-home/, which is gitignored. The
# verification gate uses MARCHLANDS_GODOT_HOME to isolate its saves/settings.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_USER_DIR="${MARCHLANDS_GODOT_HOME:-$ROOT/.godot-home}"
mkdir -p "$GODOT_USER_DIR"/{data,config,cache}

export XDG_DATA_HOME="$GODOT_USER_DIR/data"
export XDG_CONFIG_HOME="$GODOT_USER_DIR/config"
export XDG_CACHE_HOME="$GODOT_USER_DIR/cache"

GODOT_BIN="${GODOT:-}"
if [[ -z "$GODOT_BIN" ]]; then
	if command -v godot >/dev/null 2>&1; then
		GODOT_BIN="$(command -v godot)"
	elif [[ -x "$ROOT/tools/vendor/godot" ]]; then
		GODOT_BIN="$ROOT/tools/vendor/godot"
	else
		echo "error: godot not found (pacman -S godot)" >&2
		exit 1
	fi
fi

exec "$GODOT_BIN" "$@"
