import AppKit
import OpenDictKit

// No storyboard, no @main attribute: a menu-bar-only app is simplest to set up
// imperatively, and this keeps the whole launch path visible in one file.
// Everything else lives in OpenDictKit so it can be tested.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
