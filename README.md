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
The FUSE mount propagates to sibling containers via the standard
`rshared`/`rslave` bind pattern. Full rationale and alternatives considered:
[research.md](research.md).

## Setup (once per pair)

Both computers do the same thing; only the compose file differs
([compose/computer-a-jellyfin.yml](compose/computer-a-jellyfin.yml) vs
[compose/computer-b-plex.yml](compose/computer-b-plex.yml)).

1. **Get the image** onto each computer (any one of):

   ```sh
   # from this repo checkout
   docker build -t fs-portal:latest tools/fs-portal
   # …or build on one machine and carry it over
   docker save fs-portal:latest | gzip > fs-portal.tar.gz   # sender
   docker load < fs-portal.tar.gz                            # receiver
   ```

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

**A pure `transmitter` needs no FUSE privileges at all.** `SYS_ADMIN`,
`/dev/fuse`, `apparmor:unconfined`, and the `:rshared` portal bind exist only
for the *mount* (receiver) side. A transmitter-only service trims down to:

```yaml
  fs-portal:
    image: fs-portal:latest
    container_name: fs-portal
    restart: always
    environment:
      - ROLES=transmitter
      - IROH_SECRET=${FS_PORTAL_SECRET}
    volumes:
      - /path/to/your/media:/export:ro
      - ${FS_PORTAL_ROOT}/config:/config
    # no cap_add, no devices, no security_opt, no portal/cache volumes
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

## Environment reference (fs-portal container)

| Var | Default | Meaning |
| --- | --- | --- |
| `ROLES` | `both` | `transmitter` (share your library only), `receiver` (mount theirs only), or `both`; `export`/`import` accepted as synonyms, comma-combinable |
| `IROH_SECRET` | generated → `/config/iroh_secret` | 64-hex stable identity (`openssl rand -hex 32`) |
| `PEER_TICKET` | — | other side's ticket; or file `/config/peer_ticket` (live pickup) |
| `EXPORT_DIR` | `/export` | what you share (bind it `:ro`) |
| `MOUNT_DIR` | `/portal/media` | where the peer's library appears |
| `FSP_VFS_CACHE_MAX_SIZE` | `2G` | local read cache for streaming |
| `FSP_DIR_CACHE_TIME` | `30s` | how quickly new remote files appear |

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
