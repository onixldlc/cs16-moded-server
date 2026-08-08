#!/bin/sh
# Sync the image's mod tree (/opt/mods) into the running server's directories.
#
# Three different policies, on purpose:
#
#   addons/          version-marked. Copied only when the image's .mods-version differs
#                    from the volume's, so restarts are cheap and anything you installed
#                    by hand into the addons volume is left alone (the copy is additive).
#   liblist.gam      enforced on every start. It is the mod wiring -- it points the engine
#                    at metamod instead of cs.so -- and the content fetch overwrites it
#                    with Valve's version.
#   server.cfg       seeded once, never overwritten. The image always refreshes
#   rehlds.cfg       <name>.default beside it so you can diff in the new upstream values
#   reunion.cfg      when you feel like it. reunion.cfg has one exception: its two
#                    cid_NoSteam4x lines are rewritten from REUNION_NOSTEAM every start,
#                    because upstream ships them set to reject.
set -e

HLDS_DIR="${HLDS_DIR:-/opt/hlds}"
ADDONS_DIR="${ADDONS_DIR:-$HLDS_DIR/cstrike/addons}"
MODS_DIR="${MODS_DIR:-/opt/mods}"

log() {
	echo "[install-mods] $*"
}

if [ ! -d "$MODS_DIR/cstrike" ]; then
	log "no mod tree at $MODS_DIR — nothing to install"
	exit 0
fi

mkdir -p "$HLDS_DIR/cstrike" "$ADDONS_DIR"

# --- mod version markers ----------------------------------------------------

baked=$(cat "$MODS_DIR/.mods-version" 2>/dev/null || echo unknown)
installed=$(cat "$ADDONS_DIR/.mods-version" 2>/dev/null || echo none)

# A fresh addons volume means a fresh deployment: the mod's own server.cfg/rehlds.cfg
# should win. Valve's game content ships a cstrike/server.cfg, so "seed only if missing"
# alone would keep Valve's forever and PugMod's tuning would never apply.
first_install=0
if [ "$installed" = "none" ]; then
	first_install=1
fi

# --- mounted directories: seed when empty, never overwrite -------------------

# Mount your own directory onto part of the addons tree and it becomes yours. Which way that
# goes is decided by one thing, whether the directory is empty:
#
#   empty     -> the mount was just created, so SEED it with the image's copy. This is what
#                makes mounting safe at all: a mount HIDES whatever was underneath it, so an
#                empty mount would hide the real cfgs and the plugin would find nothing.
#   non-empty -> already yours. Excluded from the install below, never overwritten, so an
#                image update cannot revert your edits.
#
# Emptiness is the right signal because a fresh named volume or a fresh host directory is
# empty by definition, and one that has been used is not. Checked on every start, not only on
# a version change: the volume may be new while the marker says the mods are current.
mounted_kept=""

is_mount() {
	awk -v target="$1" '$5 == target { found = 1 } END { exit !found }' /proc/self/mountinfo
}

dir_empty() {
	[ -z "$(ls -A "$1" 2>/dev/null)" ]
}

for sub in $(cd "$MODS_DIR/cstrike/addons" && find . -type d | sed -e 's|^\./||' -e '/^\.$/d'); do
	target="$ADDONS_DIR/$sub"

	is_mount "$target" || continue

	if dir_empty "$target"; then
		if cp -a "$MODS_DIR/cstrike/addons/$sub/." "$target/" 2>/dev/null; then
			log "seeded $sub from the image ($(ls -A "$target" | wc -l) files) — the mount was empty"
		else
			log "WARNING: $sub is mounted, empty and not writable — the plugin will find nothing"
			log "         there. Mount it writable for one start and it will be filled in."
		fi
	else
		log "$sub is yours (mounted, not empty) — left alone"
		mounted_kept="$mounted_kept $sub"
	fi
done

# --- addons: only on a version change ---------------------------------------

if [ "$baked" != "$installed" ]; then
	log "installing mods: $baked (was: $installed)"

	# Directories the operator owns are excluded outright rather than written over.
	tar_excludes=""
	for sub in $mounted_kept; do
		tar_excludes="$tar_excludes --exclude=./$sub"
	done

	# tar, not `cp -a`, for the leftovers: a read-only mount somewhere in the tree makes those
	# paths unwritable, and `cp -a` exits non-zero on the first one. This script runs under
	# `set -e` from an entrypoint, so that is a boot loop with no useful error. tar keeps going
	# and reports what it skipped.
	tar_err=$(mktemp)

	# shellcheck disable=SC2086 # $tar_excludes is a list of arguments, intentionally split
	if ( cd "$MODS_DIR/cstrike/addons" && tar $tar_excludes -cf - . ) | ( cd "$ADDONS_DIR" && tar xf - ) 2>"$tar_err"; then
		log "installed"
	else
		log "installed; some paths were left alone (read-only mount?):"
		sed -e 's/^/[install-mods]   /' "$tar_err" | sort -u | head -5
	fi

	rm -f "$tar_err"
	printf '%s\n' "$baked" > "$ADDONS_DIR/.mods-version"
