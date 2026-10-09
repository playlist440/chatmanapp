import Testing
import Foundation
@testable import ChatmanKit

/// The burst rule, run over a year of a real group.
///
/// Reads every export `server/terugtest.sh` made, from
/// `~/Library/Application Support/chatman-terugtest/`, and writes beside each one when the rule
/// would have gone off. Without an export it does nothing: the numbers in `Attention.Burst` are
/// a starting point until somebody has looked at what they do to a group they know.
///
/// What to look for: a group should go off once or twice a month at most, and on the days you
/// remember something actually happening. If it goes off more, raise the minimum; if it misses
/// the day the street was flooded, lower it — and write down in `Attention.Burst` what the
/// check found.
@Suite("Burst backtest")
struct BurstBacktestTests {

    private static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/chatman-terugtest")
    }

    @Test("A year of a real group, if there is one to look at")
    func backtest() throws {
        let exports = ((try? FileManager.default.contentsOfDirectory(
            at: Self.folder, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "csv" }

        for export in exports {
            let report = try Self.run(on: export)
            try report.write(
                to: export.deletingPathExtension().appendingPathExtension("uitkomst.txt"),
                atomically: true, encoding: .utf8
            )
        }
    }

    @Test("The playback finds the one evening something happened, and nothing else")
    func syntheticYear() throws {
        // A quiet group: three messages a day from a handful of neighbours, for a year —
        // and one evening with forty messages from six people in twenty minutes.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var lines: [String] = []
        for day in 0..<365 {
            for message in 0..<3 {
                let at = start.addingTimeInterval(Double(day) * 86_400 + Double(message) * 3_600 + 36_000)
                lines.append("\(Int(at.timeIntervalSince1970 * 1000)),n\(message)")
            }
            if day == 200 {
                for message in 0..<40 {
                    let at = start.addingTimeInterval(Double(day) * 86_400 + 72_000 + Double(message) * 30)
                    lines.append("\(Int(at.timeIntervalSince1970 * 1000)),p\(message % 6)")
                }
            }
        }

        let file = FileManager.default.temporaryDirectory.appending(path: "synthetic-\(UUID()).csv")
        try lines.sorted().joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let report = try Self.run(on: file)
        #expect(report.contains("1 uitbarstingen"))
    }

    /// Plays the export back as if the app had looked every five minutes all year — the most
    /// it could ever see — and lists every burst the rule calls.
    static func run(on export: URL) throws -> String {
        typealias Burst = Attention.Burst

        let rows = try String(contentsOf: export, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line -> (at: Date, sender: String)? in
                let parts = line.split(separator: ",")
                guard parts.count == 2, let ms = Double(parts[0]) else { return nil }
                return (Date(timeIntervalSince1970: ms / 1000), String(parts[1]))
            }
        guard let first = rows.first?.at, let last = rows.last?.at else { return "Leeg." }

        let step: TimeInterval = 5 * 60
        var typical = 0.0
        var log = ""
        var lastBurst: Date?
        var bursts: [(Date, Int, Int)] = []
        var index = 0
        var tick = first

        while tick <= last {
            let next = tick.addingTimeInterval(step)
            var rise = 0
            while index < rows.count, rows[index].at < next {
                rise += 1
                index += 1
            }

            typical = Burst.learn(typicalDaily: typical, rise: rise, after: step)
            log = Burst.log(log, adding: rise, at: next)
            let messages = Burst.total(in: log, now: next)

            if messages >= Burst.minimumMessages {
                let windowStart = next.addingTimeInterval(-Burst.window)
                let people = Set(rows.lazy
                    .filter { $0.at >= windowStart && $0.at < next }
                    .map(\.sender)).count

                if Burst.isBurst(messages: messages, people: people, typicalDaily: typical,
                                 lastBurst: lastBurst, now: next) {
                    lastBurst = next
                    bursts.append((next, messages, people))
                }
            }
            tick = next
        }

        let months = max(1, last.timeIntervalSince(first) / (30 * 86_400))
        var lines = [
            "\(rows.count) berichten, \(Int(months.rounded())) maanden, gewone dag nu \(Int(typical.rounded())) berichten.",
            String(format: "%d uitbarstingen, %.1f per maand.", bursts.count, Double(bursts.count) / months),
            ""
        ]
        for (at, messages, people) in bursts {
            lines.append("\(at.formatted(date: .abbreviated, time: .shortened))  \(messages) berichten, \(people) mensen")
        }
        return lines.joined(separator: "\n")
    }
}
