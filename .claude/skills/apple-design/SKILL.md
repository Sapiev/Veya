---
name: apple-design
description: Apple's approach to interface design and fluid, physical motion, applied to native SwiftUI/AppKit apps on macOS. Use when building or reviewing gesture-driven UI, spring animations (interpolatingSpring, .spring(response:dampingFraction:)), drag/swipe/sheet interactions (DragGesture, NSPanGestureRecognizer), momentum and interruptible transitions, translucent materials and depth (NSVisualEffectView, .ultraThinMaterial), typography (Dynamic Type, tracking, leading), reduced-motion/accessibility, or the design foundations (feedback, spatial consistency, restraint) behind Apple-style interfaces.
---

# Apple Design

How Apple builds interfaces that stop feeling like a computer and start feeling like an extension of you. This knowledge comes from Apple's WWDC design talks — chiefly *Designing Fluid Interfaces* (WWDC 2018) — distilled and applied to native macOS development with SwiftUI and AppKit (`Animation`, gesture recognizers, Core Animation, `NSVisualEffectView`).

The through-line: **an interface feels alive when motion starts from the current on-screen value, inherits the user's velocity, projects momentum forward, and can be grabbed and reversed at any instant.** Springs are the tool that makes all of this natural, because they are inherently interruptible and velocity-aware — and SwiftUI's animation system is built around springs as first-class citizens, more directly than most UI frameworks.

## The Core Idea

> "When we align the interface to the way we think and move, something magical happens — it stops feeling like a computer and starts feeling like a seamless extension of us."

An interface is fluid when it behaves like the physical world: things respond instantly, move continuously, carry momentum, resist at boundaries, and can be redirected mid-motion. Everything below is a way to get closer to that.

Apple frames design as serving four human needs: **safety/predictability, understanding, achievement, and joy.** Every rule here serves one of them.

## 1. Response — kill latency

The moment lag appears, the feeling of directness "falls off a cliff." Response is the foundation everything else is built on.

- **Respond on press-down, not on release.** Highlight a button the instant it's pressed. Waiting for the tap/click to fully commit before showing feedback feels dead.
- **Be vigilant about every latency.** Audit debounces, artificial `Task.sleep`/`DispatchQueue.asyncAfter` delays, Combine `.debounce` operators sitting on the input path, and anything that waits for an animation to finish before accepting the next interaction. Anything non-essential between input and visible response is a regression.
- **Feedback must be continuous *during* the interaction, not just at the end.** For a drag, slider, or drawer, update the UI 1:1 with the pointer/trackpad the whole way through — never animate only when the gesture completes.

`ButtonStyle` is the right lever in SwiftUI: `configuration.isPressed` flips true on press-down, not on release, so driving feedback off it is inherently instant.

```swift
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
```

## 2. Direct manipulation — 1:1 tracking

> "Touch and content should move together."

When the user drags something, it must stay glued to the cursor/finger — and respect the offset from *where they grabbed it*. Snapping to the element's center on grab breaks the illusion immediately.

- `DragGesture`'s `translation` is already relative to the gesture's start point, so adding it to the view's base offset naturally respects the grab offset — don't recenter on the dragged point.
- Track a short **velocity/position history** (timestamped translation samples from `onChanged`), not just the current point — `DragGesture` doesn't expose instantaneous velocity directly, and you'll need it at release for momentum (§5, §6).
- For AppKit views (e.g. a custom `NSView`-based waveform or scrubber), `NSPanGestureRecognizer` or raw `mouseDragged(with:)` play the same role — capture the pointer for the gesture's duration and keep your own position/timestamp history.

```swift
@State private var baseOffset: CGSize = .zero
@State private var dragOffset: CGSize = .zero
@State private var samples: [(time: Date, translation: CGSize)] = []

.gesture(
    DragGesture(minimumDistance: 0)
        .onChanged { value in
            dragOffset = value.translation // respects the grab offset automatically
            samples.append((Date(), value.translation))
            if samples.count > 5 { samples.removeFirst() } // keep a short history for velocity
        }
        .onEnded { value in
            baseOffset.width += value.translation.width
            baseOffset.height += value.translation.height
            dragOffset = .zero
        }
)
```

