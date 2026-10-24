import AppKit
import ObjectiveC

/// AppKit paints table and list selection, and the right-click outline, in the system accent,
/// which SwiftUI's `tint` never reaches; this repaints both in `color`.
@MainActor enum SelectionTint {
    static var color: NSColor? {
        didSet {
            guard color != oldValue else { return }
            for row in drawn.allObjects where row.isSelected {
                row.needsDisplay = true
            }
            for effect in sourceListSelections.allObjects {
                effect.applyTint()
            }
        }
    }

    /// Rows that painted a selection, so a palette change repaints them.
    fileprivate static let drawn = NSHashTable<NSTableRowView>.weakObjects()
    /// Source lists (the sidebar) paint selection with a `.selection` material view, not `drawSelection`.
    fileprivate static let sourceListSelections = NSHashTable<NSVisualEffectView>.weakObjects()

    /// Swaps in the repaints once; later calls do nothing.
    static func install() {
        _ = swapped
    }

    private static let swapped: Void = {
        swap(NSTableRowView.self, #selector(NSTableRowView.drawSelection(in:)), #selector(NSTableRowView.drawTintedSelection(in:)))
        swap(NSTableView.self, Selector(("drawContextMenuHighlightForRow:")), #selector(NSTableView.drawTintedContextMenuHighlight(forRow:)))
        swap(NSVisualEffectView.self, #selector(NSVisualEffectView.layout), #selector(NSVisualEffectView.layoutTinted))
        swap(NSVisualEffectView.self, #selector(setter: NSVisualEffectView.isEmphasized), #selector(NSVisualEffectView.setTintedEmphasized(_:)))
        // A press can select and emphasize a row without laying out its material view again.
        swap(NSTableRowView.self, #selector(setter: NSTableRowView.isEmphasized), #selector(NSTableRowView.setTintedEmphasized(_:)))
        swap(NSTableRowView.self, #selector(setter: NSTableRowView.isSelected), #selector(NSTableRowView.setTintedSelected(_:)))
    }()

    private static func swap(_ type: AnyClass, _ original: Selector, _ tinted: Selector) {
        guard let originalMethod = class_getInstanceMethod(type, original), let tintedMethod = class_getInstanceMethod(type, tinted) else { return }
        // An inherited method is added to `type` first, so the exchange never reaches the superclass.
        if class_addMethod(type, original, method_getImplementation(tintedMethod), method_getTypeEncoding(tintedMethod)) {
            class_replaceMethod(type, tinted, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod))
        } else {
            method_exchangeImplementations(originalMethod, tintedMethod)
        }
    }

    /// Recolors only the pixels AppKit just drew in `rect`; what lies behind is clear.
    fileprivate static func recolor(_ rect: NSRect) {
        guard let color else { return }
        color.set()
        rect.fill(using: .sourceAtop)
    }
}

private extension NSTableRowView {
    /// After the swap this name calls AppKit's own drawing, which sets the selection's shape.
    @objc func drawTintedSelection(in dirtyRect: NSRect) {
        drawTintedSelection(in: dirtyRect)
        SelectionTint.drawn.add(self)
        // An unfocused table's gray selection is the platform's, not the accent.
        if isEmphasized {
            SelectionTint.recolor(bounds)
        }
    }
}

private extension NSTableRowView {
    @objc func setTintedEmphasized(_ emphasized: Bool) {
        setTintedEmphasized(emphasized)
        tintSelectionMaterial()
    }

    @objc func setTintedSelected(_ selected: Bool) {
        setTintedSelected(selected)
        tintSelectionMaterial()
    }

    private func tintSelectionMaterial() {
        for case let effect as NSVisualEffectView in subviews {
            effect.applyTint()
        }
    }
}

private extension NSTableView {
    /// After the swap this name calls AppKit's own outline around the right-clicked row.
    @objc func drawTintedContextMenuHighlight(forRow row: Int) {
        drawTintedContextMenuHighlight(forRow: row)
        if row >= 0 {
            SelectionTint.recolor(rect(ofRow: row))
        }
    }
}

private extension NSVisualEffectView {
    private static let tintName = "veyaSelectionTint"

    @objc func layoutTinted() {
        layoutTinted()
        applyTint()
    }

    @objc func setTintedEmphasized(_ emphasized: Bool) {
        setTintedEmphasized(emphasized)
        applyTint()
    }

    /// Covers the material with the tint, solid while the list has focus and a wash otherwise: a click or
    /// press on the sidebar never focuses it, so it would only ever show the platform gray.
    /// The material's own mask keeps its rounded shape.
    func applyTint() {
        guard material == .selection, superview is NSTableRowView, let layer else { return }
        SelectionTint.sourceListSelections.add(self)
        let tint = layer.sublayers?.first { $0.name == Self.tintName } ?? {
            let tint = CALayer()
            tint.name = Self.tintName
            layer.addSublayer(tint)
            return tint
        }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = layer.bounds
        tint.cornerRadius = layer.cornerRadius
        let focused = isEmphasized || (superview as? NSTableRowView)?.isEmphasized == true
        tint.backgroundColor = SelectionTint.color?.withAlphaComponent(focused ? 1 : 0.45).cgColor
        tint.isHidden = SelectionTint.color == nil
        tint.zPosition = 1
        CATransaction.commit()
    }
}