else
	log "up to date (marker $installed)"
fi

# --- zBot data: BotProfile.db, BotChatter.db, bot voices ---------------------

# The bots live in cs.so; this is the data they read. Copied on a marker change like the
# addons rather than every start, because the voice bank is ~10 MB of wavs.
if [ "$baked" != "$installed" ] || [ ! -f "$HLDS_DIR/cstrike/BotProfile.db" ]; then
	for f in BotProfile.db BotChatter.db; do
		if [ -f "$MODS_DIR/cstrike/$f" ]; then
			cp -f "$MODS_DIR/cstrike/$f" "$HLDS_DIR/cstrike/$f"
		fi
	done

	if [ -d "$MODS_DIR/cstrike/sound/radio/bot" ]; then
		mkdir -p "$HLDS_DIR/cstrike/sound/radio/bot"
		cp -a "$MODS_DIR/cstrike/sound/radio/bot/." "$HLDS_DIR/cstrike/sound/radio/bot/"
	fi

	voices=$(find "$HLDS_DIR/cstrike/sound/radio/bot" -name '*.wav' 2>/dev/null | wc -l)
	log "zbot data installed (BotProfile.db, BotChatter.db, $voices voice files)"
fi

# --- liblist.gam: every start -----------------------------------------------

cp -f "$MODS_DIR/cstrike/liblist.gam" "$HLDS_DIR/cstrike/liblist.gam"
log "liblist.gam -> $(grep -m1 gamedll_linux "$HLDS_DIR/cstrike/liblist.gam" | tr -s ' \t')"

# --- client-side vis files: every start, tiny -------------------------------

if [ -d "$MODS_DIR/cstrike/vis" ]; then
	mkdir -p "$HLDS_DIR/cstrike/vis"
	cp -a "$MODS_DIR/cstrike/vis/." "$HLDS_DIR/cstrike/vis/"
fi

# --- server configs: seed live, always refresh .default ---------------------

for cfg in server.cfg rehlds.cfg reunion.cfg; do
	src="$MODS_DIR/cstrike/$cfg"
	[ -f "$src" ] || continue

	cp -f "$src" "$HLDS_DIR/cstrike/${cfg}.default"

	if [ "$first_install" = "1" ]; then
		cp -f "$src" "$HLDS_DIR/cstrike/$cfg"
		log "$cfg installed from mod (first install)"
	elif [ -f "$HLDS_DIR/cstrike/$cfg" ]; then
		if cmp -s "$src" "$HLDS_DIR/cstrike/$cfg"; then
			log "$cfg unchanged from upstream"
		else
			log "$cfg kept (yours); upstream copy is ${cfg}.default"
		fi
	else
		cp -f "$src" "$HLDS_DIR/cstrike/$cfg"
		log "$cfg seeded"
	fi
done

# --- YaPB: installed, deliberately NOT loaded -------------------------------

# Bots come from zBot, inside ReGameDLL's cs.so. YaPB is still downloaded by the
# Dockerfile and still installed into the addons volume -- only the plugins.ini line is
# withheld, so metamod never loads it.
#
# install_yapb_plugin() below is the code that would load it. Nothing calls it, on
# purpose. To go back to YaPB: call it instead of remove_yapb_plugin at the bottom of this
# block, and drop the zBot cvars in configure-server.sh. Nothing re-downloads -- yapb.so
# and its waypoints are already sitting in the volume.
yapb_line="linux addons/yapb/bin/yapb.so"
plugins_ini="$ADDONS_DIR/metamod/plugins.ini"

# NOT CALLED. Kept so switching back to YaPB is a one-line change, not archaeology.
install_yapb_plugin() {
	if [ ! -f "$ADDONS_DIR/yapb/bin/yapb.so" ]; then
		log "yapb.so is not installed — not touching plugins.ini"
	elif grep -q 'addons/yapb/bin/yapb.so' "$plugins_ini"; then
		log "plugins.ini already loads yapb"
	else
		printf '\n; YaPB bots -- added by cs16-moded-server\n%s\n' "$yapb_line" >> "$plugins_ini"
		log "added yapb to plugins.ini"
	fi
}

# Called. PugMod's zip rewrites plugins.ini, and an older version of this image appended
# the yapb line to the volume's copy, so the line is actively removed rather than merely
# not added.
remove_yapb_plugin() {
	if grep -q 'addons/yapb/bin/yapb.so' "$plugins_ini"; then
		grep -v 'addons/yapb/bin/yapb.so' "$plugins_ini" \
			| grep -v '; YaPB bots -- added by cs16-moded-server' > "$plugins_ini.new"
		mv -f "$plugins_ini.new" "$plugins_ini"
		log "yapb removed from plugins.ini (its files stay installed)"
	else
		log "yapb not loaded (zBot provides the bots)"
	fi
}

