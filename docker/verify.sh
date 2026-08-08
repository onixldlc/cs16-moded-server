#!/bin/sh
# Image self-check: everything the server needs is present and 32-bit, before any
# volume is involved. Run with:  docker run --rm cs16-moded-server:latest verify
set -eu

MODS_DIR="${MODS_DIR:-/opt/mods}"

fail() {
	echo "[verify] FAIL: $*" >&2
	exit 1
}

is_x86_32() {
	# file >= 5.45 renamed "Intel 80386" to "Intel i386"
	file "$1" | grep -Eq 'ELF 32-bit.*Intel (80386|i386)'
}

# --- from the base image ----------------------------------------------------

for f in /opt/dist/engine/engine_i486.so /opt/dist/cstrike/dlls/cs.so; do
	test -f "$f" || fail "missing $f (base image broken)"
	is_x86_32 "$f" || fail "$f is not 32-bit x86"
done

test -x /usr/local/bin/fetch-content.sh   || fail "missing fetch-content.sh"
test -x /usr/local/bin/server-entrypoint.sh || fail "missing server-entrypoint.sh"
test -x /usr/local/bin/install-mods.sh    || fail "missing install-mods.sh"
test -x /usr/local/bin/configure-server.sh || fail "missing configure-server.sh"
test -x /usr/local/bin/fetch-nav.sh       || fail "missing fetch-nav.sh"
test -x /usr/local/bin/install-overlay.sh || fail "missing install-overlay.sh"
test -x /usr/local/bin/rcon.sh            || fail "missing rcon.sh"
test -x /usr/local/bin/rcon               || fail "missing the rcon alias"

# rcon speaks UDP through bash's /dev/udp, so bash specifically has to be there -- the
# base image's /bin/sh is dash and cannot do it.
test -x /usr/bin/bash || test -x /bin/bash || fail "bash is missing — rcon needs /dev/udp"

# zBot is skipped outright on a dedicated server unless this is set, and it has to be set
# before the first map loads -- see docker/Dockerfile. The file is CRLF and the value is
# quoted (bot_enable "1"\r), hence no anchor at the end of the pattern.
grep -qE '^[[:space:]]*bot_enable[[:space:]]+"?1"?' /opt/dist/cstrike/game_init.cfg \
	|| fail "game_init.cfg does not enable bot_enable — zBot would never run"

# And nothing may leave a 0 behind it: cs.so keeps the last value in the file.
if grep -qE '^[[:space:]]*bot_enable[[:space:]]+"?0"?' /opt/dist/cstrike/game_init.cfg; then
	fail "game_init.cfg still has a bot_enable 0 line — zBot would be disabled"
fi

# --- the mods ---------------------------------------------------------------

test -f "$MODS_DIR/.mods-version" || fail "missing $MODS_DIR/.mods-version"

for f in \
		"$MODS_DIR/cstrike/addons/metamod/metamod_i386.so" \
		"$MODS_DIR/cstrike/addons/pugmod/dlls/pugmod_mm.so" \
		"$MODS_DIR/cstrike/addons/hitboxfixer/hitbox_fix_mm_i386.so" \
		"$MODS_DIR/cstrike/addons/yapb/bin/yapb.so" \
		"$MODS_DIR/cstrike/addons/reunion/reunion_mm_i386.so"; do
	test -f "$f" || fail "missing $f"
	is_x86_32 "$f" || fail "$f is not 32-bit x86"
done

for f in \
		"$MODS_DIR/cstrike/liblist.gam" \
		"$MODS_DIR/cstrike/addons/metamod/plugins.ini" \
		"$MODS_DIR/cstrike/addons/metamod/config.ini" \
		"$MODS_DIR/cstrike/server.cfg" \
		"$MODS_DIR/cstrike/rehlds.cfg" \
		"$MODS_DIR/cstrike/addons/yapb/conf/yapb.cfg" \
		"$MODS_DIR/cstrike/addons/yapb/data/graph/de_dust2.graph" \
	"$MODS_DIR/cstrike/reunion.cfg" \
	"$MODS_DIR/cstrike/BotProfile.db" \
	"$MODS_DIR/cstrike/BotChatter.db"; do
	test -f "$f" || fail "missing $f"
done

