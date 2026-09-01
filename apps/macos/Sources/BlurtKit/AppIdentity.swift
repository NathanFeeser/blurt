import Foundation

/// Which Blurt this process is: the released one, or a development build.
///
/// They are different apps on purpose. A development build is signed with a
/// different certificate than a release, and macOS keys every kind of trust
/// on the pair of bundle id and signature: with one bundle id and two
/// signatures, the keychain treats the release as a stranger reading items the
/// dev build created (a password prompt per read), TCC keeps a stale
/// Accessibility entry that neither build satisfies, Sparkle's update state is
/// shared, and one history database is open from two processes. Every one of
/// those bit, one afternoon, in that order.
///
/// So build-macos-app.sh stamps development builds as `com.nerflabs.blurt.dev`
/// named "Blurt Dev", and anything on disk or in a system database that the
/// app owns derives its location from here rather than spelling the name out.
/// The two builds can then be installed, trusted and run side by side — they
/// share nothing but the hotkey.
///
/// A process with no bundle at all — the test host, a bare binary — is not the
/// released app, and gets an id of its own rather than the dev build's: its
/// keychain service must hold nothing, because reading an item some other
/// signature created is a password prompt, and a test run is no place for
/// one. So a test that constructs an `AppModel` reads nobody's keys and writes
/// nobody's log, which was quietly not true before.
enum AppIdentity {
    /// The bundle id every release ships under.
    static let releaseBundleId = "com.nerflabs.blurt"

    static let bundleId = Bundle.main.bundleIdentifier ?? "\(releaseBundleId).unbundled"

    static let isDevelopment = bundleId != releaseBundleId

    /// The name shown in System Settings, Application Support, and dialogs.
    static let name = isDevelopment ? "Blurt Dev" : "Blurt"
}