## 3. Interruptibility — the single most important principle

> "The thought and the gesture happen in parallel."

Every animation must be interruptible and redirectable at any moment. A user must be able to grab a moving element mid-flight and reverse it without waiting for the animation to finish. A closing sheet the user grabs again should follow the cursor — not finish closing first, then reopen.

- **Never lock out input during a transition.** Don't `.disabled(true)` a view, or gate a gesture recognizer, just because an animation is in flight.
- **Always animate from the *presentation* (current) value, never the target value.** SwiftUI does this for you by default for state-driven animations: when `withAnimation` retargets a value that's already mid-animation, the new animation starts from the live, currently-rendered value, not the old target — as long as the change flows through the same `@State`/`@Binding` and an implicit `.animation(_:value:)` or explicit `withAnimation`. Don't fight this by reading stale model values instead of the animatable view state.
- **Avoid fixed-duration `Animation.linear`/`.easeInOut` curves for anything gesture-driven** — they can't be smoothly grabbed and reversed mid-flight the way a spring can. Springs are SwiftUI's native tool for exactly this: `.spring(response:dampingFraction:)` and `Animation.interpolatingSpring(mass:stiffness:damping:initialVelocity:)` both animate from the current value by default.
- **When a gesture reverses, blend velocity — don't hard-cut it.** Replacing one animation with another at a reversal creates a velocity discontinuity, a "brick wall." SwiftUI's `Animatable`-driven spring retargeting carries velocity through when the underlying value changes under animation rather than being snapped and restarted — this is the same thing iOS's *additive animations* do natively in UIKit/Core Animation.
- **2D motion decomposes into independent X and Y springs for free.** When you animate a `CGSize`/`CGPoint`-backed property (e.g. `.offset(x:y:)`) with a single spring, SwiftUI's `Animatable` conformance (`AnimatablePair`) interpolates each component independently — you don't need to hand-roll two springs unless you want deliberately different parameters per axis.

## 4. Behavior over animation — use springs

> "Think of animation as a conversation between you and the object, not something prescribed by the interface."

A pre-scripted, fixed-duration animation can't respond to new input. A spring can — new input just changes the target, and the motion stays continuous. Reach for springs for anything a user can touch.

Apple deliberately replaced the physics triplet (mass/stiffness/damping) with two designer-friendly parameters, and SwiftUI exposes them directly:

- **`dampingFraction`** — controls overshoot. `1.0` = critically damped, no bounce, smooth settle. `< 1.0` = overshoots and oscillates. Lower = bouncier.
- **`response`** — how quickly the value reaches the target, in seconds. Lower = snappier. **This is not "duration"** — a spring has no fixed duration; its settle time emerges from the parameters.

**Defaults:**
- Start most UI at **`dampingFraction: 1.0`** (critically damped) — graceful and non-distracting.
- Add bounce (**`dampingFraction` ~`0.8`**) **only when the gesture itself carried momentum** (a flick, a throw, a drag release). Overshoot on a menu that just faded in feels wrong; overshoot on a card you flicked feels right.

**Concrete values Apple ships:**

| Interaction | Damping | Response |
| --- | --- | --- |
| Move / reposition (e.g. a floating mini-player) | `1.0` | `0.4` |
| Rotation | `0.8` | `0.4` |
| Drawer / sheet (e.g. an expandable now-playing panel) | `0.8` | `0.3` |

**SwiftUI mapping:** `.spring(response:dampingFraction:blendDuration:)` takes Apple's own parameters directly — no translation layer needed. A safe house style is `dampingFraction: 1.0` springs everywhere by default; reserve bounce for momentum-driven, physical interactions.

```swift
// Critically damped default (no overshoot)
withAnimation(.spring(response: 0.4, dampingFraction: 1.0)) {
    position = target
}

// Momentum interaction — a little bounce, only because a flick preceded it
withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
    position = target
}
```

## 5. Velocity handoff — the seam between drag and animation