if [ -f "$plugins_ini" ]; then
	remove_yapb_plugin
fi

# --- Reunion: on by default, with one guard ---------------------------------

# REUNION=on (the default) loads Reunion, which is what lets clients with no Steam ticket
# connect. REUNION=off disables it.
#
# The guard: a PugMod built -static-libstdc++ that ALSO exports operator new/delete cannot
# be loaded beside Reunion, which links libstdc++.so.6. Two C++ runtimes land in one
# process and a std::locale facet allocated by one is freed by the other, so the server
# aborts at map start with "free(): invalid pointer" -- confirmed under gdb, reproduced with
# every Reunion build back to 0.1.0.129, in both load orders. Reunion alone, or with
# hitbox_fixer, is fine.
#
# The fix is one line in PugMod's Makefile:
#   BUILD_LINKER=-Wl,--exclude-libs,ALL -static-libgcc -static-libstdc++ ...
# The Dockerfile checks the pinned build for those exports and leaves the answer in
# .pugmod-cxx-exports. If the plugin in the volume is byte-identical to the pinned one, that
# answer applies; if you replaced it by hand, it is assumed to be a fixed build. A risky
# combination means Reunion is not loaded and the log says why -- the server stays up.
#
# Reunion hooks client authentication, so its Readme wants the line at the TOP of the file.
# Like the yapb line it is added here rather than baked in, because PugMod's zip replaces
# plugins.ini. Any existing copy is dropped first: that keeps this idempotent and keeps
# Reunion first even after a PugMod bump rewrites the file.
reunion_line="linux addons/reunion/reunion_mm_i386.so"

reunion_on=0
case "${REUNION:-on}" in
	on|1|yes|true) reunion_on=1 ;;
esac

# Would loading Reunion beside this PugMod abort the server? Only the pinned build has a
# verdict; a hand-replaced plugin is taken on trust.
pugmod_risky=0
pugmod_so="$ADDONS_DIR/pugmod/dlls/pugmod_mm.so"
baked_pugmod="$MODS_DIR/cstrike/addons/pugmod/dlls/pugmod_mm.so"

if [ -f "$pugmod_so" ] && [ -f "$baked_pugmod" ] && cmp -s "$pugmod_so" "$baked_pugmod"; then
	pugmod_risky=$(cat "$MODS_DIR/.pugmod-cxx-exports" 2>/dev/null || echo 0)
fi

if [ ! -f "$plugins_ini" ]; then
	:
elif [ "$reunion_on" = "0" ]; then
	if grep -q 'addons/reunion/reunion_mm_i386.so' "$plugins_ini"; then
		grep -v 'addons/reunion/reunion_mm_i386.so' "$plugins_ini" \
			| grep -v '; Reunion -- must load first' > "$plugins_ini.new"
		mv -f "$plugins_ini.new" "$plugins_ini"
		log "REUNION=off — removed reunion from plugins.ini (files stay installed)"
	else
		log "REUNION=off — reunion not loaded (no non-Steam clients); REUNION=on to enable"
	fi
elif [ ! -f "$ADDONS_DIR/reunion/reunion_mm_i386.so" ]; then
	log "REUNION=on but reunion_mm_i386.so is not installed — skipping"
elif [ "$pugmod_risky" = "1" ] && grep -q 'addons/pugmod/dlls/pugmod_mm.so' "$plugins_ini"; then
	# Refusing beats a boot loop. Strip any line a previous image left behind.
	if grep -q 'addons/reunion/reunion_mm_i386.so' "$plugins_ini"; then
		grep -v 'addons/reunion/reunion_mm_i386.so' "$plugins_ini" \
			| grep -v '; Reunion -- must load first' > "$plugins_ini.new"
		mv -f "$plugins_ini.new" "$plugins_ini"
	fi
	log "REUNION=on, but NOT loading it: this pugmod_mm.so exports its static libstdc++"
	log "  symbols, and the server would abort at map start (free(): invalid pointer)."
	log "  Fix PugMod's Makefile with -Wl,--exclude-libs,ALL and bump PUGMOD_TAG, or drop a"
	log "  fixed pugmod_mm.so into the addons volume. Non-Steam clients cannot connect until"
	log "  then; REUNION=off silences this."
