#!/usr/bin/env bash
# Unit tests for scripts/lib.sh — pure functions only, no docker needed.
# Usage: test/unit/run.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

PASS=0
FAIL=0

t() { # t <name> <expected> <actual>
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  ok   $name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $name"
    echo "       expected: $(printf '%q' "$expected")"
    echo "       actual:   $(printf '%q' "$actual")"
  fi
}

t_rc() { # t_rc <name> <expected-rc> <actual-rc>
  t "$name_prefix$1 (rc)" "$2" "$3"
}

if [[ ! -f "$ROOT/scripts/lib.sh" ]]; then
  echo "FATAL: $ROOT/scripts/lib.sh does not exist" >&2
  exit 1
fi
# shellcheck source=../../scripts/lib.sh
source "$ROOT/scripts/lib.sh"

name_prefix=""

echo "== fsp_parse_ticket =="
# Real-world shape of dumbpipe listen-tcp output: ticket is a long base32
# token in a "connect-tcp" hint line, surrounded by other log noise.
SAMPLE_OUT=$'using secret key 6d24...\nListening on TCP 127.0.0.1:8080\nTo connect, use e.g.:\ndumbpipe connect-tcp nodeealvvv4nwa522qhznqrblv6jxcrgnvpapvakxw5i6mwltmm6ps2r4aicamaakdu5wtjasadei2qdfuqjadakqk3t2ieq\nforwarding incoming requests'
t "extracts ticket token" \
  "nodeealvvv4nwa522qhznqrblv6jxcrgnvpapvakxw5i6mwltmm6ps2r4aicamaakdu5wtjasadei2qdfuqjadakqk3t2ieq" \
  "$(printf '%s\n' "$SAMPLE_OUT" | fsp_parse_ticket)"

t "empty input yields nothing" "" "$(printf 'no ticket here\n' | fsp_parse_ticket)"

t "ignores short base32-ish words" "" \
  "$(printf 'listen tcp abcdefg 127.0.0.1:8080\n' | fsp_parse_ticket)"

# Longest candidate wins (secret hex line must not be mistaken for a ticket:
# hex contains chars outside base32 alphabet like 0,1,8,9 → rejected).
t "rejects hex secret lines" "" \
  "$(printf 'using secret key 0f9b81d2c4a6e5f30f9b81d2c4a6e5f30f9b81d2c4a6e5f30f9b81d2c4a6e5f3\n' | fsp_parse_ticket)"

echo "== fsp_is_valid_secret =="
fsp_is_valid_secret "$(printf 'a%.0s' {1..64})"; t "64 hex chars ok" 0 $?
fsp_is_valid_secret "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; t "mixed hex ok" 0 $?
fsp_is_valid_secret "xyz"; t "short garbage rejected" 1 $?
fsp_is_valid_secret ""; t "empty rejected" 1 $?
fsp_is_valid_secret "$(printf 'g%.0s' {1..64})"; t "non-hex rejected" 1 $?
fsp_is_valid_secret "$(printf 'a%.0s' {1..63})"; t "63 chars rejected" 1 $?

echo "== fsp_gen_secret =="
S1="$(fsp_gen_secret)"
S2="$(fsp_gen_secret)"
fsp_is_valid_secret "$S1"; t "generated secret is valid" 0 $?
t "two generations differ" "different" "$([[ "$S1" == "$S2" ]] && echo same || echo different)"

echo "== fsp_roles =="
t "default roles" "export import" "$(fsp_roles "")"
t "export only" "export" "$(fsp_roles "export")"
t "import only" "import" "$(fsp_roles "import")"
t "both, comma" "export import" "$(fsp_roles "export,import")"
t "both, reversed input normalizes" "export import" "$(fsp_roles "import,export")"
t "whitespace tolerated" "export import" "$(fsp_roles " export , import ")"
fsp_roles "bogus" >/dev/null 2>&1; t "invalid role rejected (rc)" 1 $?
fsp_roles "export,bogus" >/dev/null 2>&1; t "mixed invalid rejected (rc)" 1 $?
# friendly aliases: transmitter=export, receiver=import, both=export+import
t "transmitter alias" "export" "$(fsp_roles "transmitter")"
t "receiver alias" "import" "$(fsp_roles "receiver")"
t "both alias" "export import" "$(fsp_roles "both")"
t "mixed alias and role" "export import" "$(fsp_roles "transmitter,import")"
t "aliases are case-insensitive" "export import" "$(fsp_roles "Both")"
t "receiver+transmitter normalizes" "export import" "$(fsp_roles "receiver,transmitter")"

