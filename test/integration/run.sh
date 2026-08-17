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
IDC=fsp-int-identity
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
  docker rm -f "$EXP" "$IMP" "$IDC" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== fixtures =="
mkdir -p "$WORK/media/Movies/Big Movie (2020)" "$WORK/media/Shows/Some Show/Season 01" \
  "$WORK/media/cap" "$WORK/config"
head -c $((8 * 1024 * 1024)) /dev/urandom > "$WORK/media/Movies/Big Movie (2020)/big.movie.2020.mkv"
head -c $((1 * 1024 * 1024)) /dev/urandom > "$WORK/media/Shows/Some Show/Season 01/e01.mkv"
echo "hello from exporter" > "$WORK/media/note.txt"
# fixtures for the stream-cap check: 4 files pulled in parallel later
for i in 1 2 3 4; do
  head -c $((32 * 1024 * 1024)) /dev/urandom > "$WORK/media/cap/cap$i.bin"
done
chmod -R a+rX "$WORK/media" "$WORK/config"

docker network create "$NET" >/dev/null 2>&1 || true

echo "== start exporter =="
docker rm -f "$EXP" "$IMP" >/dev/null 2>&1
# FSP_MAX_STREAMS=2 on the exporter (looser 3 on the importer) so the
# stream-cap check below can attribute the limit to the transmitter side.
# --no-healthcheck: the background healthcheck wgets the webdav port and
# would pollute the connection counting.
docker run -d --name "$EXP" --network "$NET" --no-healthcheck \
  -e ROLES=export \
  -e FSP_MAX_STREAMS=2 \
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
# FSP_PROCS=2: two dumbpipe connect-tcp tunnel processes (ports 8081+8082),
# rclone mounting the union of both — all the content checks below then run
# through the multi-process path.
# FSP_PEER_ADDR: the stable ticket carries no addresses, so hint the
# exporter's direct address (container IP + pinned FSP_IROH_PORT) like a
# same-LAN deployment would — otherwise every dial is relay-first, which is
# slow and flaky from a single source IP.
EXP_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$EXP")"
docker run -d --name "$IMP" --network "$NET" --no-healthcheck \
  -e ROLES=import \
  -e PEER_TICKET="$TICKET" \
  -e FSP_MAX_STREAMS=3 \
  -e FSP_PROCS=2 \
  -e FSP_PEER_ADDR="$EXP_IP:4919" \
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

echo "== stream cap: exporter FSP_MAX_STREAMS=2 =="
# The exporter's dumbpipe is the only client of rclone serve on
# 127.0.0.1:8080, and it forwards one tcp connection per concurrent stream.
# So under a cap of 2, the exporter must never hold more than 2 established
# connections to :8080 (1F90 hex), no matter how many reads the importer
# fires in parallel. Sample /proc/net/tcp on the exporter while 4 raw-webdav
# downloads run concurrently from the importer.
docker exec -i "$EXP" sh -c 'cat > /tmp/conn-sampler.sh' <<'EOS'
#!/bin/bash
# record the max simultaneous client connections to 127.0.0.1:8080 (:1F90)
echo 0 > /tmp/fsp-max-conns
max=0
end=$((SECONDS + 120))
while (( SECONDS < end )); do
  n=$(awk '$3 ~ /:1F90$/ && $4 == "01"' /proc/net/tcp | wc -l)
  (( n > max )) && { max=$n; echo "$max" > /tmp/fsp-max-conns; }
  sleep 0.05
done
EOS
docker exec -d "$EXP" bash /tmp/conn-sampler.sh
cap_pids=()
for i in 1 2 3 4; do
  docker exec "$IMP" sh -c "timeout 150 rclone --webdav-url=http://127.0.0.1:8081 --webdav-vendor=other copyto :webdav:cap/cap$i.bin /tmp/cap$i.bin 2>/dev/null" &
  cap_pids+=($!)
done
cap_rc=0
for p in "${cap_pids[@]}"; do wait "$p" || cap_rc=1; done
t "4 parallel downloads all complete under the cap (rc)" 0 $cap_rc
cap_sha_ok=yes
for i in 1 2 3 4; do
  want="$(sha256sum "$WORK/media/cap/cap$i.bin" | awk '{print $1}')"
  got="$(docker exec "$IMP" sh -c "sha256sum /tmp/cap$i.bin" | awk '{print $1}')"
  [[ "$want" == "$got" ]] || cap_sha_ok="no (cap$i.bin)"
done
t "parallel downloads byte-identical" "yes" "$cap_sha_ok"
max_conns="$(docker exec "$EXP" cat /tmp/fsp-max-conns)"
docker exec "$EXP" pkill -f conn-sampler >/dev/null 2>&1
echo "  observed max concurrent webdav connections: $max_conns"
t "sampler saw traffic (max >= 1)" "yes" "$([[ "$max_conns" -ge 1 ]] && echo yes)"
t "never more than 2 concurrent streams reach the exporter" "yes" \
  "$([[ "$max_conns" -le 2 ]] && echo yes)"

