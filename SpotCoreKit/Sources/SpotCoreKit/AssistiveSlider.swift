/// Assistive increments and value sets arrive without an editing session;
/// each one becomes a complete edit so seeks are not left pending.
public enum AssistiveSlider {
    public static func set(
        _ value: Double,
        editing: Bool,
        apply: (Double) -> Void,
        onEditingChanged: (Bool) -> Void
    ) {
        guard !editing else { return apply(value) }
        onEditingChanged(true)
        apply(value)
        onEditingChanged(false)
    }
}