echo "== fsp_max_streams =="
t "empty defaults to 5" "5" "$(fsp_max_streams "")"
t "unset-style whitespace defaults to 5" "5" "$(fsp_max_streams "  ")"
t "explicit value passes through" "12" "$(fsp_max_streams "12")"
t "zero disables the cap" "0" "$(fsp_max_streams "0")"
t "leading zeros normalized" "7" "$(fsp_max_streams "007")"
t "surrounding whitespace tolerated" "3" "$(fsp_max_streams " 3 ")"
fsp_max_streams "five" >/dev/null 2>&1; t "words rejected (rc)" 1 $?
fsp_max_streams "-1" >/dev/null 2>&1; t "negative rejected (rc)" 1 $?
fsp_max_streams "3.5" >/dev/null 2>&1; t "fraction rejected (rc)" 1 $?

echo "== fsp_procs =="
t "empty defaults to 1" "1" "$(fsp_procs "")"
t "whitespace defaults to 1" "1" "$(fsp_procs "  ")"
t "explicit value passes through" "4" "$(fsp_procs "4")"
t "leading zeros normalized" "8" "$(fsp_procs "008")"
t "surrounding whitespace tolerated" "3" "$(fsp_procs " 3 ")"
t "upper bound accepted" "64" "$(fsp_procs "64")"
fsp_procs "0" >/dev/null 2>&1; t "zero rejected (rc)" 1 $?
fsp_procs "65" >/dev/null 2>&1; t "above 64 rejected (rc)" 1 $?
fsp_procs "-2" >/dev/null 2>&1; t "negative rejected (rc)" 1 $?
fsp_procs "two" >/dev/null 2>&1; t "words rejected (rc)" 1 $?
fsp_procs "2.5" >/dev/null 2>&1; t "fraction rejected (rc)" 1 $?

echo "== fsp_import_conf =="
# Contract: one webdav remote per tunnel process on consecutive ports from
# FSP_IMPORT_PORT, unioned as "portal:" with search_policy=rand so each file
# open picks a random tunnel (that is the load distribution).
conf="$(FSP_IMPORT_PORT=8081 fsp_import_conf 2)"
t "import conf for 2 procs" \
"[dp1]
type = webdav
url = http://127.0.0.1:8081
vendor = other

[dp2]
type = webdav
url = http://127.0.0.1:8082
vendor = other

[portal]
type = union
upstreams = dp1: dp2:
search_policy = rand" \
"$conf"
conf="$(FSP_IMPORT_PORT=9000 fsp_import_conf 3)"
t "import conf honors port base" "yes" "$(printf '%s\n' "$conf" | grep -qx 'url = http://127.0.0.1:9002' && echo yes)"
t "import conf unions all procs" "yes" "$(printf '%s\n' "$conf" | grep -qx 'upstreams = dp1: dp2: dp3:' && echo yes)"

echo "== fsp_bwlimit =="
t "empty defaults to off" "off" "$(fsp_bwlimit "")"
t "whitespace defaults to off" "off" "$(fsp_bwlimit "  ")"
t "off normalizes case" "off" "$(fsp_bwlimit "OFF")"
t "single rate passes through" "10M" "$(fsp_bwlimit "10M")"
t "surrounding whitespace trimmed" "10M" "$(fsp_bwlimit " 10M ")"
t "lowercase suffix ok" "512k" "$(fsp_bwlimit "512k")"
t "bare number ok (KiB/s)" "100" "$(fsp_bwlimit "100")"
t "fractional rate ok" "1.5M" "$(fsp_bwlimit "1.5M")"
t "full unit suffix ok" "10MiB" "$(fsp_bwlimit "10MiB")"
t "upload:download pair ok" "10M:100k" "$(fsp_bwlimit "10M:100k")"
t "pair with off side ok" "10M:off" "$(fsp_bwlimit "10M:off")"
t "timetable passed through" "08:00,512k 12:00,10M" "$(fsp_bwlimit "08:00,512k 12:00,10M")"
fsp_bwlimit "fast" >/dev/null 2>&1; t "words rejected (rc)" 1 $?
fsp_bwlimit "10Q" >/dev/null 2>&1; t "bogus suffix rejected (rc)" 1 $?
fsp_bwlimit "10M:" >/dev/null 2>&1; t "dangling pair rejected (rc)" 1 $?
fsp_bwlimit "10 M" >/dev/null 2>&1; t "inner space rejected (rc)" 1 $?

echo "== fsp_serve_args =="
# Contract: newline-separated argv for `rclone`, serving EXPORT_DIR read-only
# on 127.0.0.1:$FSP_WEBDAV_PORT only. FSP_METRICS=0 disables the metrics
# endpoint; request logging is always on at FSP_RCLONE_LOG_LEVEL.
args="$(EXPORT_DIR=/export FSP_WEBDAV_PORT=8080 FSP_METRICS=0 fsp_serve_args)"
t "serve argv (metrics off)" \
"serve
webdav
/export
--addr
127.0.0.1:8080
--read-only
--log-level=INFO" \
"$args"