grep -q 'gamedll_linux "addons/metamod/metamod_i386.so"' "$MODS_DIR/cstrike/liblist.gam" \
	|| fail "liblist.gam does not point at metamod"

# A plugin with an unresolved shared library is skipped SILENTLY by metamod -- the server
# boots, loads cs.so, and the plugin is simply not there. PugMod needs libcurl4:i386.
for so in "$MODS_DIR"/cstrike/addons/*/*.so "$MODS_DIR"/cstrike/addons/*/dlls/*.so; do
	[ -f "$so" ] || continue
	if ldd "$so" | grep -q "not found"; then
		echo "[verify] unresolved dependencies in $so:" >&2
		ldd "$so" | grep "not found" >&2
		fail "$so cannot be loaded in this image"
	fi
	echo "[verify] deps ok: $(basename "$so")"
done

# Every plugin plugins.ini names must exist, or the loader errors at boot.
grep -E '^[[:space:]]*linux[[:space:]]' "$MODS_DIR/cstrike/addons/metamod/plugins.ini" \
	| while read -r _ path _; do
		test -f "$MODS_DIR/cstrike/$path" || fail "plugins.ini names $path, which is not shipped"
		echo "[verify] plugin ok: $path"
	done

echo "[verify] mods: $(cat "$MODS_DIR/.mods-version")"
echo "[verify] metamod_i386.so     $(stat -c %s "$MODS_DIR/cstrike/addons/metamod/metamod_i386.so") bytes"
echo "[verify] pugmod_mm.so        $(stat -c %s "$MODS_DIR/cstrike/addons/pugmod/dlls/pugmod_mm.so") bytes"
echo "[verify] hitbox_fix_mm       $(stat -c %s "$MODS_DIR/cstrike/addons/hitboxfixer/hitbox_fix_mm_i386.so") bytes"
echo "[verify] yapb.so             $(stat -c %s "$MODS_DIR/cstrike/addons/yapb/bin/yapb.so") bytes, $(ls "$MODS_DIR"/cstrike/addons/yapb/data/graph/*.graph | wc -l) waypoint graphs"
echo "[verify] reunion_mm_i386.so  $(stat -c %s "$MODS_DIR/cstrike/addons/reunion/reunion_mm_i386.so") bytes"
echo "[verify] zbot data           BotProfile.db $(stat -c %s "$MODS_DIR/cstrike/BotProfile.db") bytes, $(find "$MODS_DIR/cstrike/sound/radio/bot" -name '*.wav' | wc -l) voice files"
# --- the boot loop that shipped once ----------------------------------------

# configure-server.sh is the last thing entrypoint.sh runs before handing over to the
# engine, and entrypoint.sh runs under `set -e`. A multi-line EXTRA_CVARS -- what a compose
# file's `EXTRA_CVARS: |` block always produces -- ends with a newline, so the loop that
# echoes it back reads an empty final line. While that loop ended in
# `[ -n "$line" ] && log`, the false test became the pipeline's exit status, the script
# exited 1, and the container boot-looped with no error message at all: the log just stopped
# after the last [configure] line. Assert the exit status directly.
vdir=$(mktemp -d)
mkdir -p "$vdir/cstrike"

vfail() {
	rm -rf "$vdir"
	fail "$*"
}

if ! HLDS_DIR="$vdir" RCON_PASSWORD=verify-only EXTRA_CVARS='sv_aim 0
mp_consistency 0
' /usr/local/bin/configure-server.sh >/dev/null 2>&1; then
	vfail "configure-server.sh exits non-zero with a multi-line EXTRA_CVARS — the container would boot-loop"
fi

test -f "$vdir/cstrike/cs16-moded.cfg" || vfail "configure-server.sh wrote no cs16-moded.cfg"
grep -q '^mp_consistency 0' "$vdir/cstrike/cs16-moded.cfg" || vfail "cs16-moded.cfg lost an EXTRA_CVARS line"
grep -q '^exec cs16-moded.cfg' "$vdir/cstrike/server.cfg" || vfail "server.cfg does not exec cs16-moded.cfg"

rm -rf "$vdir"
echo "[verify] configure-server.sh ok with a multi-line EXTRA_CVARS"

echo "[verify] OK"