echo "== multi-process import: FSP_PROCS=2 =="
# exec pgrep directly (no sh -c wrapper: its cmdline would match the pattern)
n_tunnels="$(docker exec "$IMP" pgrep -f 'dumbpipe connect-tcp' | wc -l)"
t "two tunnel processes running" "2" "$(echo "$n_tunnels" | tr -d '[:space:]')"
port2=no
docker exec "$IMP" bash -c '(exec 3<>/dev/tcp/127.0.0.1/8082) 2>/dev/null' && port2=yes
t "second tunnel port open (8082)" "yes" "$port2"

echo "== read-only enforcement: layer 1, receiver FUSE mount =="
docker exec "$IMP" sh -c 'touch /portal/media/should-fail 2>/dev/null'; t "write rejected (rc)" 1 $?
docker exec "$IMP" sh -c 'rm "/portal/media/note.txt" 2>/dev/null'; t "delete rejected (rc)" 1 $?
t "note.txt still on exporter" "yes" "$([[ -f "$WORK/media/note.txt" ]] && echo yes)"

echo "== read-only enforcement: layer 2, sender webdav (mount bypassed) =="
# a hostile/modified receiver talks straight to the tunneled WebDAV port; the
# exporter's own `rclone serve --read-only` must reject writes on its own.
docker exec "$IMP" sh -c 'echo evil > /tmp/evil.txt && rclone --webdav-url=http://127.0.0.1:8081 --webdav-vendor=other copyto /tmp/evil.txt :webdav:evil.txt 2>/dev/null'
t "raw webdav PUT rejected (rc)" 1 $?
t "PUT left no file on exporter" "yes" "$([[ ! -e "$WORK/media/evil.txt" ]] && echo yes)"
docker exec "$IMP" sh -c 'rclone --webdav-url=http://127.0.0.1:8081 --webdav-vendor=other deletefile :webdav:note.txt 2>/dev/null'
t "raw webdav DELETE rejected (rc)" 1 $?
t "note.txt survives raw DELETE" "yes" "$([[ -f "$WORK/media/note.txt" ]] && echo yes)"

echo "== read-only enforcement: layer 3, sender :ro bind =="
# even a compromised fs-portal container cannot write the media: docker
# mounted it read-only at the kernel level.
docker exec "$EXP" sh -c 'touch /export/evil-from-exporter 2>/dev/null'; t "exporter container write rejected (rc)" 1 $?
t "no file appeared in sender media" "yes" "$([[ ! -e "$WORK/media/evil-from-exporter" ]] && echo yes)"

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

echo "== observability: prometheus endpoints =="
# rclone serve (9101) and rclone mount (9102) expose rclone's native metrics;
# the vendored dumbpipe exposes forwarding counters on 9103 (listen) and
# 9104 (connect). All bind 0.0.0.0 in-container but nothing is published.
# retry each scrape briefly: the exporter was just restarted above and its
# supervised processes respawn on a 2s cadence
scrape() { # scrape <container> <port> <marker-regex>
  local i m
  for i in $(seq 1 15); do
    m="$(docker exec "$1" wget -qO- -T 3 "http://127.0.0.1:$2/metrics" 2>/dev/null)"
    if echo "$m" | grep -q "$3"; then echo "$m"; return 0; fi
    sleep 1
  done
  echo ""
}
m="$(scrape "$EXP" 9101 '^go_\|^rclone')"
t "rclone serve metrics respond" "yes" "$([[ -n "$m" ]] && echo yes)"
m="$(scrape "$IMP" 9102 '^go_\|^rclone')"
t "rclone mount metrics respond" "yes" "$([[ -n "$m" ]] && echo yes)"
m="$(scrape "$EXP" 9103 '^dumbpipe_connections_total')"
t "dumbpipe listen metrics respond" "yes" "$([[ -n "$m" ]] && echo yes)"
# the receiver side is one central metrics server on 9104: both tunnel
# processes push to it (pushes arrive within ~5s, covered by scrape retries)
# and the merged exposition labels every sample with its proc
m="$(scrape "$IMP" 9104 'proc="dp2"')"
t "central metrics server responds with both tunnels" "yes" "$([[ -n "$m" ]] && echo yes)"
t "metrics carry proc=dp1 label" "yes" "$(echo "$m" | grep -q 'proc="dp1"' && echo yes)"
t "push freshness gauge present" "yes" "$(echo "$m" | grep -q '^dumbpipe_metrics_push_age_seconds{proc="dp1"}' && echo yes)"
port9105=closed
docker exec "$IMP" bash -c '(exec 3<>/dev/tcp/127.0.0.1/9105) 2>/dev/null' && port9105=open
t "no per-process metrics port (9105 closed)" "closed" "$port9105"
# the importer's tunnels survived the whole run: together they must have
# counted the earlier transfers (8MB movie + parallel caps) as bytes from
# the peer (values are per-proc samples now — sum them)
bytes_from_peer="$(echo "$m" | awk '/^dumbpipe_bytes_from_peer_total[{ ]/{s+=$2} END{print s+0}')"
t "dumbpipe counted transferred bytes (>1MB)" "yes" "$([[ "${bytes_from_peer:-0}" -gt 1000000 ]] && echo yes)"
conns="$(echo "$m" | awk '/^dumbpipe_connections_total[{ ]/{s+=$2} END{print s+0}')"
t "dumbpipe counted connections (>=1)" "yes" "$([[ "${conns:-0}" -ge 1 ]] && echo yes)"

