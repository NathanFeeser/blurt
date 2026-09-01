import Foundation
import Sparkle

/// Where updates come from.
///
/// Info.plist names the real feed, and that is what ships. This exists for one
/// reason: Sparkle 2 no longer honours a feed URL placed in user defaults, so
/// short of rebuilding the app there was no way to point an installed build at
/// a local appcast — which meant the update path could only ever be exercised
/// by publishing a real release and hoping. `BLURT_UPDATE_FEED` in the
/// environment overrides the feed for that one launch and nothing else.
///
///     BLURT_UPDATE_FEED=http://localhost:8000/appcast.xml \
///       build/Blurt.app/Contents/MacOS/Blurt
///
/// scripts/rehearse-update.sh is the whole rehearsal, end to end.
final class UpdateFeed: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["BLURT_UPDATE_FEED"]
    }
}
