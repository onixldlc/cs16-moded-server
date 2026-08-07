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

# --- addons: only on a version change ---------------------------------------

baked=$(cat "$MODS_DIR/.mods-version" 2>/dev/null || echo unknown)
installed=$(cat "$ADDONS_DIR/.mods-version" 2>/dev/null || echo none)

# A fresh addons volume means a fresh deployment: the mod's own server.cfg/rehlds.cfg
# should win. Valve's game content ships a cstrike/server.cfg, so "seed only if missing"
# alone would keep Valve's forever and PugMod's tuning would never apply.
first_install=0
if [ "$installed" = "none" ]; then
	first_install=1
fi

if [ "$baked" != "$installed" ]; then
	log "installing mods: $baked (was: $installed)"
	cp -a "$MODS_DIR/cstrike/addons/." "$ADDONS_DIR/"
	printf '%s\n' "$baked" > "$ADDONS_DIR/.mods-version"
	log "installed"
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

# --- Reunion goes FIRST in plugins.ini --------------------------------------

# Reunion hooks client authentication, so its Readme wants the line at the top of the
# file. Like the yapb line it is added here rather than baked in, because PugMod's zip
# replaces plugins.ini. Any existing copy of the line is dropped first: that keeps this
# idempotent and keeps Reunion first even after a PugMod bump rewrites the file.
reunion_line="linux addons/reunion/reunion_mm_i386.so"

if [ -f "$plugins_ini" ] && [ -f "$ADDONS_DIR/reunion/reunion_mm_i386.so" ]; then
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
fi

# --- Reunion auth policy: managed, like liblist.gam -------------------------

# Upstream reunion.cfg ships cid_NoSteam47 = 5 and cid_NoSteam48 = 5, which REJECT
# clients without a Steam ticket -- the opposite of the reason Reunion is in this image.
# So those two lines are rewritten on every start from REUNION_NOSTEAM; the rest of
# reunion.cfg (emulator handling, query flood limiter, SteamIdHashSalt) stays yours.
reunion_cfg="$HLDS_DIR/cstrike/reunion.cfg"

if [ -f "$reunion_cfg" ]; then
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
