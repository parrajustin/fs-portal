# fs-portal

Share two media libraries between two computers, in both directions, over
[iroh](https://www.iroh.computer/) — no port forwarding, no VPN, works behind
NAT. Each side runs **one extra container**; plex/jellyfin then see the other
computer's library as ordinary **read-only files** and can add it as a normal
library folder.

```
computer A (jellyfin)          iroh (QUIC, e2e-encrypted,     computer B (plex)
                               hole-punched, relay fallback)
media ──▶ fs-portal ◀═════════════════════════════════════▶ fs-portal ◀── media
             │  FUSE mount of B's library          FUSE mount of A's library │
             ▼                                                               ▼
        jellyfin sees /data/friend-media/media          plex sees /friend-media/media
```

Under the hood: `rclone serve webdav --read-only` (localhost-only) is tunneled
out by `dumbpipe listen-tcp` (iroh); the other side bridges it back with
`dumbpipe connect-tcp` and FUSE-mounts it with `rclone mount --read-only`.
dumbpipe is **built from source vendored in [vendor/dumbpipe/](vendor/dumbpipe/)**
(pinned tag + `Cargo.lock`, provenance in its `UPSTREAM` file) — the image
never downloads upstream release binaries.
The FUSE mount propagates to sibling containers via the standard
`rshared`/`rslave` bind pattern. Full rationale and alternatives considered:
[research.md](research.md).

## Setup (once per pair)

Both computers do the same thing; only the compose file differs
([compose/computer-a-jellyfin.yml](compose/computer-a-jellyfin.yml) vs
[compose/computer-b-plex.yml](compose/computer-b-plex.yml)).

1. **Get the image** onto each computer (any one of):

   ```sh
   # from Docker Hub (published by release.sh)
   docker pull xerofuzzion/fs-portal:latest-x86_64
   # …or build from this repo checkout
   docker build -t fs-portal:latest .
   # …or build on one machine and carry it over
   docker save fs-portal:latest | gzip > fs-portal.tar.gz   # sender
   docker load < fs-portal.tar.gz                            # receiver
   ```

   Releases are cut with `./release.sh` (pushes `v<N>-x86_64` and
   `latest-x86_64`; add `--arm64` for aarch64, slow under QEMU).

2. **Add to `.env`** (next to your existing compose `.env`):

   ```sh
   FS_PORTAL_SECRET=$(openssl rand -hex 32)   # generate; keep private; never reuse the other side's
   FS_PORTAL_PEER_TICKET=                     # empty for now
   FS_PORTAL_ROOT=/opt/fs-portal              # any host dir (unraid: /mnt/cache_ssd/appdata/fs-portal)
   ```

   The secret is the computer's permanent iroh identity — the "fixed
   receiver". As long as it doesn't change, the ticket you exchange in step 4
   stays valid forever.

3. **Merge the `fs-portal` service** from the matching file in
   [compose/](compose/) into your stack, and add the **one new volume line**
   to your plex/jellyfin service:

   ```yaml
   - ${FS_PORTAL_ROOT}/portal:/friend-media:rslave        # plex
   - ${FS_PORTAL_ROOT}/portal:/data/friend-media:rslave   # jellyfin
   ```

4. **Start + exchange tickets** (one time, any order):

   ```sh
   docker compose up -d fs-portal
   docker logs fs-portal      # prints a big banner with YOUR ticket
   ```

   Send your ticket to the other person, put theirs in
   `FS_PORTAL_PEER_TICKET`, then `docker compose up -d` (recreates the
   container with the env). Alternatively, drop it in a file without a
   restart: `docker exec fs-portal sh -c 'cat > /config/peer_ticket'` and
   paste + Ctrl-D. Sloppy pastes are fine — the whole
   `dumbpipe connect-tcp <ticket>` line is accepted.

5. **Point the media server at it.** In plex add library folder
   `/friend-media/media`; in jellyfin add `/data/friend-media/media`.
   Restart plex/jellyfin once if the folder was empty when they started.

## Modes

`ROLES` picks what this fs-portal instance does (`transmitter`/`receiver`/
`both`; `export`/`import` are accepted synonyms, comma-combinable,
case-insensitive):

| Mode | What runs | Use when |
| --- | --- | --- |
| `both` (default) | serve your library **and** mount theirs | the normal two-way setup in the compose examples |
| `transmitter` | serve your library over iroh + print your ticket; no FUSE mount | you share but don't want their library (e.g. a seedbox/NAS that only feeds a friend) |
| `receiver` | mount their library only; mints no ticket, needs `PEER_TICKET` | a box that only consumes (e.g. a travel/HTPC machine), or a 3rd machine mounting an existing transmitter |

### Example: `transmitter` (share only)

**A pure `transmitter` needs no FUSE privileges at all.** `SYS_ADMIN`,
`/dev/fuse`, `apparmor:unconfined`, and the `:rshared` portal bind exist only
for the *mount* (receiver) side. It prints/persists your ticket and serves
your library read-only over iroh — nothing else:

```yaml
services:
  fs-portal:
    image: xerofuzzion/fs-portal:latest-x86_64
    container_name: fs-portal
    restart: always
    environment:
      - ROLES=transmitter
      - IROH_SECRET=${FS_PORTAL_SECRET} # openssl rand -hex 32
      - FSP_MAX_STREAMS=5 # max files streamed at once (0 = unlimited)
    volumes:
      - /path/to/your/media:/export:ro
      - ${FS_PORTAL_ROOT}/config:/config # keeps identity + ticket.txt
    # no cap_add, no devices, no security_opt, no portal/cache volumes
```

### Example: `receiver` (mount only)

Mints no ticket of its own; it just mounts the transmitter's library at
`${FS_PORTAL_ROOT}/portal/media` on the host for your media server (which
adds `- ${FS_PORTAL_ROOT}/portal:/friend-media:rslave` and uses
`/friend-media/media`):

```yaml
services:
  fs-portal:
    image: xerofuzzion/fs-portal:latest-x86_64
    container_name: fs-portal
    restart: always
    environment:
      - ROLES=receiver
      - PEER_TICKET=${FS_PORTAL_PEER_TICKET} # ticket from the transmitter
      - FSP_MAX_STREAMS=5 # max files streamed at once (0 = unlimited)
    volumes:
      - ${FS_PORTAL_ROOT}/portal:/portal:rshared
      - ${FS_PORTAL_ROOT}/config:/config
      - ${FS_PORTAL_ROOT}/cache:/cache
    cap_add:
      - SYS_ADMIN
    devices:
      - /dev/fuse
    security_opt:
      - apparmor:unconfined
```

### Example: `both` (two-way, the usual setup)

Union of the two: your media in, their media out. This is what the full
stacks in [compose/](compose/) use:

```yaml
services:
  fs-portal:
    image: xerofuzzion/fs-portal:latest-x86_64
    container_name: fs-portal
    restart: always
    environment:
      - ROLES=both
      - IROH_SECRET=${FS_PORTAL_SECRET}
      - PEER_TICKET=${FS_PORTAL_PEER_TICKET:-} # empty on first boot
      - FSP_MAX_STREAMS=5 # max files streamed at once (0 = unlimited)
    volumes:
      - /path/to/your/media:/export:ro
      - ${FS_PORTAL_ROOT}/portal:/portal:rshared
      - ${FS_PORTAL_ROOT}/config:/config
      - ${FS_PORTAL_ROOT}/cache:/cache
    cap_add:
      - SYS_ADMIN
    devices:
      - /dev/fuse
    security_opt:
      - apparmor:unconfined
```

Least privilege per mode:

| | `transmitter` | `receiver` | `both` |
| --- | --- | --- | --- |
| `cap_add: SYS_ADMIN` + `devices: /dev/fuse` + `apparmor:unconfined` | — | required | required |
| `…/portal:/portal:rshared` volume | — | required | required |
| `…/cache:/cache` volume | — | recommended | recommended |
| `/export` bind (`:ro`) | required | — | required |
| `IROH_SECRET` / `/config` | required (ticket identity) | recommended¹ | required |
| `PEER_TICKET` | — | required | required |

¹ a receiver works without a stable secret (it mints no ticket anyone dials),
but keeping `/config` mounted avoids a fresh node id on every boot.

The healthcheck adapts automatically: it only probes the pieces the chosen
mode runs. Single modes are exercised on every integration run (the test
exporter is `ROLES=export`, the importer `ROLES=import`).

## Guarantees

- **Read-only, three layers deep**: the WebDAV export is `--read-only`, the
  FUSE mount is `--read-only`, and your media is bound into fs-portal with
  `:ro`. Nobody can modify or delete your files through the portal.
- **Fixed receiver**: node identity derives from `IROH_SECRET`; tickets never
  expire or change. IPs, ISPs, and NATs can change freely — iroh rediscovers
  the peer by node id.
- **Self-healing**: every process is supervised and restarts on failure;
  stale FUSE mounts are cleaned before remount; the `rslave` consumer bind
  means plex/jellyfin pick up a fresh mount after an fs-portal restart with
  no action (verified by the e2e suite).
- **Nothing listens on your LAN**: the WebDAV server binds 127.0.0.1 inside
  the container; the only ingress is the iroh endpoint.
- **Bounded concurrency**: at most `FSP_MAX_STREAMS` (default 5) files are
  streamed at once. Each side enforces its own cap inside the iroh tunnel —
  the transmitter throttles a greedy/misbehaving peer, and the receiver
  throttles its own media server (e.g. a library scan opening every file) —
  so one bulk read can't spiral into 100% CPU. Excess opens simply queue
  until a slot frees; nothing errors. Set `0` to disable.
- **Bounded bandwidth** (opt-in): `FSP_BWLIMIT` caps rclone's transfer rate
  on each side — the transmitter throttles what it serves into the tunnel,
  the receiver throttles its own reads of the peer (both verified against
  rclone v1.71). `FSP_MAX_STREAMS` bounds *how many* files stream at once;
  `FSP_BWLIMIT` bounds *how fast* they flow in total, which also bounds the
  CPU spent on iroh's per-chunk encryption. `10M` = 10 MiB/s (units are
  Byte/s, not bit/s); `UP:DOWN` pairs (`10M:1M`) and [rclone bwlimit
  timetables](https://rclone.org/docs/#bwlimit-bandwidth-spec) also work.

## Observability

Everything is observable from `docker logs` and four Prometheus endpoints.

**Logs (console, structured):**

- `[dumbpipe-listen]` / `[dumbpipe-connect]` — per-stream lifecycle from the
  vendored dumbpipe: `stream start` (with current active count),
  `chunk forwarded` every 32 MiB per direction (`chunk_mib`, `speed_mib_s`,
  `total_mib`), and `stream closed` with byte totals and average MiB/s per
  direction (`duration_s`, `from_peer_mib`, `avg_from_peer_mib_s`, …).
  Queueing on `FSP_MAX_STREAMS` is logged when it happens. Verbosity is the
  standard `RUST_LOG` filter (default `dumbpipe=info`; set `dumbpipe=debug`
  or `iroh=debug` for connection internals).
- `[rclone-serve]` — every WebDAV request the peer makes, at
  `FSP_RCLONE_LOG_LEVEL` (default `INFO`).
- `[rclone-mount]` — VFS/cache activity plus a one-line transfer stats
  summary every `FSP_STATS_INTERVAL` (default `60s`): cumulative bytes,
  current speed, active transfers.

**Prometheus endpoints** (in-container, bound `0.0.0.0`, *not* published by
default — add `ports:` to scrape from outside; `FSP_METRICS=0` disables all):

| Port | Process | What you get |
| --- | --- | --- |
| `9101` | rclone serve (transmitter) | rclone core + HTTP server metrics |
| `9102` | rclone mount (receiver) | rclone VFS/cache/transfer metrics |
| `9103` | dumbpipe listen (transmitter) | `dumbpipe_connections_total/active/closed`, `dumbpipe_bytes_{to,from}_peer_total`, `dumbpipe_connection_errors_total`, `dumbpipe_queue_waits_total`, `dumbpipe_stream_duration_ms_total` |
| `9104` | dumbpipe connect (receiver) | same counters, receiver side |

Scrape example (add to the fs-portal service: `ports: ["9101-9104:9101-9104"]`):

```yaml
scrape_configs:
  - job_name: fs-portal
    static_configs:
      - targets: ["your-host:9101", "your-host:9102", "your-host:9103", "your-host:9104"]
```

Average stream speed in PromQL:
`rate(dumbpipe_bytes_from_peer_total[5m])` (bytes/s), and
`dumbpipe_stream_duration_ms_total / 1000 / dumbpipe_connections_closed_total`
for mean stream lifetime. An OpenTelemetry collector picks all of this up
as-is (`prometheus` receiver for the four endpoints, `filelog`/docker
receiver for the console logs) — the dumbpipe logs are structured key=value
`tracing` output, deliberately kept OTLP-free so the vendored `Cargo.lock`
stays pinned.

## Environment reference (fs-portal container)

| Var | Default | Meaning |
| --- | --- | --- |
| `ROLES` | `both` | `transmitter` (share your library only), `receiver` (mount theirs only), or `both`; `export`/`import` accepted as synonyms, comma-combinable |
| `IROH_SECRET` | generated → `/config/iroh_secret` | 64-hex stable identity (`openssl rand -hex 32`) |
| `PEER_TICKET` | — | other side's ticket; or file `/config/peer_ticket` (live pickup) |
| `EXPORT_DIR` | `/export` | what you share (bind it `:ro`) |
| `MOUNT_DIR` | `/portal/media` | where the peer's library appears |
| `FSP_MAX_STREAMS` | `5` | max files streamed concurrently, enforced on both sides (`0` = unlimited) |
| `FSP_BWLIMIT` | `off` | total rclone bandwidth cap per side, e.g. `10M` = 10 MiB/s; accepts `UP:DOWN` pairs and rclone timetables |
| `FSP_VFS_CACHE_MAX_SIZE` | `2G` | local read cache for streaming |
| `FSP_DIR_CACHE_TIME` | `30s` | how quickly new remote files appear |
| `FSP_METRICS` | `1` | `0` disables all four Prometheus endpoints |
| `FSP_SERVE_METRICS_PORT` / `FSP_MOUNT_METRICS_PORT` | `9101` / `9102` | rclone metrics ports |
| `FSP_LISTEN_METRICS_PORT` / `FSP_CONNECT_METRICS_PORT` | `9103` / `9104` | dumbpipe metrics ports |
| `FSP_RCLONE_LOG_LEVEL` | `INFO` | rclone log level (`DEBUG` for per-read detail) |
| `FSP_STATS_INTERVAL` | `60s` | rclone mount transfer-stats log cadence |
| `RUST_LOG` | `dumbpipe=info` | dumbpipe/tracing filter (`dumbpipe=debug`, `iroh=debug`) |

Container needs: `cap_add: SYS_ADMIN`, `devices: /dev/fuse`,
`security_opt: apparmor:unconfined`, and the portal dir bound `:rshared`
(see compose examples). Healthcheck goes healthy only when the export
answers and the peer mount is listable.

## Tests

```sh
tools/fs-portal/test/unit/run.sh          # pure shell-lib tests, no docker
tools/fs-portal/test/integration/run.sh   # 2 containers, real iroh, RO+seek+restart checks
tools/fs-portal/test/e2e/run.sh           # full topology in docker:dind — two isolated
                                          # "computers", propagation, busybox consumers,
                                          # REAL jellyfin + plex reading each other's libs
                                          # (SKIP_MEDIA_SERVERS=1 to skip the big pulls,
                                          #  E2E_ISOLATED=1 for the relay-only variant —
                                          #  see research.md for why that's opt-in)
```

The e2e runs inside `docker:dind` because Docker Desktop's VM does not
propagate FUSE mounts across its virtiofs boundary; dind is a faithful stand-in
for the real Linux hosts this deploys to (details in
[research.md](research.md)).

## Troubleshooting

- `docker logs fs-portal` — the banner reprints your ticket on every boot;
  `[rclone-mount]`/`[dumbpipe-*]` prefixes show which piece is unhappy.
- Container unhealthy while `waiting for peer ticket` is normal pre-pairing.
- Empty `/friend-media` in plex/jellyfin: check the portal dir is bound
  `:rshared` on fs-portal and `:rslave` on the media server, and that the
  host path is on a `shared` mount (`findmnt -o TARGET,PROPAGATION /`).
- First mount can take ~a minute if hole punching falls back to a relay.
