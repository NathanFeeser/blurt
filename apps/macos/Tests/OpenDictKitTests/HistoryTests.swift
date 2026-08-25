import Foundation
import OpenDictCore
import Testing

@testable import OpenDictKit

@Suite("History")
@MainActor
struct HistoryTests {

    @Test("Recording is on out of the box and opens a store")
    func openByDefault() {
        let model = makeModel()
        #expect(model.historyEnabled)
        #expect(model.engine.historyIsOpen())
        #expect(FileManager.default.fileExists(atPath: AppModel.historyURL.path))
    }

    @Test("Switching history off closes the store")
    func switchingOffClosesTheStore() {
        // The guarantee behind the switch: with no store open, the core has
        // nowhere to write even if a mode asks it to.
        let model = makeModel()
        model.historyEnabled = false
        #expect(!model.engine.historyIsOpen())

        model.historyEnabled = true
        #expect(model.engine.historyIsOpen())
    }

    @Test("Switching history off does not delete what is already there")
    func switchingOffKeepsExistingEntries() {
        let model = makeModel()
        let path = AppModel.historyURL.path
        model.historyEnabled = false
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Changing the retention limit reopens the store")
    func changingTheLimitReopens() {
        let model = makeModel()
        model.historyLimit = 100
        #expect(model.historyLimit == 100)
        #expect(model.engine.historyIsOpen())
    }

    @Test("Reading history with nothing recorded is empty, not an error")
    func emptyHistoryReadsCleanly() {
        let model = makeModel()
        #expect(model.historyRecent().isEmpty)
        #expect(model.historySearch("anything").isEmpty)
    }

    @Test("Clearing works even while recording is switched off")
    func clearingWorksWhileOff() {
        // Off closes the store, so clearing has to reopen it. A privacy control
        // that appears to work while leaving everything on disk is worse than
        // not having one.
        let model = makeModel()
        model.historyEnabled = false
        model.clearHistory()
        #expect(!model.engine.historyIsOpen(), "clearing must not leave recording switched on")
    }

    @Test("The Private preset never records")
    func privateModeOptsOut() {
        // The preset exists so that "nothing leaves this machine" is one click.
        // A transcript of it sitting in a database would undercut that.
        #expect(!privateMode().recordHistory)
        #expect(starterModes().allSatisfy { $0.recordHistory })
    }
}
