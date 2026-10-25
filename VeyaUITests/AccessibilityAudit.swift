import AppKit
import XCTest

/// PBI-801: Apple's accessibility audit plus a text contrast check measured on the screen itself.
@MainActor
extension XCTestCase {
    /// Lists every issue at once instead of stopping at the first.
    func assertAuditPasses(_ app: XCUIApplication, _ screen: String, line: UInt = #line) throws {
        // A tooltip under the pointer is a window of its own with no description; park the pointer on the menu bar.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.width / 2, dy: 10 - window.frame.minY)).hover()
        var issues: [String] = []
        // Contrast is measured from the screen below instead. On Veya's translucent panels the audit flags
        // text that draws at 5.6-9.5:1 and whose accessibility color is opaque, so its verdict tracks neither.
        try app.performAccessibilityAudit(for: XCUIAccessibilityAuditType.all.subtracting(.contrast)) { issue in
            guard let element = issue.element else {
                // False positive: views under a `.isModal` overlay (Now Playing) leave the hosting view's children,
                // but their AppKit-backed scroll views still claim it as parent; XCTest cannot resolve them.
                if issue.auditType == .parentChild {
                    return true
                }
                issues.append("\(issue.compactDescription): \(issue.detailedDescription)")
                return true
            }
            // False positive: AppKit's empty function-row element at the menu bar, which Veya does not draw.
            if element.elementType == .touchBar {
                return true
            }
            // False positive: AppKit's slider knob; VoiceOver reads the slider's own label and value.
            if issue.auditType == .sufficientElementDescription, element.elementType == .valueIndicator {
                return true
            }
            // False positive: SwiftUI's menu Picker opens from VoiceOver and the keyboard but reports no press action.
            if issue.auditType == .action, element.elementType == .popUpButton {
                return true
            }
            let name = "\(element.elementType.rawValue) '\(element.label)' #\(element.identifier) \(element.frame)"
            issues.append("\(issue.compactDescription): \(name)")
            return true
        }
        issues += try lowContrastTexts(in: app)
        if !issues.isEmpty {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = screen
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertEqual(issues, [], "\(screen) audit", line: line)
    }

    /// Every visible static text whose drawn contrast is under WCAG AA: 4.5:1, or 3:1 for large text.
    private func lowContrastTexts(in app: XCUIApplication) throws -> [String] {
        let shot = XCUIScreen.main.screenshot()
        let pixels = try XCTUnwrap(ScreenPixels(shot))
        var found: [String] = []
        func visit(_ node: XCUIElementSnapshot, clip: CGRect, covered: [CGRect]) {
            let clips = [.window, .scrollView, .outline, .table].contains(node.elementType)
            let clip = clips ? clip.intersection(node.frame) : clip
            let text = (node.value as? String) ?? node.label
            if node.elementType == .staticText, !text.trimmingCharacters(in: .whitespaces).isEmpty,
               clip.insetBy(dx: -1, dy: -1).contains(node.frame), node.frame.width >= 4, node.frame.height >= 4,
               !covered.contains(where: { $0.intersects(node.frame) })
            {
                let ratio = pixels.contrast(in: node.frame)
                // About 18 pt type and up is large text in WCAG.
                let minimum = node.frame.height >= 22 ? 3.0 : 4.5
                if ratio < minimum {
                    found.append(String(format: "Contrast %.1f:1 for '%@' %@", ratio, text, "\(node.frame)"))
                }
            }
            node.children.forEach { visit($0, clip: clip, covered: covered) }
        }
        // The app lists its windows front to back; text under a window in front draws that window's pixels.
        let windows = try app.snapshot().children
        for (index, window) in windows.enumerated() {
            visit(window, clip: .infinite, covered: windows.prefix(index).filter { $0.elementType == .window }.map(\.frame))
        }
        return found
    }
}

/// A screenshot's pixels, addressed in screen points.
struct ScreenPixels {
    let rep: NSBitmapImageRep
    let scale: CGFloat

    init?(_ shot: XCUIScreenshot) {
        // XCUIScreen.main is the screen with the menu bar, NSScreen.screens.first.
        guard let rep = NSBitmapImageRep(data: shot.pngRepresentation), let screen = NSScreen.screens.first else {
            return nil
        }
        self.rep = rep
        scale = CGFloat(rep.pixelsWide) / screen.frame.width
    }

    /// The background is the median luminance in `frame`; the text is whichever extreme lies furthest from it.
    func contrast(in frame: CGRect) -> Double {
        var values: [Double] = []
        for column in Int(frame.minX * scale) ..< Int(frame.maxX * scale) {
            for row in Int(frame.minY * scale) ..< Int(frame.maxY * scale) {
                if let color = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) {
                    values.append(luminance(color))
                }
            }
        }
        guard values.count > 10 else { return .infinity }
        values.sort()
        let background = values[values.count / 2]
        let dark = values[values.count / 100], light = values[values.count - 1 - values.count / 100]
        func ratio(_ one: Double, _ other: Double) -> Double {
            (max(one, other) + 0.05) / (min(one, other) + 0.05)
        }
        return max(ratio(background, dark), ratio(background, light))
    }

    private func luminance(_ color: NSColor) -> Double {
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let red = linear(color.redComponent), green = linear(color.greenComponent), blue = linear(color.blueComponent)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}
