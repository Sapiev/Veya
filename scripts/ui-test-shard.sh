#!/bin/sh
# Prints the -only-testing arguments for one CI shard of VeyaUITests.
# Usage: scripts/ui-test-shard.sh perf | <shard 1..N> <N>
# Every *UITests class lands in exactly one shard (greedy by test count, deterministic), so a new
# class is picked up without editing CI. PerformanceUITests measures launch time and memory, so it
# gets a machine to itself and never shares one with other tests.
set -eu
cd "$(dirname "$0")/../VeyaUITests"
if [ "$1" = perf ]; then
    echo "-only-testing:VeyaUITests/PerformanceUITests"
    exit
fi
grep -c 'func test' *UITests.swift | grep -v '^PerformanceUITests' | sed 's/\.swift:/ /' |
    sort -k2,2nr -k1,1 |
    awk -v shard="$1" -v n="$2" '
        { best = 1; for (i = 2; i <= n; i++) if (load[i] < load[best]) best = i
          load[best] += $2; if (best == shard) printf "-only-testing:VeyaUITests/%s\n", $1 }'
