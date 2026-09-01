import Testing

@testable import BlurtKit

/// Tests run inside a host with its own bundle id, and everything keyed on the
/// app's identity — keychain service, log file, history folder — follows it.
/// That is what lets a test build an `AppModel` without reading whoever's real
/// API keys are in the keychain, or writing into the log they are debugging
/// with. Both used to happen.
@Suite("App identity")
struct AppIdentityTests {

    @Test("A test host is never the released app, and not the dev build either")
    func testsAreDevelopment() {
        #expect(AppIdentity.bundleId != AppIdentity.releaseBundleId)
        // Nor the dev build's id: its keychain items were created by a
        // different signature than the test host's, and reading one from here
        // would put a password prompt in the middle of a test run.
        #expect(AppIdentity.bundleId != AppIdentity.releaseBundleId + ".dev")
        #expect(AppIdentity.isDevelopment)
        #expect(AppIdentity.name == "Blurt Dev")
    }
}
