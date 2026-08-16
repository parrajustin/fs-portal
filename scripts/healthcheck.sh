#!/usr/bin/env bash
# Container healthcheck: every active role must actually be functional.
set -uo pipefail
source /opt/fs-portal/lib.sh

MOUNT_DIR="${MOUNT_DIR:-/portal/media}"
FSP_WEBDAV_PORT="${FSP_WEBDAV_PORT:-8080}"

ROLES_ACTIVE="$(fsp_roles "${ROLES:-}")" || exit 1

if [[ " $ROLES_ACTIVE " == *" export "* ]]; then
  # webdav answering locally?
  wget -q -T 5 -O /dev/null "http://127.0.0.1:$FSP_WEBDAV_PORT/" || exit 1
  # iroh receiver alive?
  pgrep -f 'dumbpipe listen-tcp' >/dev/null || exit 1
fi

if [[ " $ROLES_ACTIVE " == *" import "* ]]; then
  pgrep -f 'dumbpipe connect-tcp' >/dev/null || exit 1
  # FUSE mount actually present and listable
  grep -qs " $(echo "$MOUNT_DIR" | sed 's/ /\\\\040/g') fuse.rclone" /proc/mounts || exit 1
  ls "$MOUNT_DIR" >/dev/null 2>&1 || exit 1
fi

exit 0
