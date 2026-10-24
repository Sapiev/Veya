import SpotCoreKit
import Testing

struct AssistiveSliderTests {
    private final class Log {
        var events: [String] = []
    }

    private func record(_ value: Double, editing: Bool) -> [String] {
        let log = Log()
        AssistiveSlider.set(
            value, editing: editing,
            apply: { log.events.append("set \($0)") },
            onEditingChanged: { log.events.append($0 ? "begin" : "end") }
        )
        return log.events
    }

    @Test func aChangeOutsideAnEditBecomesACompleteEdit() {
        #expect(record(42, editing: false) == ["begin", "set 42.0", "end"])
    }

    @Test func aChangeInsideAnEditOnlySetsTheValue() {
        #expect(record(42, editing: true) == ["set 42.0"])
    }
}