When a gesture ends, the animation must **continue at the cursor's exact velocity**, so there's no visible seam between dragging and animating. This is the detail that most separates "fluid" from "fine."

`Animation.interpolatingSpring(mass:stiffness:damping:initialVelocity:)` takes the initial velocity as a direct parameter — pass the gesture's release velocity (computed from your tracked position/timestamp history, §2) straight in:

```swift
withAnimation(
    .interpolatingSpring(mass: 1.0, stiffness: 180, damping: 20, initialVelocity: releaseVelocity)
) {
    position = target
}
```

If you're working with a normalized/relative spring API instead, the same ratio Apple uses still applies:

```
relativeVelocity = gestureVelocity / (targetValue − currentValue)
```

Example: view at `y=50`, target `y=150` (100pt to go), cursor moving 50pt/s → relative velocity = `50 / 100 = 0.5`.

## 6. Momentum projection — animate to where the gesture is *going*

> "Take a small input and make a big output."

Don't snap to the nearest boundary from the *release point*. Use velocity to **project the resting position** — exactly like scroll deceleration — then snap to the target nearest that projected point. This is what makes a flick feel like it throws the element.

SwiftUI's `DragGesture.Value` gives you this almost for free: `predictedEndTranslation` / `predictedEndLocation` already apply Apple's own momentum-projection model internally — use them directly to pick the nearest snap point instead of reimplementing the math.

```swift
.gesture(
    DragGesture()
        .onEnded { value in
            let projected = baseOffset.height + value.predictedEndTranslation.height
            let target = nearestSnapPoint(to: projected)
            withAnimation(.interpolatingSpring(mass: 1.0, stiffness: 180, damping: 20,
                                                initialVelocity: velocity(from: value))) {
                offset = target
            }
        }
)
```

