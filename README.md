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

## Stations: adding and removing

The single source of truth is [stations.toml](stations.toml). Everything else
is generated from it by `make apply`.

### What you do by hand, and what is generated

| | By hand | Generated |
|---|---|---|
| **Relay** | a block in `stations.toml` | everything else |
| **Own station** | a block in `stations.toml`, a directory with `index.liq`, an HLS directory on the server | everything else |

"Everything else" means:

| File | What it gets |
|---|---|
| `docker/generated/stations.json` | the registry for omfmapi and listeners_monitor |
| `docker/icecast/config/icecast.xml` | `<relay>` and `<mount>` blocks |
| `docker-compose.yaml` | the `liquidsoap-<station>` service: ports, volumes, healthcheck, environment |

Only the regions between the `GENERATED` markers are rewritten — do not edit
them by hand. `make check` fails the build if the generated files drift out of
sync with the registry.

The generator validates duplicate `mount` values and ports, required fields,
and the headroom left in Icecast's `<sources>` limit — so a typo is caught
before deploy rather than on air.

### Adding a relay

One edit and one command.

**1.** A block in `stations.toml`:

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

**2.** Generate and apply:

```bash
make apply && make verify
docker compose up -d --build icecast
```

`--build` is mandatory: `icecast.xml` is baked into the image at build time, so
without a rebuild the new mount will not appear. Listeners get dropped for
about a minute.

### Adding your own station

**1.** A block in `stations.toml`:

```toml
[stations.night]
kind         = "local"
name         = "omFM Night"
shortcode    = "night"        # Centrifugo channel: station:night
mount        = "/night"
fallback     = "/fallback-[192].aac"
description  = "Night stream" # goes into output.icecast
genre        = "Lofi"
url          = "https://omfm.ru"
timezone     = "Europe/Moscow"
harbor_port  = 8009           # must be free, the generator checks
telnet_port  = 1236
hls_playlist = "night.m3u8"
monitor      = true
```

**2.** The script directory — take an existing station as a template:

```bash
mkdir -p docker/liquidsoap/rootfs/home/radio/liquidsoap/night
cp docker/liquidsoap/rootfs/home/radio/liquidsoap/cdp/index.liq \
   docker/liquidsoap/rootfs/home/radio/liquidsoap/night/
```

From there, edit **only the sources and the schedule** in that `index.liq`.
Everything else is pulled in from `../lib`, and the parameters come from the
environment — there is nothing to touch in the script. The `log` directory
inside the container is created by the Dockerfile.

**3.** A directory for HLS segments **on the server** (path from `[paths] hls_root`):

```bash
mkdir -p /var/www/html/omfm/hls/night
```

**4.** Generate, verify, bring it up:

```bash
make apply && make verify
make station-deploy STATION=night
```

**5.** Confirm it started:

```bash
make station-status                      # should reach healthy, up to 90 seconds
docker compose logs --tail=50 liquidsoap-night
```

If the logs are full of `Failed to obtain a media request`, the playlist is not
returning any tracks — check the music paths in `index.liq`.

### Removing a relay

**1.** Delete the block from `stations.toml`.

**2.**

```bash
make apply && make verify
docker compose up -d --build icecast
```

### Removing your own station

**1.** Delete the block from `stations.toml`.

**2.** Stop and remove the container — it will not disappear on its own:

```bash
docker compose stop liquidsoap-night && docker compose rm -f liquidsoap-night
```

Do this **before** `make apply`: once the service is gone from the compose
file, `docker compose` no longer knows about it, and the container is left
hanging around as an orphan still holding its ports.

If you already applied and the container is stuck as an orphan:

```bash
docker rm -f liquidsoap-night          # or docker compose up -d --remove-orphans
```

**3.** Apply and rebuild Icecast (the station had its own mount):

```bash
make apply && make verify
docker compose up -d --build icecast
```

**4.** Clean up after yourself — optional, but keeps things from piling up:

```bash
rm -rf docker/liquidsoap/rootfs/home/radio/liquidsoap/night
rm -rf /var/www/html/omfm/hls/night     # on the server
```

The station disappears from `/listeners` and `/np` immediately, and its ports
are freed for the next one.

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
make station-deploy  STATION=cdp   # rebuild and bring up cdp only
make station-restart STATION=cdp
make station-logs    STATION=cdp
make station-status                # state and healthcheck of every station
```

## Commands

```bash
make apply      # generate configs from stations.toml
make check      # confirm nothing has drifted
make verify     # check + liquidsoap --check + compose and source validation
make secrets    # rebuild the docker secrets (*.txt) from .env
make up         # docker compose up -d --build (runs check first)
make down
make logs
```

## Secrets

Every password, key and token lives in `.env` at the repo root — it is in
`.gitignore` and never reaches the repository. Template:
[.env.example](.env.example).

Also outside git: `docker/centrifugo/config.toml` (with a `.example` next to
it), `docker/listeners_monitor/*.txt`, and the Icecast TLS certificate
`docker/icecast/config/concat-om.pem` — which contains the private key.
The `*.txt` files are not edited by hand: they are rebuilt from `.env` by
`make secrets`.

First-time setup:

```bash
cp .env.example .env                              # fill in the values
cp docker/centrifugo/config.toml.example docker/centrifugo/config.toml
# copy the certificate separately, it is not in the repository:
#   scp concat-om.pem server:.../docker/icecast/config/
chmod 600 docker/icecast/config/concat-om.pem
make secrets && make apply && make up
```

Without `concat-om.pem` the Icecast build fails at `COPY` — that is expected.

Icecast refuses to start if the required variables are unset — deliberately, so
that it never comes up with a placeholder in place of a password.

## Notes

- [docker/liquidsoap/MIGRATION-NOTES.md](docker/liquidsoap/MIGRATION-NOTES.md)
  — what changed between Liquidsoap versions and the checklist for moving to
  2.5. The current image is `v2.4.5`.
