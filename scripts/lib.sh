#!/usr/bin/env bash
# fs-portal shell library — pure functions, unit-tested by test/unit/run.sh.
# Sourced by entrypoint.sh inside the container and by tests on the host.

# Extract a dumbpipe ticket from arbitrary log output on stdin.
# Tickets are long base32 (rfc4648 lowercase, no padding) tokens; anything
# shorter than 50 chars or containing non-base32 chars (e.g. hex secrets with
# 0/1/8/9) is not a ticket.
fsp_parse_ticket() {
  grep -oE '[a-z2-7]{50,}' | head -n 1
  return 0
}

# 32-byte hex secret (ed25519 seed) as accepted by dumbpipe's IROH_SECRET.
fsp_is_valid_secret() {
  [[ "${1-}" =~ ^[0-9a-fA-F]{64}$ ]]
}

fsp_gen_secret() {
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

# Normalize/validate the ROLES env. Canonical roles are "export" and
# "import"; "transmitter"/"receiver"/"both" are accepted aliases. Empty
# defaults to both. Echoes enabled roles space-separated in canonical order;
# rc=1 on junk.
fsp_roles() {
  local raw="${1-}" tok want_export=0 want_import=0
  if [[ -z "${raw//[[:space:]]/}" ]]; then
    echo "export import"
    return 0
  fi
  for tok in ${raw//,/ }; do
    case "${tok,,}" in
      export | transmitter) want_export=1 ;;
      import | receiver) want_import=1 ;;
      both)
        want_export=1
        want_import=1
        ;;
      *)
        echo "fs-portal: unknown role '$tok' (valid: transmitter/export, receiver/import, both)" >&2
        return 1
        ;;
    esac
  done
  local out=()
  [[ $want_export -eq 1 ]] && out+=(export)
  [[ $want_import -eq 1 ]] && out+=(import)
  echo "${out[*]}"
}

# rclone argv (newline-separated) serving EXPORT_DIR read-only over WebDAV,
# bound to localhost only — dumbpipe is the sole way in from outside.
fsp_serve_args() {
  printf '%s\n' \
    serve \
    webdav \
    "${EXPORT_DIR:-/export}" \
    --addr \
    "127.0.0.1:${FSP_WEBDAV_PORT:-8080}" \
    --read-only
}

# rclone argv (newline-separated) FUSE-mounting the peer's WebDAV (as exposed
# locally by `dumbpipe connect-tcp`) at $1. Read-only + allow-other so any
# sibling-container uid (plex/jellyfin PUID) can read through the propagated
# mount; full VFS cache is the recommended mode for media servers.
fsp_mount_args() {
  local target="$1"
  printf '%s\n' \
    mount \
    ":webdav:" \
    "$target" \
    "--webdav-url=http://127.0.0.1:${FSP_IMPORT_PORT:-8081}" \
    --webdav-vendor=other \
    --read-only \
    --allow-other \
    --umask=022 \
    --vfs-cache-mode=full \
    "--cache-dir=${FSP_CACHE_DIR:-/cache}" \
    "--vfs-cache-max-size=${FSP_VFS_CACHE_MAX_SIZE:-2G}" \
    "--vfs-read-chunk-size=${FSP_VFS_READ_CHUNK_SIZE:-8M}" \
    --vfs-read-chunk-size-limit=512M \
    "--dir-cache-time=${FSP_DIR_CACHE_TIME:-30s}" \
    --poll-interval=0 \
    --low-level-retries=20 \
    --retries=10
}
