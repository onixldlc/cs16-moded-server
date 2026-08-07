#!/bin/sh
# Open an RCON prompt on the running server, from the repo, with nothing to type.
#
#   ./bin/rcon.sh                     interactive prompt
#   ./bin/rcon.sh status              one command, then exit
#   ./bin/rcon.sh "changelevel de_aztec"
#
# This is the host-side wrapper: it finds the running container and execs the `rcon` client
# that lives inside it, which already knows the password (it reads the generated one out of
# the volume) and the port. So there is no password on your command line and nothing to
# configure here.
#
# Works with a `compose up` deployment -- the normal 24/7 case -- and falls back to a plain
# container. docker and podman are both fine.
#
# Env:
#   ENGINE         docker or podman. Default: whichever is on PATH, docker first.
#   SERVICE        compose service name (default cs16)
#   CONTAINER      container name for the fallback path (default cs16-moded-server)
set -eu

SERVICE="${SERVICE:-cs16}"
CONTAINER="${CONTAINER:-cs16-moded-server}"

die() {
	echo "rcon: $*" >&2
	exit 1
}

# --- engine -----------------------------------------------------------------

if [ -n "${ENGINE:-}" ]; then
	engine="$ENGINE"
elif command -v docker >/dev/null 2>&1; then
	engine=docker
elif command -v podman >/dev/null 2>&1; then
	engine=podman
else
	die "neither docker nor podman found on PATH"
fi

# A prompt needs a TTY; a pipe or a CI job must not get one, or the client blocks waiting
# for a terminal that is not there.
if [ -t 0 ] && [ -t 1 ]; then
	interactive=1
else
	interactive=0
fi

# Run from the repo root even when called from elsewhere, so compose finds
# docker-compose.yml.
cd "$(dirname "$0")/.."

# --- compose first, plain container second ----------------------------------

# `compose ps -q` prints an id only when the service actually has a container.
compose_id=$($engine compose ps -q "$SERVICE" 2>/dev/null || true)

if [ -n "$compose_id" ]; then
	if [ "$interactive" = "1" ]; then
		exec $engine compose exec "$SERVICE" rcon "$@"
	fi
	exec $engine compose exec -T "$SERVICE" rcon "$@"
fi

if $engine inspect "$CONTAINER" >/dev/null 2>&1; then
	if [ "$interactive" = "1" ]; then
		exec $engine exec -it "$CONTAINER" rcon "$@"
	fi
	exec $engine exec -i "$CONTAINER" rcon "$@"
fi

die "no running server found: compose service '$SERVICE' has no container, and none named '$CONTAINER' exists
     start it with '$engine compose up -d', or set SERVICE / CONTAINER to match your deployment"
