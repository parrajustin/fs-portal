#!/usr/bin/env bash
# fs-portal entrypoint — runs one or both roles:
#   export: rclone serve webdav (localhost) + dumbpipe listen-tcp (iroh)
#   import: dumbpipe connect-tcp (iroh) + rclone FUSE mount of the peer
set -uo pipefail

source /opt/fs-portal/lib.sh

log() { echo "[fs-portal] $*"; }
die() { echo "[fs-portal] FATAL: $*" >&2; exit 1; }

CONFIG_DIR="${CONFIG_DIR:-/config}"
EXPORT_DIR="${EXPORT_DIR:-/export}"
MOUNT_DIR="${MOUNT_DIR:-/portal/media}"
FSP_WEBDAV_PORT="${FSP_WEBDAV_PORT:-8080}"
FSP_IMPORT_PORT="${FSP_IMPORT_PORT:-8081}"
FSP_CACHE_DIR="${FSP_CACHE_DIR:-/cache}"
TICKET_FILE="$CONFIG_DIR/ticket.txt"
SECRET_FILE="$CONFIG_DIR/iroh_secret"

ROLES_ACTIVE="$(fsp_roles "${ROLES:-}")" || die "invalid ROLES='${ROLES:-}'"
log "roles: $ROLES_ACTIVE"
FSP_MAX_STREAMS="$(fsp_max_streams "${FSP_MAX_STREAMS:-}")" || die "invalid FSP_MAX_STREAMS='${FSP_MAX_STREAMS:-}'"
if [[ "$FSP_MAX_STREAMS" -gt 0 ]]; then
  log "max concurrent file streams: $FSP_MAX_STREAMS (FSP_MAX_STREAMS; 0 = unlimited)"
else
  log "max concurrent file streams: unlimited (set FSP_MAX_STREAMS to cap)"
fi
mkdir -p "$CONFIG_DIR"

# ---- identity -------------------------------------------------------------
# One stable secret per computer => stable node id => the ticket you hand to
# the other side never changes ("fixed receiver").
if [[ -z "${IROH_SECRET:-}" && -f "$SECRET_FILE" ]]; then
  IROH_SECRET="$(cat "$SECRET_FILE")"
  log "loaded iroh secret from $SECRET_FILE"
fi
if [[ -z "${IROH_SECRET:-}" ]]; then
  IROH_SECRET="$(fsp_gen_secret)"
  (umask 077 && printf '%s' "$IROH_SECRET" > "$SECRET_FILE")
  log "generated new iroh secret -> $SECRET_FILE (set IROH_SECRET or keep /config mounted to keep a stable identity)"
fi
fsp_is_valid_secret "$IROH_SECRET" || die "IROH_SECRET must be 64 hex chars (openssl rand -hex 32)"
export IROH_SECRET

PIDS=()

