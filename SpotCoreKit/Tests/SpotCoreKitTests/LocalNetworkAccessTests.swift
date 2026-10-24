import Network
@testable import SpotCoreKit
import Testing

struct LocalNetworkAccessTests {
    private let policyDenied = NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))

    @Test func policyDeniedMeansNoAccess() {
        #expect(LocalNetworkAccess.allowed(in: .waiting(policyDenied)) == false)
        #expect(LocalNetworkAccess.allowed(in: .failed(policyDenied)) == false)
    }

    @Test func browsingMeansAccess() {
        #expect(LocalNetworkAccess.allowed(in: .ready) == true)
    }

    @Test func otherStatesSayNothing() {
        #expect(LocalNetworkAccess.allowed(in: .setup) == nil)
        #expect(LocalNetworkAccess.allowed(in: .cancelled) == nil)
        #expect(LocalNetworkAccess.allowed(in: .waiting(.posix(.ENETDOWN))) == nil)
    }
}
