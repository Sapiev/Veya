#!/bin/sh
# Fails when a PerformanceUITests metric is over the PBI-803 budget, or missing.
# Usage: scripts/check-performance-budget.sh <result bundle>, from `xcodebuild test -resultBundlePath`.
set -eu
exec python3 - "$1" <<'EOF'
import json, statistics, subprocess, sys

MB = 1024  # memory metrics are in kB

# (test, metric display name prefix, budget, unit)
BUDGETS = [
    ("testColdLaunch", "Duration (ApplicationLaunch)", 1, "s"),
    ("testIdle", "Memory Peak Physical", 120 * MB, "kB"),
    ("testPlayback", "Memory Peak Physical", 200 * MB, "kB"),
    ("testPlayback", "CPU", 3, "%"),
]

metrics = {}
report = subprocess.run(
    ["xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", sys.argv[1]],
    check=True, capture_output=True, text=True,
).stdout
for test in json.loads(report):
    name = test["testIdentifier"].removeprefix("PerformanceUITests/").removesuffix("()")
    for run in test["testRuns"]:
        for metric in run["metrics"]:
            values = metric["measurements"]
            # Median: a launch measures 0.7 s typically and 1.5 s on a runner hiccup; one outlier must not fail the budget.
            metrics[name, metric["displayName"]] = statistics.median(values)

def value(test, prefix):
    if prefix == "CPU":
        return 100 * value(test, "CPU Time") / value(test, "Clock Monotonic Time")
    matches = [v for (t, name), v in metrics.items() if t == test and name.startswith(prefix)]
    if len(matches) != 1:
        sys.exit(f"{test}: expected one '{prefix}' metric, found {len(matches)}")
    return matches[0]

over = False
for test, prefix, budget, unit in BUDGETS:
    measured = value(test, prefix)
    ok = measured < budget
    over |= not ok
    print(f"{'ok  ' if ok else 'OVER'} {test} {prefix}: {measured:.2f} {unit} (budget {budget} {unit})")
sys.exit(1 if over else 0)
EOF
