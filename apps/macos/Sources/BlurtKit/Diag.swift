import Foundation

/// Append-only diagnostic log at `~/Library/Logs/Blurt.log`.
///
/// Worth keeping rather than deleting after the bug that motivated it: almost
/// everything this app depends on — microphone, Accessibility, code signature,
/// hotkey delivery — fails *silently* when misconfigured, and NSLog/os_log
/// routing on recent macOS is opaque enough that output can vanish from both
/// stderr and `log show` depending on how the process was launched. A plain file
/// is the only thing that reliably answers "did this code path run".
enum Diag {
    static let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Blurt.log")

    /// Serialises writes and guarantees the file exists before opening a handle.
    /// The first version of this raced on creation and dropped lines, which is a
    /// spectacularly bad property for the tool you are using to debug a race.
    private static let queue = DispatchQueue(label: "sh.blurt.diag")

    static func log(_ message: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
