#!/bin/sh
# Runs INSIDE the docker:dind harness container (real Linux dockerd, so
# rshared/rslave mount propagation behaves like a production host).
#
# Topology:
#   net-a (bridge, "computer A LAN")     net-b (bridge, "computer B LAN")
#     portal-a  export A media             portal-b  export B media
#               import B media                       import A media
#     consumer-a, jellyfin (rslave)        consumer-b, plex (rslave)
#   wan (bridge): second interface on BOTH portals — stands in for "both
#   machines are reachable over the internet", giving iroh a working direct
#   path. All application traffic still flows through iroh QUIC (tickets,
#   node-id auth, encryption); nothing else crosses between A and B.
#
# E2E_ISOLATED=1 removes the wan network so the portals can only meet
# through n0's public relay infrastructure. That is the true two-houses
# path, but from a CI host it is environment-dependent: both peers sit
# behind the SAME double NAT (symmetric, per-destination mappings — QAD
# reports "IPv4 address varies by destination") and repeated short-lived
# test endpoints from one IP get throttled by the public relay. Verified
# working occasionally in this rig, reliably only on genuinely distinct
# networks — so it is opt-in, not the default gate.
#
# Usage: inner.sh core   — fixtures, portals, busybox consumers, all checks
#        inner.sh media  — real jellyfin + plex containers see the mounts
set -u
E2E_ISOLATED="${E2E_ISOLATED:-0}"

STAGE="${1:-core}"
PASS=0; FAIL=0
t() { # t <name> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; fi
}
finish() {
  echo
  echo "e2e[$STAGE]: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
}

