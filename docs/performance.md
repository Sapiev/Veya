# Performance

Veya's reason to exist next to the official desktop app is being light. PBI-803 sets the budget, CI enforces it, and this page covers measuring and profiling.

## Budget

| Measure | Budget | Test |
| --- | --- | --- |
| Cold launch, process start to first frame | < 1 s | `testColdLaunch` |
| Idle memory (physical footprint) | < 120 MB | `testIdle` |
| Memory during playback | < 200 MB | `testPlayback` |
| CPU during playback, % of one core | < 3 % | `testPlayback` |

The budget targets an M1 Mac running the Release build. "Memory" is the physical footprint, the figure Activity Monitor's Memory column shows.

## How CI enforces it

`VeyaUITests/PerformanceUITests` records XCTest metrics: `XCTApplicationLaunchMetric` (median of 5 launches), `XCTMemoryMetric` (peak physical) and `XCTCPUMetric` over a 10 s window. A test cannot read its own measurements, so `scripts/check-performance-budget.sh` reads them from the result bundle and fails over budget, or when a metric is missing.

The CI `UI tests` step writes the bundle and the `Performance budget` step checks it. Locally:

```sh
xcodebuild test -project Veya.xcodeproj -scheme Veya -destination 'platform=macOS' \
  -only-testing:VeyaUITests/PerformanceUITests -resultBundlePath /tmp/perf.xcresult
scripts/check-performance-budget.sh /tmp/perf.xcresult
```

Known limits:

- The tests run the Debug build against the UI test scenario fakes (they are compiled out of Release). They measure the app's own UI and model cost, not librespot fetching and decoding audio. Check real playback by hand with the templates below.
- `testPlayback` plays from Liked Songs, so the scrubber, the track list row and the sidebar all show playback.
- The tests wait 5 s before measuring. AppKit writes a window snapshot for state restoration a few seconds after launch or navigation, about 0.25 s of CPU, which is not steady state.
- `XCTApplicationLaunchMetric(waitUntilResponsive: true)` records nothing on macOS, so launch is measured to the first frame.

Measured on an M4, Debug, October 2026: launch 0.50 to 0.66 s, idle 54 to 57 MB, playback 67 to 88 MB at 0.5 to 0.6 % CPU.

## Keeping playback cheap

A running SwiftUI `TimelineView` keeps the display link firing every frame, whatever its schedule (`.periodic` and `.animation(minimumInterval:)` included). It cost about 9 % CPU for the scrubber and 13 % for the equalizer bars. Instead:

- Tick with a sleeping `.task`, as `Scrubber` and the menu bar marquee do. Each scrubber tick relays out the window, so it wakes once a second, when the elapsed time turns over.
- Run continuous animations in Core Animation, as `Equalizer` does: the render server animates the layers with no per-frame work in the app.

## Profiling with Instruments

Profile the Release build (Product > Profile in Xcode, or `xcodebuild -configuration Release`) signed in to a real account, so librespot is part of the picture. Each template also runs from the command line with `xcrun xctrace record`; open the `.trace` in Instruments.

### Time Profiler: CPU

Where CPU time goes, for launch or playback.

```sh
xcrun xctrace record --template 'Time Profiler' --attach Veya --time-limit 15s --output veya-cpu.trace
```

Start playback, then record. Use the call tree with "Hide System Libraries" off: most of a SwiftUI app's cost sits under `NSHostingView.layout` and `CA::Transaction::commit`, and the app frames above them show which view triggered it. Many short bursts at frame rate point to an animation or a `TimelineView`.

For launch, use the App Launch template with `--launch -- /path/to/Veya.app`.

### Allocations: memory

Footprint growth and what holds it.

```sh
xcrun xctrace record --template 'Allocations' --launch -- /path/to/Veya.app --time-limit 60s --output veya-memory.trace
```

Browse a few large playlists, then return to Home. Use "Mark Generation" before and after: memory that survives a generation is retained. Artwork is the usual suspect. The Leaks template finds cycles.

### Activity Monitor: energy

Instruments' Power Profiler is iOS-only. On macOS, energy follows CPU time and wake-ups, which the Activity Monitor template records for every process:

```sh
xcrun xctrace record --template 'Activity Monitor' --all-processes --time-limit 60s --output veya-energy.trace
```

Check Veya's % CPU, Idle Wake Ups and App Nap columns during playback and while idle in the background. Idle wake-ups in the hundreds per second mean something polls or animates offscreen. The Energy tab of the Activity Monitor app shows the resulting Energy Impact, and it is the easiest side-by-side check against the official app.

## Comparing with the official app

For the README comparison, measure both apps the same way on the same Mac: Release Veya and the Spotify desktop app, both signed in, each playing the same playlist for a minute, then idle for a minute in the background. Record with the Activity Monitor template above and read Memory, % CPU and Idle Wake Ups for each process (Spotify runs several helper processes, so add them up). For launch, time each app's cold launch after a reboot with the App Launch template.
