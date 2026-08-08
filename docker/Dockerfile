# cs16-moded-server — a ready-to-run modded Counter-Strike 1.6 server.
#
#   cs16-server (ReHLDS + ReGameDLL_CS)
#     + Metamod-R          plugin loader
#     + PugMod             match/pickup plugin
#     + hitbox fixer       required by PugMod's plugins.ini
#     + zBot assets        the Condition Zero bots -- their code is already inside
#                          ReGameDLL's cs.so, this adds the data they need to run
#     + YaPB               the other bot implementation. Installed but NOT loaded: it
#                          conflicts with Reunion. The code that would load it is kept,
#                          uncalled, in docker/install-mods.sh.
#     + Reunion            lets non-Steam protocol 47/48 clients connect
#
# Nothing is compiled here. Every mod comes from a published release asset, pinned by
# ARG below; bump the tag by hand and rebuild. No Valve content is baked in either:
# the base image still downloads it with steamcmd into a volume on first start.
#
# Build (context is the repo root):
#   podman build -f docker/Dockerfile -t cs16-moded-server:latest .
#
# Override a mod version without editing this file:
#   podman build -f docker/Dockerfile --build-arg PUGMOD_TAG=v1.0.2 -t … .

ARG BASE_IMAGE=ghcr.io/onixldlc/cs16-server:latest


# --- stage: fetch and assemble the mod tree --------------------------------
# Throwaway stage. curl and unzip live here so the final image gains no packages.
FROM docker.io/library/debian:12-slim AS mods

ENV DEBIAN_FRONTEND=noninteractive

ARG METAMOD_TAG=v1.3.0.149-r2
ARG PUGMOD_TAG=v1.0.1-pre2
ARG HITBOXFIXER_TAG=2.0.3
ARG YAPB_TAG=4.4.957
ARG REUNION_TAG=0.2.0.34
ARG ZBOT_ASSETS_REF=5.30.0.814

RUN apt-get update

RUN apt-get install -y --no-install-recommends ca-certificates curl unzip xz-utils file binutils

RUN rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/mods

RUN mkdir -p /opt/mods/cstrike/addons

# Metamod-R: zip root is metamod/, so unpacking into cstrike/addons/ yields
# cstrike/addons/metamod/{metamod_i386.so,config.ini,plugins.ini}
RUN curl -fsSL -o metamod.zip \
        "https://github.com/onixldlc/Metamod-R/releases/download/${METAMOD_TAG}/metamod-standalone.zip"

RUN unzip -q -o metamod.zip -d /opt/mods/cstrike/addons

# PugMod: zip root is already cstrike/ — a complete drop-in tree carrying liblist.gam
# (pre-wired to metamod), server.cfg, rehlds.cfg, vis/ and addons/{pugmod,metamod,hitboxfixer}.
# It MUST unpack after Metamod-R: its addons/metamod/plugins.ini is the one that lists
# the plugins, and it deliberately replaces the loader's stock config.
RUN curl -fsSL -o pugmod.zip \
        "https://github.com/onixldlc/PugMod/releases/download/${PUGMOD_TAG}/pugmod_linux32_${PUGMOD_TAG}.zip"

RUN unzip -q -o pugmod.zip -d /opt/mods

# hitbox fixer: PugMod's plugins.ini loads addons/hitboxfixer/hitbox_fix_mm_i386.so but
# ships only hbf.cfg. Without this the loader logs a failed plugin load on every boot.
# Zip roots are addons/ and vis/, so it unpacks at the cstrike/ level.
RUN curl -fsSL -o hitboxfixer.zip \
        "https://github.com/Garey27/hitbox_fixer/releases/download/${HITBOXFIXER_TAG}/hitbox_fix-bin-${HITBOXFIXER_TAG}.zip"

RUN unzip -q -o hitboxfixer.zip -d /opt/mods/cstrike

# YaPB: the bots. Ships as .tar.xz with addons/ at the root, so it unpacks at the
# cstrike/ level like the hitbox fixer. Carries yapb.so, its conf/ and .graph waypoints
# for the stock maps (de_dust2 included), so bots can navigate out of the box.
RUN curl -fsSL -o yapb.tar.xz \
        "https://github.com/yapb/yapb/releases/download/${YAPB_TAG}/yapb-${YAPB_TAG}-linux.tar.xz"

RUN tar -xJf yapb.tar.xz -C /opt/mods/cstrike

# Reunion: lets clients without a Steam ticket (protocol 47/48) onto a ReHLDS server.
# Its zip is a flat layout rather than a drop-in cstrike/ tree, so the two files that
# matter are placed by hand; the AMX Mod X sample scripts, the Windows dll and the API
# header for plugin authors are dropped.
RUN curl -fsSL -o reunion.zip \
        "https://github.com/rehlds/ReUnion/releases/download/${REUNION_TAG}/reunion-${REUNION_TAG}.zip"

RUN unzip -q -o reunion.zip -d /tmp/mods/reunion

RUN install -D -m 0755 /tmp/mods/reunion/addons/reunion/reunion_mm_i386.so \
        /opt/mods/cstrike/addons/reunion/reunion_mm_i386.so