wait_for() { # wait_for <seconds> <cmd...>
  n="$1"; shift
  while [ "$n" -gt 0 ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1; n=$((n-1))
  done
  return 1
}

if [ "$STAGE" = "core" ]; then
  echo "== dind prep =="
  mount --make-rshared / 2>/dev/null || true
  docker load < /e2e/fs-portal-image.tar >/dev/null || { echo "FATAL: image load failed"; exit 1; }

  echo "== fixtures: computer A (jellyfin-style library) =="
  mkdir -p "/srv/computer-a/media/tvshows/Some Show/Season 01" \
           /srv/computer-a/media/movies \
           /srv/computer-a/portal /srv/computer-a/config /srv/computer-a/cache
  head -c $((4*1024*1024)) /dev/urandom > "/srv/computer-a/media/tvshows/Some Show/Season 01/e01.mkv"
  echo "library of computer A" > /srv/computer-a/media/A.txt

  echo "== fixtures: computer B (plex-style library) =="
  mkdir -p "/srv/computer-b/media/Movies/Big Movie (2020)" \
           "/srv/computer-b/media/TV Shows" \
           /srv/computer-b/portal /srv/computer-b/config /srv/computer-b/cache
  head -c $((4*1024*1024)) /dev/urandom > "/srv/computer-b/media/Movies/Big Movie (2020)/big.movie.mkv"
  echo "library of computer B" > /srv/computer-b/media/B.txt
  chmod -R a+rX /srv/computer-a /srv/computer-b

  echo "== networks (isolated=$E2E_ISOLATED) =="
  docker network create net-a >/dev/null
  docker network create net-b >/dev/null
  [ "$E2E_ISOLATED" = 1 ] || docker network create wan >/dev/null

  echo "== start portals (both roles, no peer ticket yet) =="
  for side in a b; do
    docker create --name "portal-$side" --network "net-$side" \
      -e ROLES=export,import \
      -v "/srv/computer-$side/media:/export:ro" \
      -v "/srv/computer-$side/portal:/portal:rshared" \
      -v "/srv/computer-$side/config:/config" \
      -v "/srv/computer-$side/cache:/cache" \
      --cap-add SYS_ADMIN --device /dev/fuse \
      --restart unless-stopped \
      fs-portal:dev >/dev/null || { echo "FATAL: portal-$side failed to create"; exit 1; }
    # attach the wan leg BEFORE first start so the iroh endpoint sees both
    # interfaces from the beginning and puts the reachable addr in its ticket
    [ "$E2E_ISOLATED" = 1 ] || docker network connect wan "portal-$side"
    docker start "portal-$side" >/dev/null || { echo "FATAL: portal-$side failed to start"; exit 1; }
  done

  echo "== ticket exchange (file-based, live pickup) =="
  ok=yes
  wait_for 120 test -s /srv/computer-a/config/ticket.txt || ok=no
  wait_for 120 test -s /srv/computer-b/config/ticket.txt || ok=no
  t "both portals minted tickets" yes "$ok"
  [ "$ok" = yes ] || { docker logs portal-a 2>&1 | tail -20; finish; }
  cp /srv/computer-a/config/ticket.txt /srv/computer-b/config/peer_ticket
  cp /srv/computer-b/config/ticket.txt /srv/computer-a/config/peer_ticket

  echo "== wait for cross mounts (iroh across isolated networks) =="
  m=yes
  wait_for 180 docker exec portal-a sh -c 'ls /portal/media/B.txt' || m=no
  t "portal-a mounted B's library" yes "$m"
  mb=yes
  wait_for 180 docker exec portal-b sh -c 'ls /portal/media/A.txt' || mb=no
  t "portal-b mounted A's library" yes "$mb"
  if [ "$m" != yes ] || [ "$mb" != yes ]; then
    echo "--- portal-a logs ---"; docker logs portal-a 2>&1 | tail -40
    echo "--- portal-b logs ---"; docker logs portal-b 2>&1 | tail -40
    finish
  fi

  echo "== propagation to the (dind) host =="
  h=yes; wait_for 30 test -e /srv/computer-a/portal/media/B.txt || h=no
  t "A host sees B's files via propagation" yes "$h"
  h=yes; wait_for 30 test -e /srv/computer-b/portal/media/A.txt || h=no
  t "B host sees A's files via propagation" yes "$h"

  echo "== sibling consumers (rslave) =="
  docker run -d --name consumer-a --network none \
    -v /srv/computer-a/portal:/friend-media:rslave busybox sleep 3600 >/dev/null
  docker run -d --name consumer-b --network none \
    -v /srv/computer-b/portal:/friend-media:rslave busybox sleep 3600 >/dev/null

  t "consumer on A reads B's note" "library of computer B" \
    "$(docker exec consumer-a cat /friend-media/media/B.txt 2>&1)"
  t "consumer on B reads A's note" "library of computer A" \
    "$(docker exec consumer-b cat /friend-media/media/A.txt 2>&1)"

  want="$(sha256sum '/srv/computer-b/media/Movies/Big Movie (2020)/big.movie.mkv' | awk '{print $1}')"
  got="$(docker exec consumer-a sh -c "sha256sum '/friend-media/media/Movies/Big Movie (2020)/big.movie.mkv'" | awk '{print $1}')"
  t "A->B 4MB movie byte-identical" "$want" "$got"

  want="$(sha256sum '/srv/computer-a/media/tvshows/Some Show/Season 01/e01.mkv' | awk '{print $1}')"
  got="$(docker exec consumer-b sh -c "sha256sum '/friend-media/media/tvshows/Some Show/Season 01/e01.mkv'" | awk '{print $1}')"
  t "B->A 4MB episode byte-identical" "$want" "$got"

  docker exec consumer-a sh -c 'touch /friend-media/media/nope 2>/dev/null'
  t "consumer write rejected (rc)" 1 $?

  echo "== portal restart: rslave consumers recover =="
  docker restart portal-a >/dev/null
  r=yes
  wait_for 120 docker exec consumer-a sh -c 'cat /friend-media/media/B.txt' || r=no
  t "consumer-a reads survive portal-a restart" yes "$r"

  finish
fi

if [ "$STAGE" = "media" ]; then
  echo "== real media servers see the propagated mounts =="
  docker pull jellyfin/jellyfin:latest >/dev/null 2>&1 || echo "  (jellyfin pull failed)"
  docker pull lscr.io/linuxserver/plex:latest >/dev/null 2>&1 || echo "  (plex pull failed)"

  docker run -d --name jellyfin --network net-a \
    -v /srv/computer-a/portal:/friend-media:rslave \
    jellyfin/jellyfin:latest >/dev/null
  docker run -d --name plex --network net-b \
    -e PUID=1000 -e PGID=1000 -e TZ=America/Chicago \
    -v /srv/computer-b/portal:/friend-media:rslave \
    lscr.io/linuxserver/plex:latest >/dev/null

  j=yes; wait_for 60 docker exec jellyfin cat /friend-media/media/B.txt || j=no
  t "jellyfin container sees B's library" yes "$j"
  t "jellyfin reads B's note" "library of computer B" \
    "$(docker exec jellyfin cat /friend-media/media/B.txt 2>&1)"
  # non-root uid (like PUID users) can read through --allow-other + umask 022
  t "jellyfin non-root uid can read" "library of computer B" \
    "$(docker exec -u 1000:1000 jellyfin cat /friend-media/media/B.txt 2>&1)"

  p=yes; wait_for 60 docker exec plex cat /friend-media/media/A.txt || p=no
  t "plex container sees A's library" yes "$p"
  t "plex reads A's note" "library of computer A" \
    "$(docker exec plex cat /friend-media/media/A.txt 2>&1)"
  t "plex non-root uid can read" "library of computer A" \
    "$(docker exec -u 1000:1000 plex cat /friend-media/media/A.txt 2>&1)"

  ls_out="$(docker exec plex ls /friend-media/media 2>&1)"
  echo "  plex sees: $(echo "$ls_out" | tr '\n' ' ')"

  finish
fi

echo "unknown stage: $STAGE" >&2
exit 2
