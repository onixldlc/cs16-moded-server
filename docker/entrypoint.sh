#!/bin/sh
# Wrapper around the base image's server-entrypoint.sh.
#
# Order is the whole point. The mod tree includes cstrike/liblist.gam, and the Steam
# content download ships Valve's own liblist.gam -- so mods must be installed AFTER the
# content exists and BEFORE hlds_linux starts. The base entrypoint does fetch-and-start
# in one go, so this script front-runs it:
#
#   1. fetch the game content if the volume is empty (same fetch-content.sh)
#   2. fetch the zBot navigation meshes if they are missing, then install/refresh the mods
#   3. generate cs16-moded.cfg (RCON password, EXTRA_CVARS) and make server.cfg exec it
#   4. hand over to the base entrypoint, which now skips its own fetch, copies the
#      engine and game dll from /opt/dist, and execs hlds_linux
#
# Arguments and environment pass through untouched, so INSECURE / MAP / MAXPLAYERS /
# SV_LAN / STEAM_ACCOUNT / FORCE_REFETCH all behave exactly as in cs16-server.
set -e

HLDS_DIR="${HLDS_DIR:-/opt/hlds}"
STAGE_DIR="${STAGE_DIR:-/tmp/hlds-fetch}"
CONTENT_STAGE="${CONTENT_STAGE:-$HLDS_DIR/.content}"

log() {
	echo "[moded] $*"
}

# `verify` is an image self-check, not a server start.
if [ "${1:-}" = "verify" ]; then
	exec /usr/local/bin/verify.sh
fi

# `rcon` drives a server that is already running, so it is also not a server start. Handy
# when the entrypoint is in the way:  docker exec <container> rcon status  works directly,
# this form covers `docker compose run --rm cs16 rcon ...` against a reachable host.
if [ "${1:-}" = "rcon" ]; then
	shift
	exec /usr/local/bin/rcon "$@"
fi

mkdir -p "$HLDS_DIR"

# --- phase 1: game content --------------------------------------------------

# Why the extra staging directory instead of fetching straight into $HLDS_DIR:
# the addons volume is mounted at $HLDS_DIR/cstrike/addons, which means
# $HLDS_DIR/cstrike already exists before any content arrives. fetch-content.sh moves
# its download into place per entry with mv, and mv cannot merge into an existing
# directory -- it fails with
#   mv: cannot move '.../hlds/cstrike' to '/opt/hlds/cstrike': File exists
# So: fetch into an empty dir on the same volume, then merge into place ourselves.
if [ ! -f "$HLDS_DIR/hlds_linux" ] || [ "${FORCE_REFETCH:-0}" = "1" ]; then
	log "no game content in $HLDS_DIR — fetching (first start only, several minutes)"

	rm -rf "$CONTENT_STAGE"
	mkdir -p "$CONTENT_STAGE"

	STAGE_DIR="$STAGE_DIR" HLDS_DIR="$CONTENT_STAGE" /usr/local/bin/fetch-content.sh

	# -l hardlinks instead of copying: same filesystem, so this is instant and costs no
	# extra space, and unlike mv it merges directories. Falls back to a real copy if
	# hardlinks are refused (e.g. the volume is on a filesystem that disallows them).
	log "merging content into $HLDS_DIR"
	if ! cp -al "$CONTENT_STAGE/." "$HLDS_DIR/" 2>/dev/null; then
		log "hardlink merge unavailable — copying instead"
		cp -a "$CONTENT_STAGE/." "$HLDS_DIR/"
	fi

	rm -rf "$CONTENT_STAGE"

	test -f "$HLDS_DIR/hlds_linux" || {
		echo "[moded] FATAL: content fetch finished but $HLDS_DIR/hlds_linux is missing" >&2
		exit 1
	}
	log "content ready in $HLDS_DIR"
fi

# --- phase 1b: zBot navigation meshes ---------------------------------------

# Before the mods, because install-mods.sh reports whether the current map has a mesh.
# zBot cannot move without maps/<map>.nav and CS 1.6 has never shipped one; ZBOT_NAV=czero
# fetches Condition Zero's with steamcmd, once, and keeps only the .nav files.
# ZBOT_NAV=none skips it -- set that if you supply your own.
if [ "${ZBOT_NAV:-czero}" = "czero" ]; then
	HLDS_DIR="$HLDS_DIR" STAGE_DIR="$STAGE_DIR" /usr/local/bin/fetch-nav.sh
fi

# --- phase 2: mods ----------------------------------------------------------

HLDS_DIR="$HLDS_DIR" /usr/local/bin/install-mods.sh

# --- phase 3: rcon password and custom cvars --------------------------------

HLDS_DIR="$HLDS_DIR" /usr/local/bin/configure-server.sh

# --- phase 4: hand over -----------------------------------------------------

log "handing over to server-entrypoint.sh"
exec /usr/local/bin/server-entrypoint.sh "$@"
