#!/bin/sh
# Copy a host-provided directory tree over cstrike/ on every start.
#
# This is the drop-in path for custom content: unzip whatever you have on the host into the
# mounted directory, laid out exactly like cstrike/, and it lands in the server at the next
# start. No copying into volume paths by hand, no unzipping inside the container.
#
#   overlay/server.cfg                     -> cstrike/server.cfg
#   overlay/maps/de_mirage_cs2.bsp         -> cstrike/maps/de_mirage_cs2.bsp
#   overlay/addons/pugmod/cfg/pugmod.cfg   -> cstrike/addons/pugmod/cfg/pugmod.cfg
#
# addons/ needs no special handling even though it is a separate volume: the copy runs
# INSIDE the container, where /opt/hlds/cstrike/addons is already that volume's mount point,
# so the files land where the server actually reads them. Copying into the content volume's
# addons/ directory from the host would write underneath the mount, where nothing sees it.
#
# A zip rooted at cstrike/ is handled too -- if the overlay contains a cstrike/ directory,
# that becomes the source root, so `unzip pack.zip -d overlay` works whichever way the pack
# was built.
#
#   OVERLAY_DIR   default /opt/overlay. Mount it read-only; nothing here writes to it.
#
# Runs AFTER the image's own mods are installed, so the overlay wins over anything the image
# ships. Every start, so the overlay is the source of truth for the files it contains.
#
# It only ever adds and overwrites: deleting a file from the overlay does not remove it from
# the server. Delete it in the volume too if you want it gone.
set -e

HLDS_DIR="${HLDS_DIR:-/opt/hlds}"
OVERLAY_DIR="${OVERLAY_DIR:-/opt/overlay}"

log() {
	echo "[overlay] $*"
}

if [ ! -d "$OVERLAY_DIR" ]; then
	exit 0
fi

# A zip rooted at cstrike/ unpacks to overlay/cstrike/... -- treat that as the root.
src="$OVERLAY_DIR"
if [ -d "$src/cstrike" ]; then
	src="$src/cstrike"
	log "using $src as the source root (cstrike/ found inside the overlay)"
fi

files=$(find "$src" -type f ! -name '.gitkeep' ! -name '.DS_Store' 2>/dev/null | wc -l)

if [ "$files" -eq 0 ]; then
	log "$OVERLAY_DIR is empty — nothing to copy"
	exit 0
fi

# liblist.gam is the mod wiring and install-mods.sh rewrites it on every start, so a copy
# here would be silently reverted. Better to say so than to let it look applied.
if [ -f "$src/liblist.gam" ]; then
	log "warning: liblist.gam in the overlay is ignored — the image manages it"
fi

mkdir -p "$HLDS_DIR/cstrike"

# cp -a "$src/." merges into the existing tree instead of nesting a directory inside it.
cp -a "$src/." "$HLDS_DIR/cstrike/"

log "copied $files files from $OVERLAY_DIR into $HLDS_DIR/cstrike"

for d in maps addons sound models sprites gfx overviews; do
	if [ -d "$src/$d" ]; then
		log "  $d: $(find "$src/$d" -type f | wc -l) files"
	fi
done

for f in "$src"/*.cfg; do
	[ -f "$f" ] || continue
	log "  $(basename "$f")"
done