else
	first=$(grep -vE '^[[:space:]]*(;|//|#)' "$plugins_ini" | grep -m1 -E '[^[:space:]]' || true)
	if [ "$first" = "$reunion_line" ]; then
		log "plugins.ini already loads reunion first"
	else
		grep -v 'addons/reunion/reunion_mm_i386.so' "$plugins_ini" > "$plugins_ini.new"
		{
			echo "; Reunion -- must load first, added by cs16-moded-server"
			printf '%s\n' "$reunion_line"
			cat "$plugins_ini.new"
		} > "$plugins_ini"
		rm -f "$plugins_ini.new"
		log "put reunion first in plugins.ini"
	fi

	if grep -q 'addons/pugmod/dlls/pugmod_mm.so' "$plugins_ini"; then
		log "reunion + pugmod: this pugmod_mm.so does not export libstdc++, so they coexist"
	fi
fi

# --- Reunion auth policy: managed, like liblist.gam -------------------------

# Upstream reunion.cfg ships cid_NoSteam47 = 5 and cid_NoSteam48 = 5, which REJECT
# clients without a Steam ticket -- the opposite of the reason Reunion is in this image.
# So those two lines are rewritten on every start from REUNION_NOSTEAM; the rest of
# reunion.cfg (emulator handling, query flood limiter, SteamIdHashSalt) stays yours.
reunion_cfg="$HLDS_DIR/cstrike/reunion.cfg"

if [ -f "$reunion_cfg" ] && [ "$reunion_on" = "1" ]; then
	case "${REUNION_NOSTEAM:-allow}" in
		allow|1)  nosteam_cid=3 ;;   # generated STEAM_x:y:z id, derived from the IP
		valve)    nosteam_cid=4 ;;   # same, but the id reads VALVE_x:y:z
		reject|0) nosteam_cid=5 ;;   # upstream: drop the client
		*)
			nosteam_cid=3
			log "REUNION_NOSTEAM='$REUNION_NOSTEAM' not recognised — using allow"
			;;
	esac

	sed -i -E "s|^[[:space:]]*(cid_NoSteam4[78])[[:space:]]*=.*|\\1 = $nosteam_cid|" "$reunion_cfg"
	log "reunion: cid_NoSteam47/48 = $nosteam_cid (REUNION_NOSTEAM=${REUNION_NOSTEAM:-allow})"

	# Reunion REFUSES to initialise with AuthVersion >= 3 and no salt: it prints
	#   [REUNION]: SteamIdHashSalt is not set or too short
	# and `meta list` shows "fail load", so non-Steam clients are rejected while everything
	# looks healthy. Upstream ships the field empty, so one is generated here.
	#
	# Generated once and then left alone: the salt seasons the STEAM ids handed to non-Steam
	# players, so changing it renames every one of them. REUNION_HASH_SALT pins your own.
	salt=$(grep -E '^[[:space:]]*SteamIdHashSalt[[:space:]]*=' "$reunion_cfg" \
		| head -1 | sed -E 's|^[^=]*=[[:space:]]*||')

	if [ "${#salt}" -lt 16 ]; then
		new_salt="${REUNION_HASH_SALT:-}"
		if [ -z "$new_salt" ]; then
			new_salt=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)
		fi

		if [ "${#new_salt}" -lt 16 ]; then
			log "reunion: could not generate a salt — Reunion will not initialise"
		else
			sed -i -E "s|^[[:space:]]*SteamIdHashSalt[[:space:]]*=.*|SteamIdHashSalt = $new_salt|" \
				"$reunion_cfg"
			log "reunion: generated a 32-char SteamIdHashSalt (AuthVersion >= 3 requires one)"
		fi
	fi
fi

# --- what the loader will actually load -------------------------------------

if [ -f "$ADDONS_DIR/metamod/plugins.ini" ]; then
	grep -E '^[[:space:]]*linux[[:space:]]' "$ADDONS_DIR/metamod/plugins.ini" | while read -r _ path _; do
		if [ -f "$HLDS_DIR/cstrike/$path" ]; then
			log "plugin ok: $path"
		else
			log "plugin MISSING: $path — metamod will log a load failure"
		fi
	done
fi

# --- zBot navigation meshes -------------------------------------------------

# A zBot without maps/<map>.nav loads and then stands still, and cs.so says so only once,
# at map start:  ERROR: Failed to load 'maps/de_dust2.nav' file navigation map!
# So the state is reported here, where it is easy to find in the log.
navs=$(find "$HLDS_DIR/cstrike/maps" -maxdepth 1 -name '*.nav' 2>/dev/null | wc -l)
map="${MAP:-de_dust2}"

if [ -f "$HLDS_DIR/cstrike/maps/$map.nav" ]; then
	log "zbot: $map.nav present ($navs nav files installed)"
else
	log "zbot: NO maps/$map.nav — bots will spawn but not move ($navs nav files installed)"
	log "zbot: ZBOT_NAV=czero fetches them once with steamcmd, or drop your own into the volume"
fi