# reunion.cfg belongs in the gamedir, not in addons/, so install-mods.sh seeds it like
# server.cfg. The plugin reads it once at load -- these settings have no cvars.
RUN install -D -m 0644 /tmp/mods/reunion/reunion.cfg /opt/mods/cstrike/reunion.cfg

# Does this PugMod build export the symbols of its statically linked libstdc++?
#
# If it does, loading Reunion beside it aborts the server at map start: Reunion links
# libstdc++.so.6, so two C++ runtimes end up in one process and a std::locale facet
# allocated by one is freed by the other. The verdict is recorded here, at build time,
# where binutils is available -- install-mods.sh reads it and refuses to load Reunion
# rather than letting the server boot-loop.
#
# The fix belongs in PugMod's Makefile:
#   BUILD_LINKER=-Wl,--exclude-libs,ALL -static-libgcc -static-libstdc++ ...
# With that, this file says 0 and Reunion loads.
#
# Only GLOBAL definitions of the four allocator symbols count. A fixed build still exports
# WEAK _ZdlPvS_ and _ZnwjPv -- placement new/delete, inline stubs that allocate nothing --
# so a looser pattern flags a good build as risky and Reunion never loads. Verified against
# v1.0.1-pre (risky) and v1.0.1-pre2 (ok).
RUN readelf -sW --dyn-syms /opt/mods/cstrike/addons/pugmod/dlls/pugmod_mm.so \
        | awk '$4=="FUNC" && $5=="GLOBAL" && $7!="UND" {print $8}' \
        | grep -qxE '_ZdlPv|_ZdaPv|_Znwj|_Znaj' \
        && echo 1 > /opt/mods/.pugmod-cxx-exports \
        || echo 0 > /opt/mods/.pugmod-cxx-exports

RUN echo "pugmod exports its static libstdc++ symbols: $(cat /opt/mods/.pugmod-cxx-exports)"

# zBot data. The bots themselves are compiled into ReGameDLL's cs.so, but without these
# they cannot run: BotProfile.db is the roster of bot personalities, BotChatter.db plus
# sound/radio/bot/ is their radio chatter. Neither the CS 1.6 depot nor the game dll
# ships them -- ReGameDLL keeps them in its tree, so they come from a pinned ref of that
# repo rather than a release asset. Zip root is cstrike/, so it unpacks at /opt/mods.
RUN curl -fsSL -o bot_profiles.zip \
        "https://raw.githubusercontent.com/rehlds/ReGameDLL_CS/${ZBOT_ASSETS_REF}/regamedll/extra/zBot/bot_profiles.zip"

RUN unzip -q -o bot_profiles.zip -d /opt/mods

# Fail the build on a bad tag rather than shipping a server that cannot load its plugins.
RUN test -f /opt/mods/cstrike/addons/metamod/metamod_i386.so \
        && test -f /opt/mods/cstrike/addons/metamod/plugins.ini \
        && test -f /opt/mods/cstrike/addons/pugmod/dlls/pugmod_mm.so \
        && test -f /opt/mods/cstrike/addons/hitboxfixer/hitbox_fix_mm_i386.so \
        && test -f /opt/mods/cstrike/addons/yapb/bin/yapb.so \
        && test -f /opt/mods/cstrike/addons/yapb/conf/yapb.cfg \
        && test -f /opt/mods/cstrike/addons/yapb/data/graph/de_dust2.graph \
        && test -f /opt/mods/cstrike/addons/reunion/reunion_mm_i386.so \
        && test -f /opt/mods/cstrike/reunion.cfg \
        && test -f /opt/mods/cstrike/BotProfile.db \
        && test -f /opt/mods/cstrike/BotChatter.db \
        && test -f /opt/mods/cstrike/liblist.gam

# file >= 5.45 renamed the machine string "Intel 80386" to "Intel i386"; accept either.
RUN for so in \
            /opt/mods/cstrike/addons/metamod/metamod_i386.so \
            /opt/mods/cstrike/addons/pugmod/dlls/pugmod_mm.so \
            /opt/mods/cstrike/addons/hitboxfixer/hitbox_fix_mm_i386.so \
            /opt/mods/cstrike/addons/yapb/bin/yapb.so \
            /opt/mods/cstrike/addons/reunion/reunion_mm_i386.so; do \
            file "$so" | grep -Eq 'ELF 32-bit.*Intel (80386|i386)' || exit 1; \
        done

# The engine loads metamod instead of cs.so; metamod then loads the real game dll.
RUN grep -q 'gamedll_linux "addons/metamod/metamod_i386.so"' /opt/mods/cstrike/liblist.gam

# Marker the runtime compares against the volume's copy to decide whether to reinstall.
RUN printf 'metamod=%s pugmod=%s hitboxfixer=%s yapb=%s reunion=%s zbot=%s\n' \
        "${METAMOD_TAG}" "${PUGMOD_TAG}" "${HITBOXFIXER_TAG}" "${YAPB_TAG}" "${REUNION_TAG}" \
        "${ZBOT_ASSETS_REF}" > /opt/mods/.mods-version

