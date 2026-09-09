# omFM stack

***English** · [Русский](README.ru.md)*

A self-hosted internet radio stack: Liquidsoap plays our own stations, Icecast
serves and relays them, omfmapi collects now-playing and listener stats, and
Centrifugo pushes it all to clients over SSE.

```
Liquidsoap ──POST /np/:station──> omfmapi ──publish──> Centrifugo ──SSE──> nuxt-om
    │                                ▲
    └──> Icecast ──> listeners       │
         (+ relays from AzuraCast)   │
                                     │
    nginx access.log ──> listeners_monitor ──POST /listeners_stat
    icecast listclients ─┘
    AzuraCast API ───────────────────┘
```

## What it is made of

| Service | Port | Role |
|---|---|---|
| `liquidsoap-<station>` | `127.0.0.1:800x` harbor, `127.0.0.1:123x` telnet | plays one own station |
| `icecast` | `8000`, `8443` — public | serves mounts and relays |
| `omfmapi` | `127.0.0.1:9999` | the hub everything reports to |
| `listeners_monitor` | — | counts listeners across HLS and Icecast |
| `centrifugo` | `127.0.0.1:9998` | SSE broadcast to the frontend |

**Liquidsoap** — one container per own station. It plays the schedule, encodes
to Icecast and writes HLS segments at the same time, and once a second POSTs the
current now-playing state to omfmapi. It also exposes a harbor HTTP port
(`/nowplaying`, `/metadata`, `/queueFile`, `/queuePlaylist`, `/skipQueue`) and a
telnet port — both bound to localhost.

**Icecast** — serves the mounts of our own stations and relays remote ones (our
AzuraCast at `radio.omfm.ru` plus a few third-party streams). The only service
open to the outside world.

**omfmapi** — Node/Express. Everything reports to it, and it is the only thing
that talks to Centrifugo:

- accepts `POST /np/:station` from Liquidsoap and republishes the state to the
  `station:<shortcode>` channel **once every 15 seconds** — the stations push
  every second, omfmapi throttles;
- accepts `POST /listeners_stat` from the HLS monitor;
- polls the AzuraCast API every 30 seconds for the relays that have an
  `azuracast_id`;
- merges all three sources and publishes the result to `station:listeners`;
- serves `GET /np`, `GET /listeners`, `GET /spotifyToken` for reading.

The write endpoints require Basic auth, with credentials coming from docker
secrets.

**listeners_monitor — the HLS monitor.** A separate Python container. Our own
stations are listened to over two different transports, and this is the only
place where both are counted as one audience. Every 20 seconds it:

1. tails the nginx access log (`/var/log/nginx/hls-omfm.access.log`, mounted
   read-only) and picks out the `.ts` / `.m3u8` requests — those are the HLS
   listeners;
2. queries Icecast `/admin/listclients` for every station's mount, all mounts in
   parallel;
3. resolves geo data for new IPs through findip.net, cached for 24 hours;
4. treats a listener as live while it has been seen within the last 60 seconds
   (`refresh_interval × 3`), then POSTs the whole picture to omfmapi.

Only stations with `monitor = true` are counted, and HLS listeners are
recognised by the request path — so nginx has to actually write those requests
into that log file.

**Centrifugo** — uni_sse, broadcast only. Channels `station:<shortcode>` and
`station:listeners`, which nuxt-om subscribes to.

### Icecast is built from source, off master

`docker/icecast/Dockerfile` clones `icecast-server` and `icecast-libigloo`
straight from gitlab.xiph.org and builds them — with no tag and no pinned
commit. The image therefore always holds the **development version**, not a
release: whatever upstream master looked like on the day of the build. libigloo
is built from source for the same reason, to get ≥ 0.9.4.

The price is that the build is not reproducible: two rebuilds on different days
can yield two different Icecasts, and `docker compose up -d --build icecast`
after adding a station picks up whatever landed upstream in the meantime. If a
rebuild suddenly breaks something, look here first — the fix is to pin the
`git clone` to a known-good commit.

## Stations: adding and removing

The single source of truth is [stations.toml](stations.toml). Everything else
is generated from it. It is edited through a dialogue:

```bash
./omfm station new          # an own station, played by our Liquidsoap
./omfm relay new            # a relay of someone else's stream
./omfm station rm night
./omfm relay rm newfm
```

None of these take an irreversible step silently: before writing, the block
that will go into the registry — or be cut out of it — is printed, and you are
asked to confirm. Directories holding music and HLS segments are never deleted
by the script, it only prints the commands.

The file also cannot be left broken. The prospective registry is first run
through the generator's own validator in full: a duplicate port, `mount` or
`shortcode`, a missing required field, an exhausted `<sources>` limit — all of
it is caught **before** the original changes. If the check fails, the station
directory is not created either.

