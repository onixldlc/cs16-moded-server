#!/bin/sh
# Fetch navigation meshes (maps/*.nav) for the zBot bots.
#
# The Condition Zero bots are compiled into ReGameDLL's cs.so and their profiles and
# voices ship in this image -- but a bot cannot move without a navigation mesh for the
# current map, and CS 1.6 has never shipped one:
#   ERROR: Failed to load 'maps/de_dust2.nav' file navigation map!
# The meshes exist in Condition Zero, which steamcmd can install as another mod of the
# same app 90 the game content itself comes from. So they are fetched here, per
# deployment, under the deployer's own Steam Subscriber Agreement -- exactly like the game
# content, and for the same reason: nothing Valve owns is baked into a published image.
#
# Everything except the .nav files is thrown away, so the volume grows by a few MB, not by
# the size of Condition Zero.
#
#   HLDS_DIR    server root, normally the mounted volume (default /opt/hlds)
#   STAGE_DIR   scratch space for the download (default /tmp/hlds-fetch)
#   FORCE_REFETCH_NAV=1   fetch again even if nav files are already installed
#
# Runs once: the marker cstrike/.nav-source records where the meshes came from.
set -eu

HLDS_DIR="${HLDS_DIR:-/opt/hlds}"
STAGE_DIR="${STAGE_DIR:-/tmp/hlds-fetch}"
STEAMCMD_URL="${STEAMCMD_URL:-https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz}"

maps_dir="$HLDS_DIR/cstrike/maps"
marker="$HLDS_DIR/cstrike/.nav-source"
stage="$STAGE_DIR/czero"
steamcmd_dir="$STAGE_DIR/steamcmd-nav"

log() {
	echo "[fetch-nav] $*"
}

nav_count() {
	find "$maps_dir" -maxdepth 1 -name '*.nav' 2>/dev/null | wc -l
}

mkdir -p "$maps_dir"

if [ -f "$marker" ] && [ "${FORCE_REFETCH_NAV:-0}" != "1" ]; then
	log "already done: $(cat "$marker") — $(nav_count) nav files (FORCE_REFETCH_NAV=1 to redo)"
	exit 0
fi

# Someone else's meshes already in place (mounted, or copied in by hand): leave them.
if [ "$(nav_count)" -gt 0 ] && [ "${FORCE_REFETCH_NAV:-0}" != "1" ]; then
	log "$(nav_count) nav files already present — not fetching"
	printf 'pre-existing (not fetched by this image)\n' > "$marker"
	exit 0
fi

log "no nav files in $maps_dir — fetching Condition Zero meshes (a few hundred MB, once)"

rm -rf "$stage" "$steamcmd_dir"
mkdir -p "$stage" "$steamcmd_dir"

log "downloading steamcmd"
curl -sSL -o "$STAGE_DIR/steamcmd-nav.tar.gz" "$STEAMCMD_URL"
tar xzf "$STAGE_DIR/steamcmd-nav.tar.gz" -C "$steamcmd_dir"
rm -f "$STAGE_DIR/steamcmd-nav.tar.gz"

# Same app and same legacy branch as the game content -- only the mod differs. steamcmd
# exits non-zero on transient states, so the result is asserted below instead.
log "running app_update 90 (mod czero)"
"$steamcmd_dir/steamcmd.sh" \
	+force_install_dir "$stage" \
	+login anonymous \
	+app_set_config 90 mod czero \
	+app_update 90 -beta steam_legacy validate \
	+quit || true

if [ ! -d "$stage/czero/maps" ]; then
	log "FAILED: czero/maps missing after app_update — no nav files installed"
	log "set ZBOT_NAV=none to stop trying, or drop your own maps/*.nav into the volume"
	rm -rf "$stage" "$steamcmd_dir"
	exit 0
fi

# Only the meshes. A .nav is keyed to a map name, so one that has no matching .bsp here is
# harmless -- it is simply never read -- and keeping it means a later map change works.
copied=0
for nav in "$stage/czero/maps"/*.nav; do
	[ -f "$nav" ] || continue
	cp -f "$nav" "$maps_dir/"
	copied=$((copied + 1))
done

rm -rf "$stage" "$steamcmd_dir"

if [ "$copied" -eq 0 ]; then
	log "FAILED: czero/maps held no .nav files"
	exit 0
fi

printf 'steamcmd app 90 mod czero\n' > "$marker"
log "installed $copied nav files into $maps_dir"
