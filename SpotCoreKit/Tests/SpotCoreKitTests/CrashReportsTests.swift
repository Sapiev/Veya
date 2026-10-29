import Foundation
@testable import SpotCoreKit
import Testing

@MainActor
struct CrashReportsTests {
    private let defaults: UserDefaults
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "CrashReportsTests-\(UUID().uuidString)")

    init() {
        let suite = "CrashReportsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private var saved: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.sorted()
    }

    @Test func offByDefaultAndTheFirstCrashAsks() {
        let reports = CrashReports(defaults: defaults, directory: directory)
        #expect(!reports.keepsReports)
        #expect(!reports.asksForConsent)

        reports.received(["{\"signal\":11}"])

        #expect(reports.asksForConsent)
        #expect(saved.isEmpty)
    }

    @Test func aCrashUnansweredAtQuitAsksAgainOnRelaunchAndIsKeptOnYes() {
        CrashReports(defaults: defaults, directory: directory).received(["first"])

        let relaunched = CrashReports(defaults: defaults, directory: directory)
        #expect(relaunched.asksForConsent)
        relaunched.answer(keep: true)

        #expect(saved == ["first"])
        #expect(!CrashReports(defaults: defaults, directory: directory).asksForConsent)
    }

    @Test func decliningDiscardsTheUnansweredCrash() {
        CrashReports(defaults: defaults, directory: directory).received(["first"])
        CrashReports(defaults: defaults, directory: directory).answer(keep: false)

        #expect(!CrashReports(defaults: defaults, directory: directory).asksForConsent)
        #expect(saved.isEmpty)
    }

    @Test func optingInKeepsTheCrashThatAskedAndLaterOnes() {
        let reports = CrashReports(defaults: defaults, directory: directory)
        reports.received(["first"])
        reports.answer(keep: true)
        reports.received(["second"])

        #expect(!reports.asksForConsent)
        #expect(saved == ["first", "second"])
        #expect(CrashReports(defaults: defaults, directory: directory).keepsReports)
    }

    @Test func decliningIsRememberedAndNeverAsksAgain() {
        let reports = CrashReports(defaults: defaults, directory: directory)
        reports.received(["first"])
        reports.answer(keep: false)

        let relaunched = CrashReports(defaults: defaults, directory: directory)
        relaunched.received(["second"])

        #expect(!relaunched.asksForConsent)
        #expect(saved.isEmpty)
    }

    @Test func turningOffDeletesKeptReports() {
        let reports = CrashReports(defaults: defaults, directory: directory)
        reports.keepsReports = true
        reports.received(["first"])
        reports.keepsReports = false

        #expect(saved.isEmpty)
    }

    @Test func keptReportsAreRedactedAndCapped() {
        let reports = CrashReports(defaults: defaults, directory: directory)
        reports.keepsReports = true
        reports.received((0 ... CrashReports.limit).map { "access_token=secret\($0)" })

        #expect(saved.count == CrashReports.limit)
        #expect(saved.allSatisfy { !$0.contains("secret") })
    }
}