RUN rm -rf /tmp/mods


# --- final: the server image, mods layered on top --------------------------
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# PugMod links 32-bit libcurl (HTTP for its match APIs). The base image has the amd64
# curl binary, not the i386 library, and without it metamod skips the plugin SILENTLY:
# the server boots fine, loads cs.so, and PugMod is simply absent. i386 is already a
# dpkg foreign architecture in the base image.
RUN apt-get update

RUN apt-get install -y --no-install-recommends libcurl4:i386

RUN rm -rf /var/lib/apt/lists/*

# ~4 MB of mod files. Staged under /opt/mods; install-mods.sh syncs them into the
# volumes at start, so pulling a newer image and restarting is all an update takes.
COPY --from=mods /opt/mods /opt/mods

COPY docker/entrypoint.sh /usr/local/bin/moded-entrypoint.sh

COPY docker/install-mods.sh /usr/local/bin/install-mods.sh

COPY docker/configure-server.sh /usr/local/bin/configure-server.sh

COPY docker/install-overlay.sh /usr/local/bin/install-overlay.sh

COPY docker/fetch-nav.sh /usr/local/bin/fetch-nav.sh

# On PATH under its own name, so it is callable with no path at all, plus a short alias:
#   docker compose exec cs16 rcon.sh        interactive prompt
#   docker compose exec cs16 rcon status    one command
COPY script/rcon.sh /usr/local/bin/rcon.sh

RUN ln -sf /usr/local/bin/rcon.sh /usr/local/bin/rcon

COPY docker/verify.sh /usr/local/bin/verify.sh

RUN chmod +x /usr/local/bin/moded-entrypoint.sh \
        /usr/local/bin/install-mods.sh \
        /usr/local/bin/configure-server.sh \
        /usr/local/bin/fetch-nav.sh \
        /usr/local/bin/install-overlay.sh \
        /usr/local/bin/rcon.sh \
        /usr/local/bin/verify.sh

# zBot refuses to run on a DEDICATED server unless bot_enable is 1, and cs.so reads that
# cvar before server.cfg is ever exec'd -- game_init.cfg is the documented place for it.
# The base image copies /opt/dist/cstrike over the volume on every start, which would undo
# a line written into the volume, so the value is changed in the dist copy itself.
#
# The file already ships the cvar, set to 0 -- ReGameDLL's own default -- with CRLF line
# endings and a quoted value:  bot_enable "0"\r
# So the line is rewritten in place. Appending instead does nothing useful: cs.so keeps the
# LAST value it reads, but a guard that merely looks for the cvar name matches the shipped
# 0 and skips the append entirely, which is how v1.0.0 shipped with bots disabled.
RUN sed -i -E 's|^([[:space:]]*bot_enable)[[:space:]]+.*|\1 "1"|' /opt/dist/cstrike/game_init.cfg

# Belt and braces: if a future base image drops the cvar from the file, add it.
RUN grep -qE '^[[:space:]]*bot_enable[[:space:]]+"?1"?' /opt/dist/cstrike/game_init.cfg \
        || printf '\n// zBot needs this before the first map loads -- cs16-moded-server\nbot_enable "1"\n' \
                >> /opt/dist/cstrike/game_init.cfg

# Plugins live in their own volume so hand-installed ones and edited cfgs survive an
# image update. See docker-compose.yml.
# Build-time gate for the failure above: every plugin must resolve all of its shared
# libraries inside THIS image. A missing dependency fails the build instead of producing
# a server that quietly runs without the plugin.
RUN for so in /opt/mods/cstrike/addons/*/*.so /opt/mods/cstrike/addons/*/dlls/*.so; do \
            [ -f "$so" ] || continue; \
            if ldd "$so" | grep -q "not found"; then \
                echo "unresolved dependencies in $so:"; ldd "$so" | grep "not found"; exit 1; \
            fi; \
        done

# RCON is always on: configure-server.sh generates a 32-char password at first start
# and remembers it in the content volume. Set RCON_PASSWORD to pin your own, or
# RCON_ENABLED=0 to turn it off. EXTRA_CVARS holds your own console commands, one per
# line, and they are applied after server.cfg so they win.
ENV RCON_ENABLED=1

# Reunion (non-Steam clients) is ON: letting friends without Steam connect is the point of
# having it. install-mods.sh still declines to load it -- and says so -- if the PugMod build
# in the volume is one that cannot coexist with it, so a bad pin degrades to "no Reunion"
# instead of a boot loop. REUNION=off disables it outright.
ENV REUNION=on

# Drop-in directory for custom content. Mount a host directory here, laid out like
# cstrike/, and everything in it is copied over the server on every start -- see
# docker/install-overlay.sh. Empty or unmounted, it does nothing.
ENV OVERLAY_DIR=/opt/overlay

ENV ADDONS_DIR=/opt/hlds/cstrike/addons

VOLUME /opt/hlds/cstrike/addons

ENTRYPOINT ["/usr/local/bin/moded-entrypoint.sh"]
