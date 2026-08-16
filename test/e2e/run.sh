#!/usr/bin/env bash
# fs-portal end-to-end test. Spins up a privileged docker:dind container (a
# real Linux dockerd, so FUSE mount propagation behaves like production /
# unraid, unlike Docker Desktop's VM) and runs the full two-computer topology
# inside it: isolated networks, iroh-only path, real jellyfin+plex consumers.
#
# Usage: test/e2e/run.sh            # full run (core + real media servers)
#        SKIP_MEDIA_SERVERS=1 ...   # skip the jellyfin/plex image pulls
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
IMAGE="${IMAGE:-fs-portal:dev}"
DIND=fsp-e2e-dind
DIND_IMAGE="${DIND_IMAGE:-docker:28-dind}"

# Docker Desktop only shares $HOME-ish paths into its VM
STAGE_ROOT="${FSP_WORK_ROOT:-$HOME/.cache/fs-portal-tests}"
STAGE="$STAGE_ROOT/e2e-stage"

cleanup() {
  docker rm -f "$DIND" >/dev/null 2>&1
  rm -rf "$STAGE"
}
trap cleanup EXIT

echo "== build + export image =="
docker build -q -t "$IMAGE" "$ROOT" >/dev/null || { echo "FATAL: build failed"; exit 1; }
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp "$HERE/inner.sh" "$STAGE/inner.sh"
docker save -o "$STAGE/fs-portal-image.tar" "$IMAGE"

echo "== boot dind harness ($DIND_IMAGE) =="
docker rm -f "$DIND" >/dev/null 2>&1
docker run -d --privileged --name "$DIND" \
  -e DOCKER_TLS_CERTDIR="" \
  -v "$STAGE:/e2e:ro" \
  "$DIND_IMAGE" >/dev/null || { echo "FATAL: dind failed to start"; exit 1; }

up=no
for _ in $(seq 1 60); do
  docker exec "$DIND" docker info >/dev/null 2>&1 && { up=yes; break; }
  sleep 1
done
if [[ "$up" != yes ]]; then
  echo "FATAL: inner dockerd never came up"; docker logs "$DIND" | tail -30; exit 1
fi

echo "== stage: core (E2E_ISOLATED=${E2E_ISOLATED:-0}) =="
docker exec -e E2E_ISOLATED="${E2E_ISOLATED:-0}" "$DIND" sh /e2e/inner.sh core
core_rc=$?

media_rc=0
if [[ "${SKIP_MEDIA_SERVERS:-0}" != 1 && $core_rc -eq 0 ]]; then
  echo "== stage: media (real jellyfin + plex) =="
  docker exec "$DIND" sh /e2e/inner.sh media
  media_rc=$?
fi

echo
if [[ $core_rc -eq 0 && $media_rc -eq 0 ]]; then
  echo "e2e: ALL STAGES PASSED"
  exit 0
fi
echo "e2e: FAILED (core=$core_rc media=$media_rc)"
exit 1
