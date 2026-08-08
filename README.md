# cs16-moded-server

A ready-to-run **modded Counter-Strike 1.6 server** in one image:

| piece | source | why |
|---|---|---|
| ReHLDS engine + ReGameDLL_CS game dll | [`ghcr.io/onixldlc/cs16-server`](https://github.com/onixldlc/ReGameDLL_CS) | the server itself |
| [Metamod-R](https://github.com/onixldlc/Metamod-R) | `metamod-standalone.zip` | plugin loader |
| [PugMod](https://github.com/onixldlc/PugMod) | `pugmod_linux32_*.zip` | match / pickup game plugin |
| [hitbox_fixer](https://github.com/Garey27/hitbox_fixer) | `hitbox_fix-bin-*.zip` | required by PugMod's `plugins.ini` |
| zBot data ([ReGameDLL_CS](https://github.com/rehlds/ReGameDLL_CS)) | `extra/zBot/bot_profiles.zip` | bots — the code is already inside `cs.so`, this is the data it needs |
| [YaPB](https://github.com/yapb/yapb) | `yapb-*-linux.tar.xz` | the other bot implementation — installed, **not loaded** |
| [Reunion](https://github.com/rehlds/ReUnion) | `reunion-*.zip` | lets clients with no Steam ticket connect |

Nothing is compiled here and no game content is baked in. Mods come from published
release assets pinned in `docker/server/Dockerfile`; the game content is downloaded from Steam
into a volume on first start.

## Run it

```bash
git clone https://github.com/onixldlc/cs16-moded-server.git
cd cs16-moded-server
docker compose up -d
docker compose logs -f
```

The **first** start pulls ~544 MB of game content from Steam — minutes, not seconds. The
server is unreachable until the log says `content ready`. Every later start is immediate.

Default: port **8222/udp**, `de_dust2`, 12 slots, `-insecure` (no VAC, so no Steam account
or GSLT needed). Change those in `docker-compose.yml`.

Server console:

```bash
docker attach cs16-moded-server     # detach with Ctrl-P Ctrl-Q
```

## RCON (always on)

RCON is enabled on every start. Leave `RCON_PASSWORD` unset and a **32-char random
password** is generated on first start, printed in the log and remembered in the content
volume, so it stays the same across restarts:

```bash
docker compose logs | grep "RCON is ON"
# [configure] RCON is ON  ->  rcon_password aBcD1234...wXyZ   (32 chars, unique to your server)
```

Pin your own with `RCON_PASSWORD`, or set `RCON_ENABLED: "0"` to turn RCON off. From the
game console:

```
rcon_address <host>:8222
rcon_password <password>
rcon status
```

RCON rides the same **UDP** port as the game and the password travels in cleartext. Also
note PugMod'"'"'s `server.cfg` sets `sv_rcon_maxfailures 5` / `sv_rcon_banpenalty 60`: a
handful of wrong passwords bans your IP for an hour.

## Bots

Bots are **zBot** — the Condition Zero bots compiled into ReGameDLL's `cs.so`. No metamod
plugin is involved.

`BOTS: "0"` turns bots off. `BOT_QUOTA` sets the count explicitly, otherwise it is
`MAXPLAYERS - HUMAN_SLOTS`. `BOT_DIFFICULTY` is on YaPB's `0..4` scale and is clamped to
`0..3` for zBot. `BOT_CHATTER` is `normal` / `minimal` / `radio` / `off`.

YaPB is still downloaded, still installed into the addons volume, and still verified at
build time — it is simply never put into `plugins.ini`, because loading it alongside
Reunion aborts the server at boot (`free(): invalid pointer`). The code that would load it
is kept and never called: `install_yapb_plugin()` in `docker/server/install-mods.sh` and
`yapb_cvars()` in `docker/server/configure-server.sh`. Switching back means calling those two
instead of the zBot path — no re-download, the files are already in the volume.

Two things about zBot are worth knowing, because both are silent failures otherwise:

- **`bot_enable 1` must be set before the first map loads.** `cs.so` reads it while the
  game dll initialises, long before `server.cfg` runs, so it goes in `game_init.cfg` — and
  because the base image copies `/opt/dist/cstrike` over the volume on every start, this
  image writes the line into that dist copy at build time. `verify` fails if it is missing.
- **A zBot with no navigation mesh spawns and then stands still.** CS 1.6 has never shipped
  `maps/*.nav`; the meshes live in Condition Zero. `ZBOT_NAV=czero` (the default) fetches
  them once with steamcmd — same app 90 and same legacy branch the game content comes from
  — keeps only the `.nav` files and throws the rest away. That download is a few hundred MB
  and happens on first start only. `ZBOT_NAV=none` skips it, for when you mount your own.
  The log says which way it went:

```
[fetch-nav] installed 46 nav files into /opt/hlds/cstrike/maps
[install-mods] zbot: de_dust2.nav present (46 nav files installed)
```

  CZ's meshes are built for CZ's copies of the classic maps. Layouts match closely enough
  to play, but a mesh is not authoritative for a map it was not made from.

Nothing Valve owns is baked into the image, bots included — the meshes are fetched per
deployment under the deployer's own Steam Subscriber Agreement, exactly like the game
content.

## Non-Steam clients (Reunion)

**On by default** (`REUNION: "off"` to disable) — letting people without Steam connect is
the whole point of having it.

One caveat, handled automatically. A PugMod built `-static-libstdc++` that *also* exports
`operator new`/`operator delete` cannot be loaded beside Reunion, which links
`libstdc++.so.6`: two C++ runtimes in one process, and a `std::locale` facet allocated by one
gets freed by the other, so the server aborts at map start with `free(): invalid pointer`
(confirmed under gdb; reproduced with every Reunion build back to 0.1.0.129, in both load
orders — Reunion alone, or with hitbox_fixer, is fine). The one-line fix in PugMod's
`Makefile`:

```make
BUILD_LINKER=-Wl,--exclude-libs,ALL -static-libgcc -static-libstdc++ -lcurl -lssl -lcrypto -ldl -lm -lz
```

PugMod **`v1.0.1-pre2` and later carry the flag**, and that is what is pinned here — so
Reunion just works. The check below stays as a guard against a future pin regressing.

The build checks the pinned PugMod for those exports and records the answer in
`/opt/mods/.pugmod-cxx-exports`. If the verdict is "risky", the server starts **without**
Reunion and says so in the log, rather than boot-looping:

```
[install-mods] REUNION=on, but NOT loading it: this pugmod_mm.so exports its static libstdc++
```

Replace `pugmod_mm.so` in the addons volume with a fixed build, or bump `PUGMOD_TAG` to a
release that carries the flag, and Reunion loads by itself.

Reunion also **refuses to initialise without a hash salt** — upstream ships
`SteamIdHashSalt` empty, and with `AuthVersion >= 3` that means `meta list` reports
`fail load` while everything else looks healthy. A 32-char salt is generated on first start
and then left alone, since it seasons the ids handed to non-Steam players; `REUNION_HASH_SALT`
pins your own.

[Reunion](https://github.com/rehlds/ReUnion) is loaded **first** by metamod,
so clients on protocol 47/48 with no Steam ticket can connect. Upstream's `reunion.cfg` ships
`cid_NoSteam47 = 5` / `cid_NoSteam48 = 5`, which *reject* exactly those clients — so those
two lines are managed here and rewritten on every start from `REUNION_NOSTEAM`:

| `REUNION_NOSTEAM` | `cid_NoSteam47/48` | effect |
|---|---|---|
| `allow` (default) | `3` | client gets a generated `STEAM_x:y:z` id, derived from its IP |
| `valve` | `4` | same, but the id reads `VALVE_x:y:z` |
| `reject` | `5` | upstream behaviour: the client is dropped |

Steam clients are untouched (`cid_Steam = 1`, id passed through as-is), and so is the rest
of `cstrike/reunion.cfg` — emulator handling, the query flood limiter, `SteamIdHashSalt`.
Edit it freely; `reunion.cfg.default` always holds the upstream copy.

An id generated from an IP is not an identity: it changes when the player's IP changes,
and everyone behind one NAT shares one. Admin lists keyed on those ids are worth that
much. `sv_lan 0` + `-insecure` is already the default here, so this adds no VAC exposure.

## Driving the server: `bin/rcon`

From the repo, against a `compose up -d` server, with nothing to type:

```bash
./bin/rcon
rcon 127.0.0.1:27015 — connected. 'exit' or Ctrl-D to leave, 'help' for server help.
rcon> status
rcon> changelevel de_aztec
rcon> exit
```

One command and out, for scripts:

```bash
./bin/rcon status
./bin/rcon "bot_quota 4"
```

`bin/rcon` is only a finder: it locates the running container — compose service first
(`SERVICE`, default `cs16`), plain container second (`CONTAINER`, default
`cs16-moded-server`) — and runs the real client inside it. docker and podman both work,
picked automatically or forced with `ENGINE`. Straight at the container works too, either
spelling:

```bash
docker compose exec cs16 rcon.sh
docker exec -it cs16-moded-server rcon
```

Why bother, when `docker attach` exists: attach hands you the server's *own* stdin console,
shared with the process, and leaving it without `Ctrl-P Ctrl-Q` takes the server down with
you. An RCON prompt is a separate session you can open and close at will, which is what you
want on a server that is meant to stay up.

The client reads `cstrike/.rcon_password` from the volume — the password
`configure-server.sh` generated on first start — and talks to `127.0.0.1:27015` inside the
container, so nothing needs to be reachable from outside and no password touches your shell
history. `RCON_HOST`, `RCON_PORT`, `RCON_PASSWORD`, `RCON_TIMEOUT`, `RCON_QUIET` override
if you point it elsewhere.

No new package in the image: GoldSrc RCON is a challenge/response over UDP and `bash` does
UDP through `/dev/udp`, so the whole client is `script/rcon.sh`, installed on `PATH`. The password is assembled
into the packet inside the shell, never as an argument, so `ps` in the container cannot see
it. A stale challenge is refreshed silently, so a prompt left open all afternoon keeps
working. Exit status is `2` on a bad password.

Note PugMod's `server.cfg` sets `sv_rcon_maxfailures 5` / `sv_rcon_banpenalty 60`: five
wrong passwords and your IP sits out an hour.

## Your own cvars

`EXTRA_CVARS` takes console commands, one per line:

```yaml
    environment:
      EXTRA_CVARS: |
        mp_consistency 0
        sv_alltalk 1
```

Or point `EXTRA_CVARS_FILE` at a mounted file.

## Engine launch options

`EXTRA_CVARS` is console commands. Some settings are not console commands at all -- the
engine only reads them from its command line at startup, and no cfg file can set them.
Those go in `EXTRA_ARGS`:

```yaml
    environment:
      EXTRA_ARGS: "-nomaster -noipx -nojoy -pingboost 3 -heapsize 65536 +maxplayers 32"
```

This is the same string you would put after `hlds.exe` or `./hlds_run`. It is appended to the
managed command line (`-game cstrike -port ... -insecure +sv_lan ... +maxplayers ... +map
...`), and any option you set there is **left out** of the managed part rather than written
twice. So `+maxplayers 32` replaces `MAXPLAYERS` and `+map de_mirage_cs2` replaces `MAP`; the
log says which ones were skipped.

Duplicates are avoided because the engine does not resolve them the way you would expect.
With both `+map de_dust2` and `+map de_mirage_cs2` on one command line it booted
`de_mirage_cs2` and then immediately loaded `de_dust2` — the *first* value effectively won.
Each option is emitted exactly once for that reason.

`-heapsize` is in kilobytes (`65536` = 64 MB) and `-pingboost 3` changes the engine's timing
loop -- both are worth understanding before copying them from a forum post.

An option whose value contains spaces cannot go here, because the string is word-split into
arguments. `hostname "Two Words"` belongs in `EXTRA_CVARS`.

These land in `cstrike/cs16-moded.cfg`, which is regenerated on every start, and
`server.cfg` gets **one** managed line appended:

```
// added by cs16-moded-server -- runs after everything above, do not remove
exec cs16-moded.cfg
```

That is deliberate. The engine execs `server.cfg` at map start, *after* the command line,
so `+rcon_password` on the command line loses to `rcon_password ""` on line 2 of PugMod'"'"'s
server.cfg. An `exec` at the end of `server.cfg` runs last, so your values win. Everything
else in `server.cfg` stays yours.

## Your own maps, models, sounds and cfgs

One directory, laid out exactly like `cstrike/`. Unzip a pack into it, restart, done — any
depth, any subdirectory, cfgs included. Nothing needs sorting by hand.

```yaml
    volumes:
      - ./content:/opt/overlay:ro
```

```bash
mkdir -p content && unzip yourpack.zip -d ./content
docker compose restart cs16
```

```
content/server.cfg                     -> cstrike/server.cfg
content/maps/de_mirage_cs2.bsp         -> cstrike/maps/de_mirage_cs2.bsp
content/maps/de_mirage_cs2.nav         -> cstrike/maps/de_mirage_cs2.nav
content/addons/pugmod/cfg/pugmod.cfg   -> cstrike/addons/pugmod/cfg/pugmod.cfg
```

**Both pack layouts work, and both at once.** Packs come rooted either way, and mixing them is
the normal case once you have two of them:

```
content/maps/...            flat, already relative to cstrike/
content/cstrike/maps/...    cstrike/-rooted, e.g. unzip pack.zip -d ./content
```

The flat part is applied first and the `cstrike/` part second, so the more specific layout wins
a conflict. (An earlier version picked `content/cstrike` as the *only* root when it existed,
which silently ignored everything in a flat pack sitting next to it.)

The log says what landed:

```
[overlay] copied 346 files from /opt/overlay
[overlay]   maps: 59 files
[overlay]   addons: 16 files
[overlay]   maps/*.nav now installed: 65
```

`addons/` needs no special handling even though it is a separate volume: the copy runs *inside*
the container, where `cstrike/addons` is already that volume's mount point. Copying into the
content volume's `addons/` from the *host* is the one thing that does **not** work — it writes
underneath the mount, where nothing reads it.

### Why copied and not mounted

Because **a mount hides whatever was underneath it** — a plain bind mount and podman's `:O`
both do, tested. Mounting `content/maps` onto `cstrike/maps` would make Valve's stock 25 maps
disappear instead of adding yours to them, and the same goes for `models`, `sound`, `sprites`
and `gfx`.

Three limits: the copy never deletes (removing a file from `content/` leaves the copy in the
volume), `liblist.gam` is ignored because the image rewrites it every start, and `game_init.cfg`
is ignored in practice because `/opt/dist` is copied over `cstrike/` *afterwards*. It runs after
the image's own mods, so your files win over those; and before the cvar generation, so an
overlaid `server.cfg` still gets its managed `exec cs16-moded.cfg` line.

`content/` is gitignored — it is per-deployment, and usually large.

### Optional: one directory live instead of copied

If there is a directory you tune constantly and a restart is annoying, mount that one directly
and edits become instant, because the file on disk *is* the file the server reads:

```yaml
      - ./live-cfg:/opt/hlds/cstrike/addons/pugmod/cfg
```

Empty when the server starts and it is seeded with the image's own copy; non-empty and it is
yours — the mod install excludes it and an image update never overwrites it, which it says in
the log:

```
[install-mods] seeded pugmod/cfg from the image (16 files) — the mount was empty
[install-mods] pugmod/cfg is yours (mounted, not empty) — left alone
```

Keep it writable, or an empty one cannot be seeded (the image warns). Most deployments do not
need this — `content/` handles cfgs perfectly well, one restart later.

## Update

```bash
docker compose pull && docker compose up -d
```

Engine, game dll and mods are reinstalled from the image. Game content is untouched.

## How the two volumes divide up

| volume | holds | update behaviour |
|---|---|---|
| `hlds-content` → `/opt/hlds` | game content, engine, `cs.so` | content fetched once; engine + dll overwritten from the image every start |
| `hlds-addons` → `/opt/hlds/cstrike/addons` | plugins and their cfgs | reinstalled only when the image's mod version marker changes, so plugins you add by hand stay |

`cstrike/liblist.gam` is rewritten on every start — it is the mod wiring
(`gamedll_linux "addons/metamod/metamod_i386.so"`), and the Steam content ships Valve's
version.

`server.cfg`, `rehlds.cfg` and `reunion.cfg` are **seeded once** and never overwritten.
The upstream versions are always refreshed alongside as `<name>.default`, so you can diff
in new values when you want them. Reunion's two `cid_NoSteam4x` lines are the one
exception — see above.

## Bumping a mod version

Edit the ARGs in `docker/server/Dockerfile`:

```dockerfile
ARG METAMOD_TAG=v1.3.0.149-r2
ARG PUGMOD_TAG=v1.0.1-pre2
ARG HITBOXFIXER_TAG=2.0.3
ARG YAPB_TAG=4.4.957
ARG REUNION_TAG=0.2.0.34
ARG ZBOT_ASSETS_REF=5.30.0.814
```

Push a `v*` tag and the workflow builds, verifies and publishes. The build fails if a tag
does not exist, if a plugin binary is missing or not 32-bit x86, or if `plugins.ini` names
a plugin that is not shipped.

One-off build without editing the file: run the workflow via *Run workflow* and fill in
the tag inputs, or locally:

```bash
docker build -f docker/server/Dockerfile --build-arg PUGMOD_TAG=v1.0.2 -t cs16-moded-server:test .
```

## Check an image

```bash
docker run --rm ghcr.io/onixldlc/cs16-moded-server:latest verify
```

Asserts the engine, game dll and every mod binary are present and 32-bit, that
`liblist.gam` points at metamod, and that every plugin `plugins.ini` names exists. Prints
the pinned mod versions.

## Layout

Two images, one repo. The server, and the optional download mirror.

```
docker/server/Dockerfile          two stages: fetch the mod releases, layer them on cs16-server
docker/server/entrypoint.sh       content -> mods -> overlay -> cvars -> base entrypoint
docker/server/install-mods.sh     marker-based sync into the volumes
docker/server/install-overlay.sh  copies your drop-in directory over cstrike/ each start
docker/server/configure-server.sh rcon password, EXTRA_CVARS, bot cvars
docker/server/fetch-nav.sh        one-off steamcmd fetch of the zBot navigation meshes
docker/server/verify.sh           image self-check
docker/fastdl/Dockerfile          nginx, preconfigured for sv_downloadurl
docker/fastdl/fastdl.conf.template its config: an allowlist, not a denylist
script/rcon.sh                    the client that ships into the image as /usr/local/bin/rcon.sh
bin/rcon                          run this: finds the container, opens the prompt
docker-compose.yml                what you actually run
content/                          your drop-in directory: per-deployment, gitignored
```

```bash
podman build -f docker/server/Dockerfile -t cs16-moded-server:latest .
podman build -f docker/fastdl/Dockerfile -t cs16-fastdl:latest .
```

Both are built from the repo root, so `-f` points into the subdirectory while the context
stays `.`.

CI is split to match, one workflow per image: `.github/workflows/image-server.yml` and
`image-fastdl.yml`. Same rules in both — a pushed tag `v*` publishes, `workflow_dispatch`
builds without publishing, and each verifies the image it just built before the release is
allowed to stand.

## fastdl: HTTP downloads for clients

Optional, and genuinely optional: the server plays identically without it. It only matters for
clients that do not already have your custom content. Without it, a client missing a 17 MB map
pulls it through the game's UDP socket at 10-20 KB/s while the join blocks.

```bash
podman run -d --name cs16-fastdl -p 8225:80 \
    -v cs16-content:/srv/hlds:ro ghcr.io/onixldlc/cs16-fastdl:latest
```

Then on the server, with an address **your clients** can reach — the game client resolves it
itself, so a container name or `localhost` fails for everyone:

```
sv_allowdownload 1
sv_downloadurl "http://your-host:8225/cstrike"
```

The compose file carries the same thing as a commented service with the full instructions.

It serves **the server's own content volume, read-only** — not a copy. So what a client
downloads is byte-for-byte what the server runs: no sync step, and the mirror cannot hand out a
map the server has already replaced.

### Changing its config

Mount a directory at `/opt/fastdl`. Empty on the first start means "seed me": the image writes
its template there, on your host, ready to edit.

```yaml
    volumes:
      - hlds-content:/srv/hlds:ro
      - ./fastdl:/opt/fastdl
```

```
[fastdl] seeded /opt/fastdl with the image's template — edit it and restart
[fastdl] using 1 template(s) from /opt/fastdl
```

| `/opt/fastdl` | what happens |
|---|---|
| not mounted | the image's built-in config is used |
| mounted, empty | seeded with the template, then used |
| mounted, has `*.template` | yours — copied over the built-in one every start, read-only is fine |
| mounted, empty, read-only | cannot be seeded; warns and falls back to built-in |

The mount point is **not** `/etc/nginx/templates`, and that is deliberate. A mount hides what
was underneath it, so mounting your own directory straight onto the templates directory would
hide the baked template and nginx would render nothing at all — the same trap as mounting
`content/maps` onto `cstrike/maps`. So the template lives in a private directory inside the
image and the entrypoint copies it into place, which is what makes an empty mount safe.

The seeded file is handed to whoever owns the directory you mounted, so you can edit it as
yourself. The container runs as root, and anything it writes into a bind mount is root-owned by
default — a template you would then need `sudo` to change.

The entrypoint only prepares the config, then hands over to `nginx`'s own
`/docker-entrypoint.sh` — the `envsubst` step that turns `*.template` into a real config lives
there and is not reimplemented.

### Why its config is an allowlist

The game directory is not only client content. Next to the maps sit `cstrike/.rcon_password`
and `cstrike/cs16-moded.cfg`, both holding the rcon password in plain text, plus `server.cfg`,
`rehlds.cfg`, `reunion.cfg` and `addons/` with its adminlist. So only extensions a joining
client actually needs are served, `addons/` is denied outright by a prefix location that beats
the regex, and everything else — dotfiles included — is refused without being named. A new kind
of file in the game directory is private by default.

`.nav` is excluded too: bot navigation is server-side only, and it is ~10 MB nobody downloads.

`image-fastdl.yml` asserts this in CI against a fake game directory — a map returns 200 while
`.rcon_password`, `cs16-moded.cfg`, `server.cfg`, `addons/**`, `.nav` and directory listings all
return 403, and it greps the response body to be sure the password is not served. Widening the
allowlist by accident fails the build.

Verified against the real thing:

```
cstrike/maps/de_mirage_cs2.bsp             206      Content-Type: application/octet-stream
cstrike/cstrike.wad                        206      Content-Range present, so resumable
cstrike/.rcon_password                     403
cstrike/cs16-moded.cfg                     403
cstrike/addons/pugmod/cfg/adminlist.cfg    403
cstrike/maps/de_dust2.nav                  403
cstrike/                                   403
```

GoldSrc clients cannot handle `Content-Encoding` on downloads, so `gzip off` is set — a gzipped
`.bsp` arrives corrupt. (Compressed fastdl is a Source-engine convention and uses `.bz2` files,
which HL1 does not read either.)
