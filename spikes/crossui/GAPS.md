# swift-cross-ui 0.10.0 spike gaps (PBI-X03)

Built and launched on macOS (AppKitBackend, debug build, Swift 6.4). Linux/Windows not run; "untested" unless a source is cited.
Source for API claims: swift-cross-ui v0.10.0 sources (`Sources/SwiftCrossUI/Views`, `Sources/AppKitBackend`), README backend list.
No screenshots taken yet (no UI-test harness in this spike); the window was only confirmed alive for 6 s.

| Item | macOS (AppKit) | Linux (GTK4) | Windows (WinUI) | Verdict | Evidence |
|---|---|---|---|---|---|
| Virtualized 10k list | `List` with 10_000 rows builds and the app stays alive. AppKitBackend exposes the list as an `NSTableView` (`InspectionModifiers.swift`), so row virtualization is likely but NOT measured. Debug-build RSS about 890 MB after 6 s idle, which is suspiciously high. No `LazyVStack`/`LazyVGrid` exists. | untested | untested | unproven, needs measurement (scroll fps, RSS in release) | `ps` RSS on run; source grep for `LazyVStack` returned nothing |
| Image loading | Only `Image(URL)` (png/jpg/webp, file URL) and `Image(ImageFormats.Image<RGBA>)`. No async/remote image view, no cache. Not exercised; artwork is a colored `RoundedRectangle`. | untested | untested | workaround (download + decode in model layer, pass RGBA) | `Views/Image.swift` |
| Slider | `Slider(value:in:)` x2 (seek, volume) compile and render. Drag behavior not exercised. | untested | untested | works (macOS compile/launch only) | `swift build` ok, process alive |
| Context menu | No `contextMenu` modifier in 0.10.0. `Menu("...") { Button... }` per row is the closest, a visible button, not right-click. | untested | untested | upstream PR (or per-backend NSMenu via inspection hook) | grep for `contextMenu` finds only `Backend/BackendFeatures/Menus.swift` (window menus) |
| Translucent sidebar | `NavigationSplitView` sidebar is an opaque `SplitView`; no vibrancy/material API found. | untested | untested | blocker for macOS parity; upstream PR or AppKitBackend inspection hook | no `NSVisualEffectView` in `Sources/AppKitBackend` |
| Keyboard focus | `focusable()`, `focused(_:)` modifiers exist. Not exercised. | untested | untested | untested | `Views/Modifiers/FocusableModifier.swift`, `FocusedModifier.swift` |
| Text scaling | Not exercised. Fonts are `.font(.title)` style based; no Dynamic Type equivalent verified. | untested | untested | untested | n/a |
| Dark/light | Not toggled during run. Colors used are system defaults; no explicit appearance handling written. | untested | untested | untested | n/a |

## API surprises

- Repo moved to `github.com/moreSwift/swift-cross-ui` (stackotter URL redirects); package uses `exact: "0.10.0"`.
- `List(data, selection:)` requires `Identifiable` with `ID == SelectionValue` and `Int` index (arrays only).
- Swift 6.4 emits a warning per scene for implicit `AppKitBackend` import (error in Swift 6 mode); build still succeeds.
- First `swift build` resolves about 24 transitive checkouts (Android/Java packages) and takes several minutes; build proper was 32 s.

## Linux GTK4 prerequisites (from upstream CI/Package.swift)

`sudo apt install -y libgtk-4-dev clang` (Package.swift `.apt(["libgtk-4-dev clang"])`; CI also installs `libgtk-3-dev`, `xvfb`, `x11-xserver-utils` for tests). Build with `SCUI_DEFAULT_BACKEND=GtkBackend swift build`. GTK4 not installed locally (`brew list gtk4` fails), so the GTK build was skipped.
