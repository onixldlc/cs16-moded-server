#!/bin/sh
# Copy a host-provided directory tree over cstrike/ on every start.
#
# This is the drop-in path for anything you want on the server: maps, models, sounds, nav
# meshes, cfgs -- including nested ones like addons/pugmod/cfg/. Unzip a pack into the mounted
# directory, restart, done. No sorting files by hand, no copying into volume paths.
#
#   overlay/server.cfg                     -> cstrike/server.cfg
#   overlay/maps/de_mirage_cs2.bsp         -> cstrike/maps/de_mirage_cs2.bsp
#   overlay/maps/de_mirage_cs2.nav         -> cstrike/maps/de_mirage_cs2.nav
#   overlay/addons/pugmod/cfg/pugmod.cfg   -> cstrike/addons/pugmod/cfg/pugmod.cfg
#
# BOTH layouts are handled, and both at once. Packs come rooted either way:
#
#   overlay/maps/...            a flat pack, already relative to cstrike/
#   overlay/cstrike/maps/...    a cstrike/-rooted pack, e.g. `unzip pack.zip -d overlay`
#
# Earlier this script picked overlay/cstrike as the ONE source root whenever it existed, which
# meant unzipping a cstrike/-rooted pack next to a flat one silently ignored everything in the
# flat part. Now the flat part is copied first and the cstrike/ part second, so mixing them
# works and the more specific layout wins on a conflict.
#
# addons/ needs no special handling even though it is a separate volume: the copy runs INSIDE
# the container, where /opt/hlds/cstrike/addons is already that volume's mount point, so the
# files land where the server actually reads them. Copying into the content volume's addons/
# directory from the host would write underneath the mount, where nothing sees it.
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
CSTRIKE_DIR="$HLDS_DIR/cstrike"

log() {
	echo "[overlay] $*"
}

if [ ! -d "$OVERLAY_DIR" ]; then
	exit 0
fi

count_files() {
	find "$1" -type f ! -name '.gitkeep' ! -name '.DS_Store' 2>/dev/null | wc -l
}

total=$(count_files "$OVERLAY_DIR")

if [ "$total" -eq 0 ]; then
	log "$OVERLAY_DIR is empty — nothing to copy"
	exit 0
fi

# liblist.gam is the mod wiring and install-mods.sh rewrites it on every start, so a copy here
# would be silently reverted. Better to say so than to let it look applied.
for root in "$OVERLAY_DIR" "$OVERLAY_DIR/cstrike"; do
	if [ -f "$root/liblist.gam" ]; then
		log "warning: liblist.gam in the overlay is ignored — the image manages it"
	fi
done

mkdir -p "$CSTRIKE_DIR"

# tar, not `cp -a`: a read-only bind mount somewhere under cstrike/ makes those paths
# unwritable, and cp exits non-zero on the first one, which under `set -e` is a boot loop with
# no useful error. tar keeps going and reports what it could not write.
copy_root() {
	src="$1"
	label="$2"
	files="$3"
	shift 3

	if [ "$files" -eq 0 ]; then
		return 0
	fi

	err=$(mktemp)

	# shellcheck disable=SC2086 # "$@" here is tar's exclude list, intentionally split
	if ( cd "$src" && tar "$@" -cf - . ) | ( cd "$CSTRIKE_DIR" && tar xf - ) 2>"$err"; then
		log "copied $files files from $label"
	else
		log "copied from $label; some paths were left alone (read-only mount?):"
		sed -e 's/^/[overlay]   /' "$err" | sort -u | head -5
	fi

	rm -f "$err"
}

# The flat part, minus a cstrike/ directory -- that is the other layout, applied next. Counted
# with the same exclusion, so the number logged is the number of files actually copied.
flat_files=$(find "$OVERLAY_DIR" -type f ! -name '.gitkeep' ! -name '.DS_Store' \
	! -path "$OVERLAY_DIR/cstrike/*" 2>/dev/null | wc -l)

copy_root "$OVERLAY_DIR" "$OVERLAY_DIR" "$flat_files" --exclude=./cstrike

if [ -d "$OVERLAY_DIR/cstrike" ]; then
	copy_root "$OVERLAY_DIR/cstrike" "$OVERLAY_DIR/cstrike" "$(count_files "$OVERLAY_DIR/cstrike")"
fi

# What landed, by the directories people actually care about.
for d in maps addons sound models sprites gfx overviews; do
	from_flat=0
	from_nested=0

	[ -d "$OVERLAY_DIR/$d" ] && from_flat=$(find "$OVERLAY_DIR/$d" -type f | wc -l)
	[ -d "$OVERLAY_DIR/cstrike/$d" ] && from_nested=$(find "$OVERLAY_DIR/cstrike/$d" -type f | wc -l)

	sum=$((from_flat + from_nested))

	if [ "$sum" -gt 0 ]; then
		log "  $d: $sum files"
	fi
done

navs=$(find "$CSTRIKE_DIR/maps" -name '*.nav' 2>/dev/null | wc -l)
log "  maps/*.nav now installed: $navs"

for root in "$OVERLAY_DIR" "$OVERLAY_DIR/cstrike"; do
	for f in "$root"/*.cfg; do
		[ -f "$f" ] || continue
		log "  $(basename "$f")"
	done
done