echo "== observability: stream logs =="
logs="$(docker logs "$IMP" 2>&1)"
t "stream start logged" "yes" "$(echo "$logs" | grep -q 'stream start' && echo yes)"
t "stream close logged with speed" "yes" "$(echo "$logs" | grep -q 'stream closed' && echo yes)"
t "rclone mount logs at INFO" "yes" "$(echo "$logs" | grep -q 'INFO' && echo yes)"

echo "== observability: per-file logs and metrics =="
# dumbpipe sniffs the tunneled webdav requests: which file, bytes, avg speed,
# and when reading stopped — on both sides, in logs and metric families.
exp_logs="$(docker logs "$EXP" 2>&1)"
t "transmitter logs which file is read" "yes" \
  "$(echo "$exp_logs" | grep 'file read start' | grep -q 'big.movie.2020.mkv' && echo yes)"
t "transmitter logs read end with avg speed" "yes" \
  "$(echo "$exp_logs" | grep 'file read closed' | grep -q 'avg_mib_s' && echo yes)"
t "receiver logs which file is read" "yes" \
  "$(echo "$logs" | grep 'file read' | grep -q 'big.movie.2020.mkv' && echo yes)"
# per-file metrics: check the receiver's central server — its tunnel
# processes were never restarted, so their counters span the whole run
fm="$(scrape "$IMP" 9104 'dumbpipe_file_bytes_sent_total')"
t "per-file metrics exposed" "yes" "$([[ -n "$fm" ]] && echo yes)"
movie_bytes="$(echo "$fm" | grep '^dumbpipe_file_bytes_sent_total{file="/Movies/Big Movie (2020)/big.movie.2020.mkv"' | awk '{s+=$NF} END{print s+0}')"
t "movie bytes attributed to its file (>=8MB)" "yes" "$([[ "${movie_bytes:-0}" -ge 8388608 ]] && echo yes)"
t "per-file read seconds tracked" "yes" \
  "$(echo "$fm" | grep -q '^dumbpipe_file_read_seconds_total{file=' && echo yes)"
t "per-file requests counted" "yes" \
  "$(echo "$fm" | grep -q '^dumbpipe_file_requests_total{file="/Movies/Big Movie (2020)/big.movie.2020.mkv"' && echo yes)"

echo "== fixed receiver: ticket is a pure function of IROH_SECRET =="
# Cycle one transmitter through secrets A -> A -> B -> A across full
# stop/starts (fresh container + fresh /config each time, so nothing but the
# secret can carry the identity over) and compare the minted tickets:
#   X (A) == Y (A restart); Z (B) differs from both; W (A again) == X.
# The secrets deliberately contain hex digits outside the base32 alphabet
# (0/1/8/9) so the ticket parser can never mistake a logged secret for a
# ticket.
SECRET_A="$(printf 'a0a1a8a9%.0s' 1 2 3 4 5 6 7 8)"
SECRET_B="$(printf 'b0b1b8b9%.0s' 1 2 3 4 5 6 7 8)"

start_identity() { # start_identity <secret> — stop the server, start with the given identity
  docker rm -f "$IDC" >/dev/null 2>&1
  docker run -d --name "$IDC" --network "$NET" --no-healthcheck \
    -e ROLES=export \
    -e IROH_SECRET="$1" \
    -v "$WORK/media:/export:ro" \
    "$IMAGE" >/dev/null || { echo "FATAL: identity transmitter failed to start"; exit 1; }
}

get_ticket() { # get_ticket <container> — wait for the ticket in this boot's logs
  local i tk
  for i in $(seq 1 60); do
    tk="$(docker logs "$1" 2>&1 | grep -oE '[a-z2-7]{50,}' | head -n 1)"
    [[ -n "$tk" ]] && { echo "$tk"; return 0; }
    sleep 1
  done
  return 1
}

start_identity "$SECRET_A"; TX="$(get_ticket "$IDC")"
t "secret A mints ticket X" "yes" "$([[ -n "$TX" ]] && echo yes)"
start_identity "$SECRET_A"; TY="$(get_ticket "$IDC")"
t "restart with secret A: Y == X" "$TX" "$TY"
start_identity "$SECRET_B"; TZ="$(get_ticket "$IDC")"
t "secret B mints ticket Z" "yes" "$([[ -n "$TZ" ]] && echo yes)"
t "Z != Y" "different" "$([[ "$TZ" == "$TY" ]] && echo same || echo different)"
t "Z != X" "different" "$([[ "$TZ" == "$TX" ]] && echo same || echo different)"
start_identity "$SECRET_A"; TW="$(get_ticket "$IDC")"
t "back to secret A: W == X" "$TX" "$TW"
docker rm -f "$IDC" >/dev/null 2>&1

echo
echo "integration: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