args="$(EXPORT_DIR=/export fsp_serve_args)"
t "serve metrics on by default" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--metrics-addr=0.0.0.0:9101' && echo yes)"
args="$(EXPORT_DIR=/export FSP_SERVE_METRICS_PORT=19101 fsp_serve_args)"
t "serve metrics port override" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--metrics-addr=0.0.0.0:19101' && echo yes)"
args="$(EXPORT_DIR=/export FSP_RCLONE_LOG_LEVEL=DEBUG fsp_serve_args)"
t "serve log level override" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--log-level=DEBUG' && echo yes)"
args="$(EXPORT_DIR=/export FSP_WEBDAV_PORT=8080 FSP_BWLIMIT=10M fsp_serve_args)"
t "serve argv gains bwlimit when set" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--bwlimit=10M' && echo yes)"
args="$(EXPORT_DIR=/export FSP_WEBDAV_PORT=8080 FSP_BWLIMIT=off fsp_serve_args)"
t "serve argv omits bwlimit when off" "" "$(printf '%s\n' "$args" | grep -- '--bwlimit')"

echo "== fsp_mount_args =="
# Contract: mounts the webdav remote (proxied peer) at $1, read-only,
# allow-other so sibling-container uids can read, full vfs cache for media.
args="$(FSP_IMPORT_PORT=8081 FSP_CACHE_DIR=/cache fsp_mount_args /portal/media)"
t "mount argv contains mount+target" "yes" \
  "$(printf '%s\n' "$args" | head -2 | tr '\n' ' ' | grep -q '^mount :webdav: ' && echo yes)"
t "mount argv read-only" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--read-only' && echo yes)"
t "mount argv allow-other" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--allow-other' && echo yes)"
t "mount argv vfs cache" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--vfs-cache-mode=full' && echo yes)"
t "mount argv target" "yes" "$(printf '%s\n' "$args" | grep -qx -- '/portal/media' && echo yes)"
t "mount argv points at import port" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--webdav-url=http://127.0.0.1:8081' && echo yes)"
t "mount argv omits bwlimit by default" "" "$(printf '%s\n' "$args" | grep -- '--bwlimit')"
args="$(FSP_IMPORT_PORT=8081 FSP_CACHE_DIR=/cache FSP_BWLIMIT=10M fsp_mount_args /portal/media)"
t "mount argv gains bwlimit when set" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--bwlimit=10M' && echo yes)"

echo "== fsp_mount_args multi-process (FSP_PROCS > 1) =="
# Contract: instead of the single :webdav: remote, mount the "portal:" union
# remote (config from fsp_import_conf) so reads spread across the tunnels.
# Everything else (read-only, allow-other, vfs cache, metrics) is unchanged.
args="$(FSP_PROCS=3 FSP_IMPORT_CONF=/tmp/fsp.conf fsp_mount_args /portal/media)"
t "multi mount argv mounts union remote" "yes" \
  "$(printf '%s\n' "$args" | head -2 | tr '\n' ' ' | grep -q '^mount portal: ' && echo yes)"
t "multi mount argv carries the generated config" "yes" \
  "$(printf '%s\n' "$args" | grep -qx -- '--config=/tmp/fsp.conf' && echo yes)"
t "multi mount argv drops webdav-url" "" "$(printf '%s\n' "$args" | grep -- '--webdav-url')"
t "multi mount argv still read-only" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--read-only' && echo yes)"
t "multi mount argv still allow-other" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--allow-other' && echo yes)"
t "multi mount argv still vfs cache" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--vfs-cache-mode=full' && echo yes)"
args_single="$(fsp_mount_args /portal/media)"
args_one="$(FSP_PROCS=1 fsp_mount_args /portal/media)"
t "FSP_PROCS=1 is identical to default" "$args_single" "$args_one"
FSP_PROCS=nope fsp_mount_args /portal/media >/dev/null 2>&1; t "invalid FSP_PROCS rejected (rc)" 1 $?

echo "== fsp_mount_args observability =="
# Metrics endpoint on 9102 (togglable), INFO logs, and periodic one-line
# transfer stats so speeds show up in `docker logs`.
args="$(fsp_mount_args /portal/media)"
t "mount metrics on by default" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--metrics-addr=0.0.0.0:9102' && echo yes)"
t "mount log level default INFO" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--log-level=INFO' && echo yes)"
t "mount periodic stats" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--stats=60s' && echo yes)"
t "mount stats one-line" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--stats-one-line' && echo yes)"
args="$(FSP_METRICS=0 fsp_mount_args /portal/media)"
t "mount metrics disabled by FSP_METRICS=0" "yes" "$(printf '%s\n' "$args" | grep -q -- '--metrics-addr' && echo no || echo yes)"
args="$(FSP_MOUNT_METRICS_PORT=19102 fsp_mount_args /portal/media)"
t "mount metrics port override" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--metrics-addr=0.0.0.0:19102' && echo yes)"
args="$(FSP_STATS_INTERVAL=30s fsp_mount_args /portal/media)"
t "mount stats interval override" "yes" "$(printf '%s\n' "$args" | grep -qx -- '--stats=30s' && echo yes)"

echo
echo "unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
