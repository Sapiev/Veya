import AppKit
import ObjectiveC

/// AppKit paints table and list selection, and the right-click outline, in the system accent,
/// which SwiftUI's `tint` never reaches; this repaints both in `color`.
@MainActor enum SelectionTint {
    static var color: NSColor? {
        didSet {
            guard color != oldValue else { return }
            for row in drawn.allObjects where row.isSelected { row.needsDisplay = true }
        }
    }

    /// Rows that painted a selection, so a palette change repaints them.
    fileprivate static let drawn = NSHashTable<NSTableRowView>.weakObjects()

    /// Swaps in the repaints once; later calls do nothing.
    static func install() { _ = swapped }

    private static let swapped: Void = {
        swap(NSTableRowView.self, #selector(NSTableRowView.drawSelection(in:)), #selector(NSTableRowView.drawTintedSelection(in:)))
        swap(NSTableView.self, Selector(("drawContextMenuHighlightForRow:")), #selector(NSTableView.drawTintedContextMenuHighlight(forRow:)))
    }()

    private static func swap(_ type: AnyClass, _ original: Selector, _ tinted: Selector) {
        guard let original = class_getInstanceMethod(type, original), let tinted = class_getInstanceMethod(type, tinted) else { return }
        method_exchangeImplementations(original, tinted)
    }

    /// Recolors only the pixels AppKit just drew in `rect`; what lies behind is clear.
    fileprivate static func recolor(_ rect: NSRect) {
        guard let color else { return }
        color.set()
        rect.fill(using: .sourceAtop)
    }
}

extension NSTableRowView {
    /// After the swap this name calls AppKit's own drawing, which sets the selection's shape.
    @objc fileprivate func drawTintedSelection(in dirtyRect: NSRect) {
        drawTintedSelection(in: dirtyRect)
        SelectionTint.drawn.add(self)
        // An unfocused table's gray selection is the platform's, not the accent.
        if isEmphasized { SelectionTint.recolor(bounds) }
    }
}

extension NSTableView {
    /// After the swap this name calls AppKit's own outline around the right-clicked row.
    @objc fileprivate func drawTintedContextMenuHighlight(forRow row: Int) {
        drawTintedContextMenuHighlight(forRow: row)
        if row >= 0 { SelectionTint.recolor(rect(ofRow: row)) }
    }
}