### An own station

`./omfm station new` asks for the station key and derives everything else from
it, offering defaults that Enter accepts:

| Field | Default |
|---|---|
| `name` | the key, capitalised |
| `shortcode` | the key (Centrifugo channel `station:<shortcode>`) |
| `mount` | `/<key>` |
| `hls_playlist` | `<key>.m3u8` |
| `harbor_port`, `telnet_port` | the first free ones, one above what is taken |
| `fallback` | `/fallback-[192].aac` |
| `timezone`, `url` | `Europe/Moscow`, `https://omfm.ru` |

Then it does the rest itself:

- appends the block **to the end** of `stations.toml`. The file is never
  re-read or rewritten as a whole, so comments and formatting elsewhere are
  guaranteed intact;
- creates the station directory together with `log/` — without that directory
  playlog fails with ENOENT and nothing but jingles goes on air;
- copies `index.liq` from a template station and puts a reminder on top of what
  to edit;
- runs `./omfm apply`;
- opens `index.liq` in `$EDITOR`.

What is left by hand is what it prints at the end:

```bash
# 1. sources and schedule in index.liq — those cannot be generated
# 2. the HLS segment directory ON THE SERVER, mounted by compose.
#    Liquidsoap writes there as the radio user (uid from USER_UID, 1000 by
#    default) — it can read a root-owned directory, but not write to it:
mkdir -p /var/www/html/omfm/hls/night
chown 1000:1000 /var/www/html/omfm/hls/night
# 3. bring the station up without touching the others:
./omfm verify && ./omfm station deploy night && ./omfm station status
# 4. rebuild Icecast so the mount appears:
docker compose up -d --build icecast
```

`--build` is mandatory: `icecast.xml` is baked into the image at build time, so
without a rebuild the new mount will not appear. Listeners get dropped for about
a minute.

If the station's logs are full of `Failed to obtain a media request`, the
playlist is not returning any tracks — check the music paths in `index.liq`.

### A relay

`./omfm relay new` is shorter: a relay has no container, no directory and no
script — only an entry in `icecast.xml`. It asks for the key, name, `mount`,
`upstream` and `azuracast_id`.

`azuracast_id` is given only if the station lives on our AzuraCast and its
listener list can be pulled from there. Without it the relay still plays, it
just will not appear in the stats.

Afterwards, one command:

```bash
docker compose up -d --build icecast
```

### Removing

```bash
./omfm station rm night
```

It shows the block to be cut, asks for confirmation, then offers to stop and
remove the container. **That has to happen before `apply`**: once the service is
gone from the compose file, `docker compose` no longer knows about it, and the
container is left as an orphan still holding its ports. If it is already too
late — `docker rm -f liquidsoap-night`.

The registry edit is guarded: the result is first written to a temporary file
and read back through `tomllib`. It replaces the original only if the set of
stations shrank by exactly the one requested and every other station stayed
identical. Otherwise the original is not touched at all.

The station directory and the HLS directory on the server are printed, not
deleted.

### What gets generated

| File | What it gets |
|---|---|
| `docker/generated/stations.json` | the registry for omfmapi and listeners_monitor |
| `docker/icecast/config/icecast.xml` | `<relay>` and `<mount>` blocks |
| `docker-compose.yaml` | the `liquidsoap-<station>` service: ports, volumes, healthcheck, environment |

Only the regions between the `GENERATED` markers are rewritten — do not edit
them by hand. The marker line itself is stored in those files and is what the
generator uses to find them, so its text cannot be changed casually. `./omfm
check` fails the build if the generated files drift out of sync with the
registry.

The generator validates duplicate `mount` values, ports and `shortcode`s,
required fields, and the headroom left in Icecast's `<sources>` limit — so a
typo is caught before deploy rather than on air. A duplicate `shortcode` is the
nastiest of those: two stations would publish into the same Centrifugo channel
and overwrite each other.

### If you edit the registry by hand

The dialogue does nothing magic, it simply appends a block like this:

```toml
[stations.night]
kind         = "local"
timezone     = "Europe/Moscow"
name         = "omFM Night"
shortcode    = "night"        # Centrifugo channel: station:night
mount        = "/night"
fallback     = "/fallback-[192].aac"
description  = "Night stream" # goes into output.icecast
genre        = "Lofi"
url          = "https://omfm.ru"
harbor_port  = 8009
telnet_port  = 1236
hls_playlist = "night.m3u8"
monitor      = true
```

