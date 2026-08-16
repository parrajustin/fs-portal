#!/usr/bin/env bash
# Run the whole fs-portal test pyramid: unit -> integration -> e2e.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "########## unit ##########"
bash -n "$HERE/scripts/lib.sh" && bash -n "$HERE/scripts/entrypoint.sh" && bash -n "$HERE/scripts/healthcheck.sh" || exit 1
"$HERE/test/unit/run.sh" || exit 1

echo "########## integration ##########"
"$HERE/test/integration/run.sh" || exit 1

echo "########## e2e ##########"
"$HERE/test/e2e/run.sh" || exit 1

echo "ALL TEST SUITES PASSED"
