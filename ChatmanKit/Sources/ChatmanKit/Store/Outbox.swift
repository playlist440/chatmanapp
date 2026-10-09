import Foundation

/// Where the bytes of an attachment wait until the server has them.
///
/// A photo used to live only in memory between tapping send and the server answering. If the
/// answer was a failure the bytes were gone, and the bubble could only say "Not sent" with no
/// way to try again — or, worse, the app went to the background halfway and took the photo
/// with it. Now the bytes go to disk first, under the message's transaction ID, and stay there
/// until the send has gone through.
///
/// Kept out of backups: it is a waiting room, not an archive, and it empties itself.
enum Outbox {

    /// The folder, made on first use.
    static var directory: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Outbox", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var marked = folder
            try? marked.setResourceValues(values)
        }
        return folder
    }

    /// Puts bytes aside for one message.
    ///
    /// - Returns: The name to store on the message, relative to the outbox.
    static func keep(_ data: Data, for transactionID: String, named filename: String) throws -> String {
        let name = relativeName(for: transactionID, filename: filename)
        let file = url(for: name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: file, options: .atomic)
        return name
    }

    /// Puts a file aside for one message, as a copy.
    ///
    /// A copy, because the file is not ours: one from the Files app belongs to whoever put it
    /// there, and the picker's copy of a film is cleared up by the picker. On the phone's own
    /// file system a copy of a large film costs no space until one of the two changes.
    static func keep(fileAt source: URL, for transactionID: String, named filename: String) throws -> String {
        let name = relativeName(for: transactionID, filename: filename)
        let file = url(for: name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: source, to: file)
        return name
    }

    /// Where a kept file is.
    static func url(for name: String) -> URL {
        directory.appending(path: name)
    }

    /// Whether a kept file is still there.
    static func holds(_ name: String?) -> Bool {
        guard let name else { return false }
        return FileManager.default.fileExists(atPath: url(for: name).path)
    }

    /// How big a kept file is.
    static func size(of name: String) -> Int? {
        (try? url(for: name).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// Throws away what was kept for one message, once it has been sent.
    static func remove(_ name: String?) {
        guard let name, let folder = name.split(separator: "/").first else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: String(folder)))
    }

    /// Throws away everything no message is waiting on any more.
    ///
    /// A file can outlive its message: the server took it, but the answer never arrived, and
    /// the sync delivered the real message in its place. Nothing then asks for the file again.
    static func sweep(keeping names: Set<String>) {
        let wanted = Set(names.compactMap { $0.split(separator: "/").first.map(String.init) })
        let present = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for folder in present where !wanted.contains(folder) {
            try? FileManager.default.removeItem(at: directory.appending(path: folder))
        }
    }

    /// One folder per message, named after the transaction, with the file's own name inside
    /// so it goes out under the name it came in with.
    private static func relativeName(for transactionID: String, filename: String) -> String {
        let safe = String(filename.map { $0 == "/" || $0 == ":" ? "_" : $0 })
        let folder = String(transactionID.map { $0 == "/" ? "_" : $0 })
        return folder + "/" + (safe.isEmpty ? "attachment" : safe)
    }
}

/// Keeps the app running for a moment after it leaves the screen.
///
/// Sending is the one thing that must not stop when you put the phone away: a message you
/// typed and sent, then locked the screen on, should arrive. The system gives an app a short
/// while for this when it asks; this is the asking, and the saying when it's done.
///
/// `performExpiringActivity` rather than a background task from UIKit, because this package is
/// also linked into the watch face, where UIKit's version is off limits — and it works the
/// same on the phone and the watch.
final class KeepAwake: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)

    private init() {}

    /// Asks for time, and holds it until ``end()``.
    static func begin(_ reason: String) -> KeepAwake {
        let hold = KeepAwake()
        #if os(iOS) || os(watchOS)
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
            if expired {
                // The system wants its time back. Let the waiting call below go.
                hold.done.signal()
                return
            }
            // Held here, off the main thread, until the work is done. Three minutes is longer
            // than any send gets anyway.
            _ = hold.done.wait(timeout: .now() + 180)
        }
        #endif
        return hold
    }

    /// Hands the time back.
    func end() {
        done.signal()
    }
}
