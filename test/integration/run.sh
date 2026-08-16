#!/usr/bin/env bash
# Integration test: two fs-portal containers on one docker network.
#   exporter: serves a fixture library over iroh
#   importer: FUSE-mounts it and must see identical, read-only content
# Verifies: listing, byte-identical reads, mid-file seeks, read-only
# enforcement, and survival of an exporter restart.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-fs-portal:dev}"
NET=fsp-int-net
EXP=fsp-int-exporter
IMP=fsp-int-importer
# Docker Desktop only shares whitelisted host paths (e.g. $HOME) into its VM,
# so the bind-mount fixtures must live under $HOME, not /tmp.
FSP_WORK_ROOT="${FSP_WORK_ROOT:-$HOME/.cache/fs-portal-tests}"
mkdir -p "$FSP_WORK_ROOT"
WORK="$(mktemp -d "$FSP_WORK_ROOT/fsp-int.XXXXXX")"

PASS=0; FAIL=0
t() { # t <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "  ok   $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; fi
}

cleanup() {
  docker rm -f "$EXP" "$IMP" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== fixtures =="
mkdir -p "$WORK/media/Movies/Big Movie (2020)" "$WORK/media/Shows/Some Show/Season 01" "$WORK/config"
head -c $((8 * 1024 * 1024)) /dev/urandom > "$WORK/media/Movies/Big Movie (2020)/big.movie.2020.mkv"
head -c $((1 * 1024 * 1024)) /dev/urandom > "$WORK/media/Shows/Some Show/Season 01/e01.mkv"
echo "hello from exporter" > "$WORK/media/note.txt"
chmod -R a+rX "$WORK/media" "$WORK/config"

docker network create "$NET" >/dev/null 2>&1 || true

echo "== start exporter =="
docker rm -f "$EXP" "$IMP" >/dev/null 2>&1
docker run -d --name "$EXP" --network "$NET" \
  -e ROLES=export \
  -v "$WORK/media:/export:ro" \
  -v "$WORK/config:/config" \
  "$IMAGE" >/dev/null || { echo "FATAL: exporter failed to start"; exit 1; }

TICKET=""
for _ in $(seq 1 60); do
  TICKET="$(cat "$WORK/config/ticket.txt" 2>/dev/null)"
  [[ -n "$TICKET" ]] && break
  sleep 1
done
if [[ -z "$TICKET" ]]; then
  echo "FATAL: no ticket appeared; exporter logs:"; docker logs "$EXP" | tail -40; exit 1
fi
t "ticket produced" "yes" "yes"
echo "  ticket: ${TICKET:0:32}..."

echo "== start importer =="
docker run -d --name "$IMP" --network "$NET" \
  -e ROLES=import \
  -e PEER_TICKET="$TICKET" \
  --cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor:unconfined \
  "$IMAGE" >/dev/null || { echo "FATAL: importer failed to start"; exit 1; }

mounted=no
for _ in $(seq 1 60); do
  if docker exec "$IMP" sh -c 'grep -q " /portal/media fuse.rclone" /proc/mounts && ls /portal/media' >/dev/null 2>&1; then
    mounted=yes; break
  fi
  sleep 1
done
t "peer library mounted" "yes" "$mounted"
if [[ "$mounted" != yes ]]; then
  echo "importer logs:"; docker logs "$IMP" | tail -40
  echo "exporter logs:"; docker logs "$EXP" | tail -20
  exit 1
fi

echo "== content checks =="
want_list="$(cd "$WORK/media" && find . | LC_ALL=C sort)"
got_list="$(docker exec "$IMP" sh -c 'cd /portal/media && find . | LC_ALL=C sort')"
t "recursive listing identical" "$want_list" "$got_list"

want_note="hello from exporter"
got_note="$(docker exec "$IMP" cat /portal/media/note.txt)"
t "small file content" "$want_note" "$got_note"

want_sha="$(sha256sum "$WORK/media/Movies/Big Movie (2020)/big.movie.2020.mkv" | awk '{print $1}')"
got_sha="$(docker exec "$IMP" sh -c "sha256sum '/portal/media/Movies/Big Movie (2020)/big.movie.2020.mkv'" | awk '{print $1}')"
t "8MB file byte-identical over iroh" "$want_sha" "$got_sha"

# seek: read 64KB starting 5MB in, like a player seeking mid-stream
want_seek="$(dd if="$WORK/media/Movies/Big Movie (2020)/big.movie.2020.mkv" bs=64K skip=80 count=1 2>/dev/null | sha256sum | awk '{print $1}')"
got_seek="$(docker exec "$IMP" sh -c "dd if='/portal/media/Movies/Big Movie (2020)/big.movie.2020.mkv' bs=64K skip=80 count=1 2>/dev/null | sha256sum" | awk '{print $1}')"
t "mid-file seek read" "$want_seek" "$got_seek"

echo "== read-only enforcement =="
docker exec "$IMP" sh -c 'touch /portal/media/should-fail 2>/dev/null'; t "write rejected (rc)" 1 $?
docker exec "$IMP" sh -c 'rm "/portal/media/note.txt" 2>/dev/null'; t "delete rejected (rc)" 1 $?
t "note.txt still on exporter" "yes" "$([[ -f "$WORK/media/note.txt" ]] && echo yes)"

echo "== healthchecks =="
docker exec "$EXP" /opt/fs-portal/healthcheck.sh; t "exporter healthcheck" 0 $?
docker exec "$IMP" /opt/fs-portal/healthcheck.sh; t "importer healthcheck" 0 $?

echo "== exporter restart resilience =="
docker restart "$EXP" >/dev/null
recovered=no
for _ in $(seq 1 90); do
  got="$(docker exec "$IMP" cat /portal/media/note.txt 2>/dev/null)"
  [[ "$got" == "$want_note" ]] && { recovered=yes; break; }
  sleep 1
done
t "reads recover after exporter restart" "yes" "$recovered"

echo
echo "integration: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
