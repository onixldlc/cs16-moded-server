#!/bin/bash
# RCON for this container's own server -- interactive prompt by default.
#
#   docker compose exec cs16 rcon                 -> prompt, already connected
#   docker compose exec cs16 rcon status          -> one command, then exit
#   docker exec -it cs16-moded-server rcon.sh     -> same thing; `rcon` is an alias
#
# Nothing to type: the password comes out of cstrike/.rcon_password in the volume, which is
# where configure-server.sh put the one it generated, and the target is 127.0.0.1:27015
# inside this container. Beats `docker attach`, which shares the server's real console and
# cannot be left without care.
#
# No extra package either. GoldSrc RCON is a challenge/response over UDP and bash speaks
# UDP through /dev/udp:
#
#   1. -> \xff\xff\xff\xff challenge rcon
#      <- \xff\xff\xff\xff challenge rcon <number>
#   2. -> \xff\xff\xff\xff rcon <number> "<password>" <command>
#      <- \xff\xff\xff\xff l <text>        (one or more packets)
#
# The password goes into the packet inside this shell, never into a process argument, so
# `ps` in the container cannot read it.
#
# Env:
#   RCON_PASSWORD   the password. Unset -> read from cstrike/.rcon_password.
#   RCON_HOST       default 127.0.0.1 -- the server in this container.
#   RCON_PORT       default 27015, the port INSIDE the container, not the published one.
#   RCON_TIMEOUT    seconds to wait for the first reply packet (default 3).
#   RCON_QUIET      seconds to wait for further packets before calling the reply complete
#                   (default 0.4). A long `status` arrives as several packets.
#   HLDS_DIR        default /opt/hlds.
#
# RCON rides the game's UDP port and the password travels in cleartext, so this belongs
# inside the container rather than across a network.
set -u

HLDS_DIR="${HLDS_DIR:-/opt/hlds}"
host="${RCON_HOST:-127.0.0.1}"
port="${RCON_PORT:-27015}"
timeout="${RCON_TIMEOUT:-3}"
quiet="${RCON_QUIET:-0.4}"
pw_file="$HLDS_DIR/cstrike/.rcon_password"

challenge=""

die() {
	echo "[rcon] $*" >&2
	exit 1
}

# --- password ---------------------------------------------------------------

if [ -n "${RCON_PASSWORD:-}" ]; then
	password="$RCON_PASSWORD"
elif [ -s "$pw_file" ]; then
	password="$(cat "$pw_file")"
else
	die "no password: set RCON_PASSWORD, or start the server once so $pw_file exists"
fi

if [ -z "$password" ]; then
	die "password is empty — is RCON_ENABLED=0?"
fi

# --- wire -------------------------------------------------------------------

exec 3<>"/dev/udp/$host/$port" || die "cannot open UDP socket to $host:$port"

# Read whatever is waiting, up to one packet's worth.
#
# `read -N 4096` waits for 4096 bytes OR the timeout, and a reply is nowhere near that big,
# so it always burns the whole timeout -- a 3s setting made `status` take 6s. Blocking on a
# single byte first is not an option either: the first byte of every reply is 0xFF and
# `read -N 1` does not come back with it. So the wait is split into short slices and the
# first non-empty one wins, which puts a loopback round trip at ~0.5s.
#
# read -N returns non-zero on timeout but keeps whatever it got, which is what is wanted.
recv() {
	local wait="$1"
	local buf="" tries

	tries=$(awk -v w="$wait" 'BEGIN { n = int(w / 0.5); if (n < 1) n = 1; print n }')

	while [ "$tries" -gt 0 ]; do
		buf=""
		read -r -t 0.5 -N 4096 -u 3 buf || true

		if [ -n "$buf" ]; then
			printf '%s' "$buf"
			return 0
		fi

		tries=$((tries - 1))
	done
}

# Strip the 4-byte 0xFF header and the 'l' (print) marker wherever they appear -- with
# several packets in one read they turn up mid-buffer, not just at the front.
clean() {
	local s="$1"
	s="${s//$'\xff\xff\xff\xff'l/}"
	s="${s//$'\xff\xff\xff\xff'/}"
	printf '%s' "$s"
}

get_challenge() {
	printf '\xff\xff\xff\xffchallenge rcon\n' >&3

	local reply
	reply="$(recv "$timeout")"
	challenge=""

	if [[ "$reply" =~ challenge\ rcon\ ([0-9]+) ]]; then
		challenge="${BASH_REMATCH[1]}"
	fi

	[ -n "$challenge" ]
}

# Collect one reply: first packet, then keep draining while more keep coming, so a
# multi-packet `status` is not cut in half.
collect() {
	local body more
	body="$(clean "$(recv "$timeout")")"

	while true; do
		more="$(clean "$(recv "$quiet")")"
		[ -n "$more" ] || break
		body="$body$more"
	done

	printf '%s' "$body"
}

# Prints the reply. Returns 2 on a bad password, 1 when the server said nothing at all.
send_command() {
	local cmd="$1"
	local body

	if [ -z "$challenge" ]; then
		get_challenge || die "no challenge from $host:$port after ${timeout}s — is the server up? (docker logs)"
	fi

	printf '\xff\xff\xff\xffrcon %s "%s" %s\n' "$challenge" "$password" "$cmd" >&3
	body="$(collect)"

	# A challenge is tied to the requesting address and expires. One silent retry with a
	# fresh one keeps a long-lived prompt working instead of dying mid-session.
	case "$body" in
		*"Bad challenge"*)
			challenge=""
			get_challenge || die "server stopped answering challenges"
			printf '\xff\xff\xff\xffrcon %s "%s" %s\n' "$challenge" "$password" "$cmd" >&3
			body="$(collect)"
			;;
	esac

	while [ -n "$body" ] && [ "${body: -1}" = $'\n' ]; do
		body="${body%$'\n'}"
	done

	if [ -n "$body" ]; then
		printf '%s\n' "$body"
	fi

	case "$body" in
		*"Bad rcon_password"*) return 2 ;;
	esac

	[ -n "$body" ] || return 1
	return 0
}

# --- one command, or a prompt -----------------------------------------------

if [ "$#" -gt 0 ]; then
	rc=0
	send_command "$*" || rc=$?

	# Silence is normal for plenty of commands (changelevel, say), so it is not an error
	# here -- only a wrong password is.
	if [ "$rc" = "1" ]; then
		echo "[rcon] no reply — the command may still have run (many commands print nothing)" >&2
		rc=0
	fi

	exit "$rc"
fi

get_challenge || die "no challenge from $host:$port after ${timeout}s — is the server up? (docker logs)"

echo "rcon $host:$port — connected. 'exit' or Ctrl-D to leave, 'help' for server help."

while true; do
	line=""

	# -e gives readline (history, arrow keys) when there is a terminal. Piped input has no
	# terminal, and -e on a pipe misbehaves, so it is only used interactively.
	if [ -t 0 ]; then
		read -r -e -p "rcon> " line || break
	else
		read -r line || break
	fi

	case "$line" in
		"") continue ;;
		exit|quit|q) break ;;
	esac

	send_command "$line" || true
done

exec 3<&-
exec 3>&-
