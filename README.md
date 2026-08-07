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
release assets pinned in `docker/Dockerfile`; the game content is downloaded from Steam
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
is kept and never called: `install_yapb_plugin()` in `docker/install-mods.sh` and
`yapb_cvars()` in `docker/configure-server.sh`. Switching back means calling those two
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

[Reunion](https://github.com/rehlds/ReUnion) is loaded **first** by metamod, so clients on
protocol 47/48 with no Steam ticket can connect. Upstream's `reunion.cfg` ships
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

## Your own cvars

`EXTRA_CVARS` takes console commands, one per line:

```yaml
    environment:
      EXTRA_CVARS: |
        mp_consistency 0
        sv_alltalk 1
```

Or point `EXTRA_CVARS_FILE` at a mounted file.

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

Edit the ARGs in `docker/Dockerfile`:

```dockerfile
ARG METAMOD_TAG=v1.3.0.149-r2
ARG PUGMOD_TAG=v1.0.1-pre
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
docker build -f docker/Dockerfile --build-arg PUGMOD_TAG=v1.0.2 -t cs16-moded-server:test .
```

## Check an image

```bash
docker run --rm ghcr.io/onixldlc/cs16-moded-server:latest verify
```

Asserts the engine, game dll and every mod binary are present and 32-bit, that
`liblist.gam` points at metamod, and that every plugin `plugins.ini` names exists. Prints
the pinned mod versions.

## Layout

```
docker/Dockerfile          two stages: fetch the mod releases, layer them on cs16-server
docker/entrypoint.sh       content -> mods -> hand over to the base entrypoint
docker/install-mods.sh     marker-based sync into the volumes
docker/fetch-nav.sh        one-off steamcmd fetch of the zBot navigation meshes
docker/verify.sh           image self-check
docker-compose.yml         what you actually run
```
