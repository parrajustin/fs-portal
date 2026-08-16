# fs-portal — research

Goal: two computers, each running a media server in docker (computer A =
jellyfin, computer B = plex), each with its own local media library. Each side
should see the *other* side's library as ordinary **read-only files**, so it
can be added as a normal library folder in plex/jellyfin. Transport must be
[iroh](https://www.iroh.computer/) (p2p QUIC with hole punching + relay
fallback), with a **fixed receiver identity on both sides** so the pairing
survives restarts and IP changes.

## Options considered

### 1. Custom Rust daemon: iroh + `fuser` (write our own FUSE fs)

Write a Rust binary that speaks a bespoke protocol over iroh
(`list/stat/read-range`) and exposes the remote tree through
[fuser](https://crates.io/crates/fuser).

- ✅ Tightest possible integration, single binary.
- ❌ We would own a filesystem implementation: readdir caching, inode
  lifetimes, page-sized read splitting, reconnect logic, backpressure. This
  is precisely the code that produces subtle bugs under a media scanner that
  stats tens of thousands of files.
- ❌ Long compile/iteration cycle; hard to make "just work" reliably compared
  to reusing battle-tested components.

**Rejected** — too much novel, failure-prone surface for a v1.

### 2. iroh-blobs / sendme

iroh's own content-addressed blob layer. Great for snapshot transfer, but it
is content-addressed (BLAKE3 hashes), not a live mutable directory tree. A
media library changes constantly; re-hashing and re-announcing is the wrong
shape. **Rejected.**

### 3. NFS over an iroh tunnel

Kernel NFS client would need `mount -t nfs` in the *consumer* containers
(plex/jellyfin images don't do that, and it needs privileged mounts there).
`rclone serve nfs` + kernel mount in the portal container works, but NFS over
TCP-over-QUIC adds nothing over WebDAV here and the kernel NFS client handles
flaky transports worse (hard/soft mount hangs). **Rejected.**

### 4. Plain API (expose HTTP file API, no filesystem)

Plex/jellyfin cannot consume an HTTP API as a library — they scan
directories. A filesystem is a hard requirement. **Rejected** (as the final
interface; HTTP is fine as the *internal* hop, see below).

### 5. ✅ Chosen: dumbpipe (iroh) + rclone WebDAV serve/mount + docker mount propagation

Compose three battle-tested pieces, each doing the one thing it is good at:

```
computer A (jellyfin side)                     computer B (plex side)
──────────────────────────                     ──────────────────────
/data/media (local library)                    /mnt/user/video (local library)
      │ bind ro                                      │ bind ro
┌─────▼──────────────────────┐                ┌──────▼─────────────────────┐
│ fs-portal container        │                │ fs-portal container        │
│  rclone serve webdav :8080 │                │  rclone serve webdav :8080 │
│  dumbpipe listen-tcp ──────┼── iroh QUIC ───┼─▶ dumbpipe connect-tcp     │
│  dumbpipe connect-tcp ◀────┼── (2 tunnels) ─┼── dumbpipe listen-tcp      │
│  rclone mount webdav       │                │  rclone mount webdav       │
│   └▶ /portal/media (FUSE)  │                │   └▶ /portal/media (FUSE)  │
└─────┬──────────────────────┘                └──────┬─────────────────────┘
      │ rshared bind to host dir                     │ rshared bind to host dir
┌─────▼──────────┐                            ┌──────▼─────────┐
│ jellyfin       │  sees B's library          │ plex           │  sees A's library
│ /friend-media  │  as read-only files        │ /friend-media  │  as read-only files
└────────────────┘                            └────────────────┘
```

Each computer runs **one fs-portal container** doing both roles:

- **export**: `rclone serve webdav /export --read-only` on localhost, tunneled
  out with `dumbpipe listen-tcp`. Nothing but the iroh endpoint is exposed to
  the network — the WebDAV server itself binds `127.0.0.1` inside the
  container.
- **import**: `dumbpipe connect-tcp` materializes the peer's WebDAV server on
  a local port, and `rclone mount --read-only --allow-other` turns it into a
  FUSE filesystem at `/portal/media`.

### Why each piece

**dumbpipe** ([n0-computer/dumbpipe](https://github.com/n0-computer/dumbpipe))
is iroh's official "netcat over iroh" tool:

- `listen-tcp --host 127.0.0.1:8080` forwards incoming iroh connections to a
  local TCP service; `connect-tcp --addr 0.0.0.0:8080 <ticket>` does the
  reverse. Multiple concurrent TCP connections are supported (each spawns its
  own task / QUIC bi-stream).
- **Fixed receiver:** dumbpipe reads the `IROH_SECRET` env var
  (hex-encoded ed25519 secret) for a **stable node id**. The listen side's
  ticket therefore stays valid forever — you exchange tickets **once** when
  pairing the two machines. Verified in `src/main.rs`:
  `std::env::var("IROH_SECRET") → SecretKey::from_str(...)`.
- Traffic is end-to-end encrypted QUIC; iroh does hole punching (both sides
  behind NAT is fine) and falls back to n0's public relays when punching
  fails. The ticket embeds node id + relay + last-known direct addrs; only
  the node id matters long-term (discovery finds current addrs).
- Prebuilt static binaries: `dumbpipe-v0.39.0-linux-{x86_64,aarch64}.tar.gz`
  (latest release v0.39.0 at time of writing).
- Security model: possession of the ticket (node id) is the credential. The
  export is read-only at the rclone layer; additionally rclone WebDAV auth
  (user/pass) can be layered on via env if desired.

**rclone** does both halves of the filesystem work and is the industry
standard for exactly this:

- `rclone serve webdav --read-only` — read-only enforced server-side; range
  requests supported, so seeking inside a 40GB remux works without
  downloading the file.
- `rclone mount` (FUSE, needs `/dev/fuse` + `SYS_ADMIN`) with
  `--vfs-cache-mode full` is the well-trodden path for serving Plex/Jellyfin
  from a remote backend: sequential read-ahead for streaming, dir/attr
  caching so library scans don't hammer the link, `--read-only` again at the
  mount layer (defense in depth — consumers cannot write even though mount
  propagation ignores the consumer's `ro` bind flag for propagated
  submounts).
- The official `rclone/rclone` docker image is alpine + fuse3, ready to go.

**Docker mount propagation** is how a FUSE mount made *inside* the portal
container becomes visible to sibling containers with **zero special
privileges on the plex/jellyfin side**:

- fs-portal binds a host dir with `rshared` propagation:
  `/host/portal:/portal:rshared`, then FUSE-mounts at `/portal/media`. The
  mount event propagates container → host → any container that binds
  `/host/portal` with `rslave`.
- plex/jellyfin add one volume: `/host/portal:/friend-media:rslave` and see
  the files at `/friend-media/media`. `rslave` (not a plain bind of the
  subdir) is critical: if fs-portal restarts and remounts, consumers pick up
  the *new* mount automatically instead of holding a dead
  "transport endpoint not connected" handle.
- Requirements on the portal container only: `cap_add: [SYS_ADMIN]`,
  `devices: [/dev/fuse]`, `security_opt: [apparmor:unconfined]` — the
  standard rclone-mount-in-docker recipe. The host path must live on a
  `shared` mount (true for `/` on stock Linux, unraid included).

### Pairing / key model ("fixed receiver on either side")

Each side generates one ed25519 secret (`openssl rand -hex 32`) and keeps it
in its `.env`. The secret determines the node id, which determines the
ticket. Setup is a one-time 2-message exchange:

1. A starts fs-portal → logs + writes `/config/ticket.txt` → sends ticket to B.
2. B puts A's ticket in `PEER_TICKET`, starts fs-portal, sends its own ticket
   back to A; A sets `PEER_TICKET` and restarts.

After that, nothing ever needs re-exchanging: IPs, NATs, and networks can
change; iroh discovery + relays find the peer by node id.

## Failure modes & mitigations

| Failure | Mitigation |
| --- | --- |
| dumbpipe or rclone process dies | supervisor loop in entrypoint restarts the child; container `restart: always` as backstop |
| link drops mid-stream | QUIC reconnects; VFS retries (`--low-level-retries`, `--vfs-read-chunk-size`) |
| fs-portal restarts while plex is running | `rslave` consumer bind picks up the fresh mount; stale handles don't pin the old one |
| consumer writes to remote library | impossible three times over: WebDAV served `--read-only`, mount is `--read-only`, plex/jellyfin library configured read-only |
| ticket leaks | rotate `IROH_SECRET` (new ticket), optional WebDAV user/pass adds a second factor |
| library scan slowness | `--dir-cache-time`/`--attr-timeout` on the mount; scans hit cache, only opens traverse the link |

## Test environment caveat (why e2e runs in dind)

The dev machine runs **Docker Desktop for Linux** (linuxkit VM). Host bind
mounts cross a virtiofs boundary, so FUSE mount propagation from a container
back through a host dir is not representative of a real Linux docker host
(unraid etc.). The e2e therefore runs the whole two-computer topology inside
a privileged `docker:dind` container: a genuine Linux dockerd where
`rshared`/`rslave` behave exactly as they will in production. Inside dind the
two "computers" get **isolated bridge networks** so the only path between
them is iroh.

## Sources

- https://github.com/n0-computer/dumbpipe (README + `src/main.rs` for `IROH_SECRET`, ALPN, per-connection tasks)
- https://github.com/n0-computer/dumbpipe/releases (v0.39.0 linux static binaries)
- https://www.iroh.computer/ (hole punching, relays, node ids)
- https://rclone.org/commands/rclone_serve_webdav/ , https://rclone.org/commands/rclone_mount/
- rclone forum: [mount propagation to sibling containers without stale endpoints](https://forum.rclone.org/t/propogating-rclone-mounts-to-docker-containers-without-transport-endpoint-going-stale/48112) (`rshared` producer / `rslave` consumer pattern)
- https://github.com/RadPenguin/docker-rclone-mount (SYS_ADMIN + /dev/fuse + apparmor recipe)
