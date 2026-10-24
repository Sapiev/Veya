@testable import SpotCoreKit
import Testing

struct ReachabilityTransitionsTests {
    @Test func reportsChangesOnlyAfterTheFirstReading() {
        var transitions = ReachabilityTransitions()

        let reported = [true, true, false, false, true, false].map { transitions.update($0) }

        #expect(reported == [nil, nil, false, nil, true, false])
    }

    @Test func firstReadingOfflineIsNotReported() {
        var transitions = ReachabilityTransitions()

        #expect(transitions.update(false) == nil)
        #expect(transitions.update(true) == true)
    }
}
