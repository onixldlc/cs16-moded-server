#!/bin/sh
# Put the nginx config under the operator's control, then hand over to nginx's own startup.
#
# The problem this solves: the config template is baked into the image at
# /etc/nginx/templates/, and a mount HIDES whatever was underneath it. So "just mount your own
# template directory" leaves that directory empty, nginx renders nothing, and the mirror serves
# 404s -- exactly the trap that makes mounting cstrike/maps eat Valve's stock maps.
#
# So the mount point is a separate directory, and this script decides what happens by whether
# it is empty -- the same rule the server image uses for its own drop-ins:
#
#   not mounted   -> the image's baked template is used. Nothing to set up.
#   mounted empty -> SEEDED with the image's template, so the default appears on your host,
#                    ready to edit. Needs to be writable, once.
#   mounted with files -> yours. Copied over the baked template on every start, so editing a
#                    file on the host and restarting is the whole workflow. Read-only is fine.
#
# Then nginx's own /docker-entrypoint.sh runs, which envsubst's /etc/nginx/templates/*.template
# into /etc/nginx/conf.d/ and starts the server. That step is not reimplemented here.
#
#   FASTDL_CONF_DIR   where to look for your templates. Default /opt/fastdl.
#   FASTDL_ROOT       where the game directory is mounted. Default /srv/hlds.
set -e

FASTDL_CONF_DIR="${FASTDL_CONF_DIR:-/opt/fastdl}"
DIST_DIR="${DIST_DIR:-/opt/fastdl-dist}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/etc/nginx/templates}"

log() {
	echo "[fastdl] $*"
}

mkdir -p "$TEMPLATE_DIR"

# The baked template goes in first, always, as the baseline. Without this the unmounted case
# leaves nginx with no config at all: conf.d is empty, no server block is defined, and the
# container starts but refuses connections.
cp -f "$DIST_DIR"/*.template "$TEMPLATE_DIR"/

if [ -d "$FASTDL_CONF_DIR" ]; then
	# `ls -A` is empty for a directory with nothing in it, including a fresh named volume or a
	# host directory the operator just created.
	if [ -z "$(ls -A "$FASTDL_CONF_DIR" 2>/dev/null)" ]; then
		if cp -a "$DIST_DIR/." "$FASTDL_CONF_DIR/" 2>/dev/null; then
			log "seeded $FASTDL_CONF_DIR with the image's template — edit it and restart"
		else
			log "WARNING: $FASTDL_CONF_DIR is mounted, empty and not writable, so it cannot be"
			log "         seeded. Using the image's built-in config. Mount it writable for one"
			log "         start to get an editable copy."
		fi
	fi

	# Whatever is there now -- just seeded, or the operator's own -- overrides the baseline.
	copied=0

	for f in "$FASTDL_CONF_DIR"/*.template; do
		[ -f "$f" ] || continue
		cp -f "$f" "$TEMPLATE_DIR/"
		copied=$((copied + 1))
	done

	if [ "$copied" -gt 0 ]; then
		log "using $copied template(s) from $FASTDL_CONF_DIR"
	elif [ -n "$(ls -A "$FASTDL_CONF_DIR" 2>/dev/null)" ]; then
		log "WARNING: $FASTDL_CONF_DIR has files but none named *.template — nginx only renders"
		log "         *.template, so the image's built-in config is being used. Found:"
		log "         $(ls -A "$FASTDL_CONF_DIR" | tr '\n' ' ')"
	fi
else
	log "no $FASTDL_CONF_DIR mounted — using the image's built-in config"
fi

log "serving $FASTDL_ROOT (nginx renders the template next)"

# nginx's own entrypoint: runs /docker-entrypoint.d/*, including the envsubst step, then execs
# the command. Keep "$@" so `docker run … nginx -T` and friends still behave.
exec /docker-entrypoint.sh "$@"
