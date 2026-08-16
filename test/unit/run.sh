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

echo "== fsp_serve_args =="
# Contract: newline-separated argv for `rclone`, serving EXPORT_DIR read-only
# on 127.0.0.1:$FSP_WEBDAV_PORT only.
args="$(EXPORT_DIR=/export FSP_WEBDAV_PORT=8080 fsp_serve_args)"
t "serve argv" \
"serve
webdav
/export
--addr
127.0.0.1:8080
--read-only" \
"$args"

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

echo
echo "unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