```toml
[stations.newfm]
kind     = "relay"
name     = "New FM"
mount    = "/newfm"
fallback = "/fallback-[192].aac"
upstream = "http://radio.omfm.ru:8100/newfm.aac"
azuracast_id = 42   # only if the station lives on our AzuraCast — otherwise omit
monitor  = true     # false — do not collect listener stats for it
```

After editing — `./omfm apply && ./omfm verify`, then as above.

### How the Liquidsoap scripts are laid out

```
lib/settings.liq     station parameters from the environment + shared settings
lib/playlog.liq      log of what has played and the repeat check
lib/queues.liq       manual push queues + their HTTP endpoints
lib/nowplaying.liq   history, POSTing to omfmapi, /nowplaying, /metadata
lib/crossfade.liq    transitions between tracks
lib/output.liq       Icecast and HLS outputs
<station>/index.liq  ONLY sources and schedule
```

A station can extend the payload with its own block: that is how cdp adds
`playing_next`, which omfm does not have — with several playlists and a
schedule there is no way to reliably predict the next track.

### One station, one container

Each of our own stations is a separate `liquidsoap-<name>` service, not a
process inside a shared container under supervisord. What that buys:

- **a healthcheck on the harbor port** catches not just a crash but a **hang**.
  Supervisord only restarted a process that had died; a wedged liquidsoap
  (live process, dead air) it left alone entirely.
- a station can be rebuilt and restarted **without interrupting the others**
- each station's state is visible in `docker compose ps` and `docker logs`

```bash
./omfm station deploy cdp     # rebuild and bring up cdp only
./omfm station restart cdp
./omfm station logs cdp
./omfm station status         # state and healthcheck of every station
```

## Commands

Everything runs through [omfm](omfm) in the repository root. It can be called
from any directory — the script changes into the root itself.

```bash
./omfm apply      # generate configs from stations.toml
./omfm check      # confirm nothing has drifted
./omfm liq-check  # syntax of every .liq through liquidsoap --check
./omfm verify     # check + liq-check + compose and source validation
./omfm secrets    # rebuild the docker secrets (*.txt) from .env
./omfm up         # docker compose up -d --build (runs check first)
./omfm down
./omfm logs

./omfm station new | rm <name> | deploy <name> | restart <name> | logs <name> | status
./omfm relay   new | rm <name>
```

`./omfm help` prints the same list. Tab-completion for commands and station
names:

```bash
source tools/omfm-completion.bash
```

## Secrets

Every password, key and token lives in `.env` at the repo root — it is in
`.gitignore` and never reaches the repository. Template:
[.env.example](.env.example).

Also outside git: `docker/centrifugo/config.toml` (with a `.example` next to
it), `docker/listeners_monitor/*.txt`, and the Icecast TLS certificate
`docker/icecast/config/concat-om.pem` — which contains the private key.
The `*.txt` files are not edited by hand: they are rebuilt from `.env` by
`./omfm secrets`. If something is missing it does not write an empty file —
it names the missing variables and explains what they affect.

First-time setup:

```bash
cp .env.example .env                              # fill in the values
cp docker/centrifugo/config.toml.example docker/centrifugo/config.toml
# copy the certificate separately, it is not in the repository:
#   scp concat-om.pem server:.../docker/icecast/config/
# icecast does not run as root inside the container, and a private key must
# not be world-readable — so set the owner, not just the mode:
chown 1000:1000 docker/icecast/config/concat-om.pem   # uid: docker compose exec icecast id -u
chmod 400 docker/icecast/config/concat-om.pem
./omfm secrets && ./omfm apply && ./omfm up
```

Without `concat-om.pem` the Icecast build fails at `COPY` — that is expected.

The certificate is renewed by certbot, whose `post_hook` runs as root: the file
is recreated as `root:root`, the ownership is lost, and Icecast silently ends up
without TLS — it does not crash, it just logs `Invalid cert file` and keeps
serving port 8000 only. So the `chown` and the restart belong in the hook
itself:

```
post_hook = cat /etc/letsencrypt/live/omfm.ru/fullchain.pem \
                /etc/letsencrypt/live/omfm.ru/privkey.pem \
              > .../docker/icecast/config/concat-om.pem \
            && chown 1000:1000 .../concat-om.pem \
            && chmod 400 .../concat-om.pem \
            && docker restart icecast
```

The restart is required: the certificate is only read at startup.

Icecast refuses to start if the required variables are unset — deliberately, so
that it never comes up with a placeholder in place of a password.

## Notes

- [docker/liquidsoap/MIGRATION-NOTES.md](docker/liquidsoap/MIGRATION-NOTES.md)
  — what changed between Liquidsoap versions and the checklist for moving to
  2.5. The current image is `v2.4.5`.