cleanup() {
  log "shutting down"
  if [[ " $ROLES_ACTIVE " == *" import "* ]]; then
    fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || umount -l "$MOUNT_DIR" 2>/dev/null || true
  fi
  [[ ${#PIDS[@]} -gt 0 ]] && kill "${PIDS[@]}" 2>/dev/null
  # children of the supervisor subshells
  pkill -P $$ 2>/dev/null
  pkill rclone 2>/dev/null
  pkill dumbpipe 2>/dev/null
  exit 0
}
trap cleanup TERM INT

supervise() { # supervise <name> <cmd...> — restart forever, prefix output
  local name="$1"; shift
  (
    while true; do
      "$@" 2>&1 | while IFS= read -r line; do echo "[$name] $line"; done
      log "$name exited (rc=$?), restarting in 2s"
      sleep 2
    done
  ) &
  PIDS+=($!)
}

# dumbpipe listener needs its ticket captured from log output the first time.
supervise_listener() {
  (
    while true; do
      dumbpipe listen-tcp --host "127.0.0.1:$FSP_WEBDAV_PORT" --max-connections "$FSP_MAX_STREAMS" 2>&1 | while IFS= read -r line; do
        echo "[dumbpipe-listen] $line"
        ticket="$(printf '%s\n' "$line" | fsp_parse_ticket)"
        if [[ -n "$ticket" && "$(cat "$TICKET_FILE" 2>/dev/null)" != "$ticket" ]]; then
          printf '%s' "$ticket" > "$TICKET_FILE"
          echo ""
          echo "=================================================================="
          echo " fs-portal EXPORT is ready."
          echo " Give this ticket to the other computer (their PEER_TICKET):"
          echo ""
          echo "   $ticket"
          echo ""
          echo " (also saved to $TICKET_FILE; stable as long as the secret is)"
          echo "=================================================================="
          echo ""
        fi
      done
      log "dumbpipe-listen exited, restarting in 2s"
      sleep 2
    done
  ) &
  PIDS+=($!)
}

wait_for_port() { # wait_for_port <port> <seconds>
  local port="$1" deadline=$(( $(date +%s) + $2 ))
  while (( $(date +%s) < deadline )); do
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
    sleep 0.5
  done
  return 1
}

# ---- export role ----------------------------------------------------------
if [[ " $ROLES_ACTIVE " == *" export "* ]]; then
  [[ -d "$EXPORT_DIR" ]] || die "EXPORT_DIR $EXPORT_DIR is not mounted (bind your media library there, read-only)"
  mapfile -t serve_argv < <(fsp_serve_args)
  log "export: serving $EXPORT_DIR read-only via webdav on 127.0.0.1:$FSP_WEBDAV_PORT"
  supervise rclone-serve rclone "${serve_argv[@]}"
  wait_for_port "$FSP_WEBDAV_PORT" 30 || die "rclone serve webdav did not come up"
  log "export: opening iroh receiver (stable node id from IROH_SECRET)"
  supervise_listener
fi

# ---- import role ----------------------------------------------------------
if [[ " $ROLES_ACTIVE " == *" import "* ]]; then
  # Wait (don't die) for the peer's ticket: both computers can boot before
  # tickets have been exchanged. Accept the PEER_TICKET env or a
  # $CONFIG_DIR/peer_ticket file that may appear at any time.
  PEER_TICKET="${PEER_TICKET:-$(cat "$CONFIG_DIR/peer_ticket" 2>/dev/null)}"
  if [[ -z "${PEER_TICKET:-}" ]]; then
    log "import: waiting for peer ticket. Copy the ticket printed by the OTHER computer's fs-portal (also in its /config/ticket.txt) and either set PEER_TICKET in the environment (then recreate this container) or write it to $CONFIG_DIR/peer_ticket (picked up live)."
    i=0
    while [[ -z "${PEER_TICKET:-}" ]]; do
      sleep 5
      PEER_TICKET="$(cat "$CONFIG_DIR/peer_ticket" 2>/dev/null)"
      i=$((i + 1))
      (( i % 12 == 0 )) && log "import: still waiting for $CONFIG_DIR/peer_ticket ..."
    done
    log "import: peer ticket received"
  fi
  # tolerate sloppy pastes: pull the bare base32 token out of whatever we got
  # (full "dumbpipe connect-tcp <ticket>" lines, stray whitespace, ...)
  PEER_TICKET="$(printf '%s\n' "$PEER_TICKET" | fsp_parse_ticket)"
  [[ -n "$PEER_TICKET" ]] || die "PEER_TICKET did not contain a valid dumbpipe ticket"

  mkdir -p "$MOUNT_DIR" "$FSP_CACHE_DIR"
  # clear any stale mount from an unclean shutdown
  fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || umount -l "$MOUNT_DIR" 2>/dev/null || true

  log "import: bridging peer's webdav to 127.0.0.1:$FSP_IMPORT_PORT over iroh"
  supervise dumbpipe-connect dumbpipe connect-tcp --addr "127.0.0.1:$FSP_IMPORT_PORT" --max-connections "$FSP_MAX_STREAMS" "$PEER_TICKET"
  wait_for_port "$FSP_IMPORT_PORT" 30 || die "dumbpipe connect-tcp did not open local port"

  mapfile -t mount_argv < <(fsp_mount_args "$MOUNT_DIR")
  log "import: mounting peer library at $MOUNT_DIR (read-only)"
  (
    while true; do
      # a dead rclone leaves a stale FUSE mount behind; clear it or the next
      # mount attempt fails with "transport endpoint is not connected"
      fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || umount -l "$MOUNT_DIR" 2>/dev/null || true
      rclone "${mount_argv[@]}" 2>&1 | while IFS= read -r line; do echo "[rclone-mount] $line"; done
      log "rclone-mount exited, restarting in 2s"
      sleep 2
    done
  ) &
  PIDS+=($!)
fi

log "up. waiting on children."
wait
