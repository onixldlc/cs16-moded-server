# ghcr.io/onixldlc/cs16-fastdl -- the download mirror for cs16-moded-server.
#
# A CS 1.6 client that joins without your custom maps downloads them through the game's own UDP
# socket at roughly 10-20 KB/s, one file at a time, while the player stares at a progress bar.
# sv_downloadurl points at plain HTTP instead. For a 17 MB map that is the difference between a
# few seconds and giving up.
#
# Nothing about the server needs this. It only matters for clients that do not already have the
# content.
#
# What makes this worth an image over "just run nginx": the config is already correct for
# GoldSrc, and correct here means restrictive -- it serves the server's live game directory, and
# that directory contains the rcon password in two files. Plus the config itself is a drop-in:
# mount a directory at /opt/fastdl and the first start fills it with the template for you.
#
#   podman build -f docker/fastdl/Dockerfile -t cs16-fastdl:latest .
#
#   podman run -d --name cs16-fastdl -p 8225:80 \
#       -v cs16-content:/srv/hlds:ro \
#       -v ./fastdl:/opt/fastdl \
#       cs16-fastdl:latest
#
# Then, on the server:  sv_downloadurl "http://<your-host>:8225/cstrike"
#
# ./fastdl starts empty, gets the template written into it on the first start, and from then on
# it is yours -- edit and restart. Leave the mount off entirely and the built-in config is used.

FROM docker.io/library/nginx:alpine

# Where the game directory is mounted inside this container. The URL path is unaffected:
# /cstrike/maps/foo.bsp resolves to $FASTDL_ROOT/cstrike/maps/foo.bsp, which is exactly how
# sv_downloadurl "http://host/cstrike" expects to find files.
ENV FASTDL_ROOT=/srv/hlds

# Mount your own template directory here. Empty on the first start means "seed me".
ENV FASTDL_CONF_DIR=/opt/fastdl

# The template is kept in a private directory, NOT in /etc/nginx/templates. That is the whole
# point: mounting a directory over /etc/nginx/templates would hide the baked template and nginx
# would render nothing. The entrypoint copies from here, or from your mount, into the templates
# directory at start.
COPY docker/fastdl/fastdl.conf.template /opt/fastdl-dist/default.conf.template

COPY docker/fastdl/entrypoint.sh /usr/local/bin/fastdl-entrypoint.sh

RUN chmod +x /usr/local/bin/fastdl-entrypoint.sh

# The stock config would otherwise win the default_server slot before our render lands.
RUN rm -f /etc/nginx/conf.d/default.conf

EXPOSE 80

# Wraps nginx's own entrypoint rather than replacing it: the envsubst step that turns
# *.template into a real config lives there and is not worth reimplementing.
ENTRYPOINT ["/usr/local/bin/fastdl-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