For lower-level AppKit work (a custom `NSView` scrubber driven by raw `mouseDragged`/`mouseUp`, where you don't get `predictedEndTranslation`), fall back to Apple's exact projection function from the *Designing Fluid Interfaces* sample code:

```swift
// decelerationRate ≈ 0.998 for normal scroll feel; 0.99 for snappier
func project(initialVelocity: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
    (initialVelocity / 1000) * decelerationRate / (1 - decelerationRate)
}

let projectedEndpoint = currentPosition + project(initialVelocity: releaseVelocity)
let target = nearestSnapPoint(projectedEndpoint)
```

Note: the physics-textbook `v²/(2·decel)` is *not* what Apple ships — use the exponential-decay form above.

## 7. Spatial consistency — symmetric paths, anchored origins

> "If something disappears one way, we expect it to emerge from where it came."

- **Enter and exit along the same path.** A panel that slides in from the right must dismiss to the right. In-from-right / out-the-bottom feels disconnected and confusing. In SwiftUI, prefer a single symmetric `.transition(.move(edge:))` or `.asymmetric(insertion:removal:)` pair that mirrors itself rather than two unrelated transitions.
- **Anchor interactions to their source.** A popover, menu, or expanding panel should originate from the element that triggered it. `matchedGeometryEffect(id:in:)` is the direct SwiftUI tool for this — e.g. a mini-player's album art morphing into the full now-playing view's artwork, sharing one geometry ID across both layouts so the transition reads as the same object growing, not two views cross-fading. `.popover(attachmentAnchor:arrowEdge:)` gives the same anchoring for lighter-weight popovers.
- **Mirror the easing on reversible transitions** so the outbound path matches the return path — use the same spring parameters (response/dampingFraction) for both directions rather than a different curve for open vs. close.

## 8. Hint in the direction of the gesture

Humans predict a final state from a trajectory. Intermediate motion should telegraph where things are going — Control Center modules "grow up and out toward your finger." Make the in-between frames point at the outcome, not just interpolate blindly to it. In practice: bias a custom `GeometryEffect`/`ViewModifier`'s intermediate frames toward the gesture's direction (e.g. a volume knob that stretches slightly toward the drag direction before settling), rather than letting a symmetric spring curve do all the work.

## 9. Rubber-banding — soft boundaries

At an edge, resist progressively instead of stopping hard. A hard stop reads as "frozen"; continuous resistance reads as "responsive, but there's nothing more here." Apply damping that increases the further past the boundary the user drags.

`NSScrollView`'s trackpad bounce already gives this for free in any scrollable content — the manual version below is for custom drag interactions outside a scroll view, like a draggable now-playing sheet that resists past its fully-expanded or fully-collapsed position:

```swift
// The further past the bound, the less the element follows — real things slow before they stop
func rubberBand(overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
    (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
}

.gesture(
    DragGesture()
        .onChanged { value in
            let raw = baseOffset + value.translation.height
            if raw < minOffset {
                offset = minOffset - rubberBand(overshoot: minOffset - raw, dimension: panelHeight)
            } else if raw > maxOffset {
                offset = maxOffset + rubberBand(overshoot: raw - maxOffset, dimension: panelHeight)
            } else {
                offset = raw
            }
        }
)
```

## 10. Gesture design details (the "feel" checklist)

- **Click/tap:** highlight on press-*down* (instant, via `ButtonStyle.isPressed` — §1), commit on release. Add generous hit-target padding around small controls (playback buttons, scrubber handles), and allow cancel-by-dragging-away-and-back.
- **Drag/swipe:** require a small movement threshold before committing to a direction — `DragGesture(minimumDistance: 10)` (SwiftUI's default is `10`), then track 1:1 once committed.
- **Detect all plausible gestures in parallel from the first move**, then confidently cancel the losers once intent is clear. Compose gestures with `.simultaneousGesture`/`.highPriorityGesture`/`.gesture(_:including:)` rather than reaching for a single serialized recognizer. In AppKit, give `NSGestureRecognizer`s explicit `require(toFail:)` relationships only where truly necessary, and prefer recognizers that report continuous state over ones that only fire on a final, discrete event.
- **Minimize disambiguation delays.** Double-click/double-tap detection (`.onTapGesture(count: 2)`, `NSClickGestureRecognizer.numberOfClicksRequired`) unavoidably delays single-click recognition while it waits to see if a second click arrives; only pay that cost where double-click truly has distinct meaning (e.g. double-click to expand an album row) rather than applying it globally.

## 11. Frame-level smoothness

Smoothness is about *what's in the frames*, not just the frame rate.

- Keep the per-frame positional change below the perception threshold to avoid strobing.
- For very fast motion, a subtle **motion blur / stretch** encodes speed and reads better than a hard sharp streak.
- Animate only compositor-friendly, layer-backed properties — `.offset`, `.scaleEffect`, `.rotationEffect`, `.opacity` — rather than properties that force a layout pass on every frame (resizing a view's actual `frame` mid-gesture). For custom per-frame control outside SwiftUI's own animation system, `TimelineView(.animation)` or `CADisplayLink`/`CVDisplayLink` on macOS act as the display-synced clock. Profile with Instruments' **Core Animation** and **SwiftUI** instruments to catch dropped frames and expensive view-body re-evaluations — don't guess from eyeballing it.

## 12. Materials & depth — translucency conveys hierarchy

Apple uses translucent materials as a floating functional layer that brings structure without stealing focus. In SwiftUI, reach for the semantic material styles directly: `.ultraThinMaterial`, `.thinMaterial`, `.regularMaterial`, `.thickMaterial`, `.ultraThickMaterial`. In AppKit, `NSVisualEffectView` is the underlying primitive (`material`, `blendingMode: .behindWindow` / `.withinWindow`, `state: .active`).

- **Build toolbars/sidebars/sheets as translucent layers** — `.background(.regularMaterial)` or an `NSVisualEffectView` with `.sidebar`/`.titlebar` material — with content scrolling underneath, not opaque bars that consume a fixed strip.
- **Material weight encodes hierarchy:** heavier materials (`.thickMaterial`, `.sidebar`) separate structural regions (a library sidebar); lighter materials (`.ultraThinMaterial`) draw attention to floating interactive elements (a mini-player bar, a popover). **Never stack a light translucent surface on another** — legibility collapses.
- **Bigger surfaces should read as thicker:** a full sidebar or sheet wants a heavier material and a deeper shadow than a small chip or badge. Consider context-aware shadow — heavier over busy/text content for separation, lighter over plain backgrounds.
- **Dim to focus, separate to keep flow.** A modal sheet (`.sheet(isPresented:)`) pairs the surface with a dimming scrim behind it. A parallel, non-blocking panel (e.g. a lyrics or queue sidebar next to now-playing) uses translucency and offset *without* a scrim so the flow isn't broken. For stacked sheets, progressively dim and push back each parent layer.
- **Vibrancy keeps text legible over changing backgrounds.** Over a material background, use `.foregroundStyle(.primary)`/`.secondary` (vibrant, adaptive semantic colors) rather than a fixed gray — SwiftUI's vibrancy over materials already boosts contrast automatically. Put saturated accent color on a solid layer, not directly on the translucent foreground text.
- **Scroll edge effects, not hard dividers.** Instead of a 1px border under a sticky toolbar, fade a small blur/gradient mask (`.background(.ultraThinMaterial)` plus a subtle bottom-edge gradient) where content meets floating chrome — only where floating UI actually overlaps content.
- **Materialize, don't just fade.** For glass/blur surfaces, animate blur radius/material thickness and scale together on enter/exit where possible, so the surface reads as a real material arriving rather than a plain opacity fade.

```swift
VStack {
    nowPlayingControls
}
.padding()
.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
```

```swift
// AppKit: a sidebar-style vibrant panel
let effectView = NSVisualEffectView()
effectView.material = .sidebar
effectView.blendingMode = .behindWindow
effectView.state = .active
```

## 13. Multimodal feedback — motion + sound + haptics

Three rules for combining senses (from *Designing Audio-Haptic Experiences*):

1. **Causality** — it must be obvious what caused the feedback. Trigger it on the actual causal event (the toggle flipping, a track snapping to the queue, a volume detent), and match its character to the action's physicality.
2. **Harmony** — the visual, the sound, and the haptic must fire on the **same frame/tick**. Latency between them destroys the illusion — don't let an animation lag behind a sound effect or a haptic pulse.
3. **Utility** — add feedback only where it earns its place. Reserve haptics/sound for meaningful moments (success, error, commit, snap). Over-feedback trains users to ignore all of it.

**macOS note on haptics:** most Macs have no haptic actuator at all — unlike iPhone's Taptic Engine, haptic feedback on macOS is limited to the **Force Touch trackpad**, via `NSHapticFeedbackManager.defaultPerformer.perform(_:performanceTime:)` (e.g. `.generic`, `.alignment`, `.levelChange`). It only fires in response to a trackpad-originated gesture (a force click, a drag crossing a detent) — there's no way to trigger it from an arbitrary app event the way `UIImpactFeedbackGenerator` or SwiftUI's `.sensoryFeedback(_:trigger:)` can on iOS (that modifier isn't available on macOS). Use it sparingly for real detents — e.g. a volume slider crossing 100%, a drag-to-reorder item passing another row — not as a general-purpose UI accent. Sound (`NSSound`) is the more broadly-available feedback channel on macOS; use it with the same restraint.

## 14. Reduced motion & accessibility

Reduced motion doesn't mean *no* feedback — it means a gentler, non-vestibular equivalent. SwiftUI exposes the relevant system settings as environment values; read them and branch your animation/material choices on them:

- **`@Environment(\.accessibilityReduceMotion)`** — replace slides/springs/parallax with short opacity **cross-fades or static transitions**. Drop elastic/overshoot. Keep opacity/color changes that aid comprehension.
- **`@Environment(\.accessibilityReduceTransparency)`** — make translucent surfaces frostier/solid: swap a `.ultraThinMaterial` background for a near-opaque solid color, or step up to `.thickMaterial`.
- **`@Environment(\.accessibilityDifferentiateWithoutColor)`** — don't rely on color alone (e.g. a now-playing row highlighted only by tint); pair it with a shape/weight/icon change.

Also: avoid full-window moving backgrounds, slow looping oscillations (near 0.2 Hz / one cycle per 5s), and abrupt brightness jumps (ease dark↔light appearance changes). Make large moving objects semi-transparent while they travel, and fade big surfaces out during a large reposition and back in once settled.

```swift
struct NowPlayingSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isExpanded = false

    var body: some View {
        content
            .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.ultraThinMaterial))
            .onTapGesture {
                let animation: Animation = reduceMotion
                    ? .easeInOut(duration: 0.2)
                    : .spring(response: 0.4, dampingFraction: 0.8)
                withAnimation(animation) { isExpanded.toggle() }
            }
    }
}
```

## 15. Typography — optical sizing, tracking, leading

Apple designs type to change shape with size; the same discipline applies in a native app. (From *The Details of UI Typography*, WWDC 2020.)

- **Tracking (`.tracking()`) is size-specific — never one value for all sizes.** Large display text (an album title in a full now-playing view) wants *negative* tracking (letters read too far apart as they grow); small text (a track's metadata row) wants tracking near `0` or slightly positive for legibility. A single fixed tracking value applied everywhere is wrong somewhere. Tighten headings, leave body near `0`.
- **Leading (`.lineSpacing()`) tracks size inversely.** Tight on large headings, looser on body copy (e.g. multi-line lyrics or a long playlist description). Increase it for dense paragraph text; tighten it for compact, information-heavy list rows.
- **Build hierarchy from weight + size + leading as a set,** not size alone. Emphasize with `.fontWeight(.semibold)`/`.bold` — it adds presence without taking more horizontal space than bumping size would.
- **Respect Dynamic Type.** Use semantic text styles (`.font(.body)`, `.title2`, `.caption`) rather than fixed point sizes, so the system's text-size setting scales them correctly. Size surrounding layout with `@ScaledMetric` so spacing/padding grows with the text instead of clipping it.
- **Default to the system font** (San Francisco, via `.font(.body)` etc., or `Font.system(.body, design: .default)`) before a custom face — it already ships optical sizing (SF Pro's automatic Text/Display optical variants switch by point size), tracking tables, and legibility tuning. Override only with a reason, and prefer `design: .rounded`/`.serif`/`.monospaced` variants of the system font over a fully custom typeface where the vibe just needs to shift slightly.

```swift
Text("Now Playing")
    .font(.title2.weight(.semibold))
    .tracking(-0.2)       // slightly tightened for a larger heading
    .lineSpacing(2)

Text(trackMetadata)
    .font(.caption)
    .foregroundStyle(.secondary)

@ScaledMetric private var controlSpacing: CGFloat = 12  // grows with Dynamic Type
```

## 16. Design foundations — the eight principles

The motion and craft above serve Apple's eight design principles (*Principles of Great Design*, WWDC 2026). Use these as the names you reason with:

1. **Purpose.** Make with intention; decide what *not* to build. Every feature asks for the user's time, attention, and trust — spend that budget only where it pays off.
2. **Agency.** Keep people in control: offer choices, don't force a single path. Back it with forgiveness — easy undo for slips, a confirmation dialog only for genuinely destructive, irreversible actions (use sparingly; overusing it trains people to click through).
3. **Responsibility.** Act in the user's interest. Privacy: ask at the right moment, only for what's needed, transparently. Safety: anticipate misuse and harm — especially with AI (an allergy-aware recipe app must not suggest a harmful ingredient). Add previews, confirmations, disclaimers; cut a feature whose risk outweighs its value.
4. **Familiarity.** Build on what people already know. Use metaphors that are neither too literal nor too abstract (a trash can means delete), and honor their physics. Be consistent: things that look the same must behave the same and live in the same place (close is always top-left on macOS) so people can predict what happens next. Only break a familiar pattern if you can prove it's better — then test it, don't assume.
5. **Flexibility.** Design for different contexts, devices, and the full range of abilities. Adapt to the platform (iPhone = quick touch; desktop = deep workflows with precise pointer control) and to the situation. Design inclusively (age, language, expertise, accessibility). When no single layout fits everyone, let people personalize — rearrange controls, hide what they don't use.
6. **Simplicity — not minimalism.** Strip the unnecessary so the core purpose shines; burying everything in one place looks minimal but isn't simple. Be concise (plain language, no jargon, fewer steps) and clear (use hierarchy — order, spacing, contrast — so the most important thing is the most obvious). Every element earns its place; sometimes *adding* context simplifies (a video scrubber that shows time remaining). Show the common path first, advanced options one level deeper.
7. **Craft.** Uncompromising attention to detail builds trust. Beautiful typography, colors that adapt to light/dark, clear iconography, and responsive animations that give immediate, natural feedback. Nothing is random — every spacing, timing, and alignment value is a deliberate choice you can defend. Jittery scroll, misaligned icons, and layouts that break on rotation read as carelessness. Craft needs iteration and longevity — keep evolving the design as features and hardware change.
8. **Delight.** The result of getting the other seven right, not confetti tacked on top. Decide the emotion you want people to feel (calm, confident, excited) and reinforce it in every decision.

Tactical rules that serve these:

- **Feedback comes in four kinds:** status, completion, warning, error. Confirm meaningful actions, expose ongoing status, warn before problems, validate inline (not on submit).
- **Wayfinding.** Every screen should answer: Where am I? Where can I go? What's there? How do I get out? Never trap the user.
- **Grouping & mapping.** Proximity implies relationship; place a control near what it affects and arrange controls to mirror what they change. If you need a label to explain a control, the mapping is weak.
- **Direct, specific labels beat safe generic ones.** Name nav items for their contents ("Progress", "Library"), not vague umbrellas ("Home"). Specificity creates predictability.

## 17. Process

- **Prototype interactively — an interactive demo is worth "a million static designs."** You discover the interface by building and playing with it. Xcode Previews with **interactive mode** (the canvas lets you click, drag, and gesture directly against a live view) is the fast loop for this — iterate on spring/gesture feel there before wiring up real data, and let the working prototype set a concrete bar that prevents a mediocre final implementation.
- **Design interaction and visuals together.** "You shouldn't be able to tell where one ends and the other begins." Motion is not a layer added after the pixels — reach for `.spring()` parameters and gesture handling in the same pass as layout, not as a later polish step.
- **Test with real people in real context**, and review motion with fresh eyes. Screen-record the interaction and play it back frame-by-frame, or use Instruments' **Core Animation** instrument to inspect actual frame timing — don't trust how it looks at full speed in the moment you built it.

## Quick Reference

| Need | Technique | Concrete value |
| --- | --- | --- |
| Default UI spring | Critically damped, no overshoot | `.spring(response: 0.3–0.4, dampingFraction: 1.0)` |
| Momentum / flick spring | Under-damped, slight bounce | `.spring(response: 0.3–0.4, dampingFraction: ~0.8)` |
| Gesture → spring velocity | Hand off release velocity | `Animation.interpolatingSpring(initialVelocity:)` |
| Flick landing point | Project momentum | `DragGesture.Value.predictedEndTranslation`, or `current + (v/1000)·d/(1−d)`, `d ≈ 0.998` manually |
| Interrupt cleanly | Start from presentation (live) value | `withAnimation` retargets from the current rendered value automatically |
| Avoid reversal "brick wall" | Carry velocity through re-target | SwiftUI's `Animatable`-driven spring retargeting |
| Reversible transition | Mirror the easing curve | same `response`/`dampingFraction` both directions, or `matchedGeometryEffect` |
| Decide reverse vs. commit | Use velocity **sign**, not position | at gesture end |
| 1:1 drag | `DragGesture` translation | respects the grab offset automatically |
| Feedback | On press-down, continuous | `ButtonStyle.isPressed`, never only on release |
| Boundary | Rubber-band, don't hard-stop | progressive resistance function in `onChanged` |
| Translucent chrome | `.ultraThinMaterial` / `NSVisualEffectView` | content scrolls under |
| Type tracking | Size-specific, never fixed | `.tracking(-0.02em)`-equivalent on large text, body near `0` |
| Reduced motion | Cross-fade, not slide/spring | `@Environment(\.accessibilityReduceMotion)` |
