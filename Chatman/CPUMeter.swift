#if DEBUG
import Darwin
import Foundation
import UIKit
import ChatmanKit

/// A stopwatch for how long a screen takes to appear after the tap that asks for it.
///
/// Debug only. The complaint was that a conversation opens late, and "late" is somewhere
/// between fifty milliseconds and half a second — one of those is the transition doing its
/// job and the other is real work standing in the way. Guessing which costs more than
/// measuring it.
enum OpenStopwatch {

    /// To a file and not only to the console: a print from a simulator goes somewhere a
    /// terminal can't always reach, and a measurement nobody can read is not one.
    static func write(_ line: String) {
        print(line)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("open-bench.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    nonisolated(unsafe) static var touchedAt: Date?
    nonisolated(unsafe) static var liftedAt: Date?
    nonisolated(unsafe) static var tappedAt: Date?

    /// The finger lands. See `TouchClock`.
    static func touched() {
        touchedAt = Date()
        liftedAt = nil
    }

    /// And comes off again. A link fires on the lift, not on the landing, so without this the
    /// time somebody spent holding still is counted against the app.
    static func lifted() {
        liftedAt = Date()
    }

    /// The navigation actually starts.
    ///
    /// The gap from the touch to here is the one nobody was measuring, and it is the one that
    /// feels like waiting: a row inside a list holds a tap while the scroll view works out
    /// whether you meant to scroll.
    static func tapped() {
        tappedAt = Date()
    }

    /// How long the conversation took to work out what to draw, the first time.
    ///
    /// Only the first: after that it happens on every redraw and is somebody else's problem.
    nonisolated(unsafe) static var reportedPrepare = false

    static func prepared(from started: Date, rows: Int) {
        guard !reportedPrepare else { return }
        reportedPrepare = true

        let taken = Date().timeIntervalSince(started) * 1000
        write(String(format: "[open] working out %d rows took %.0f ms", rows, taken))
    }

    static func appeared(_ what: String) {
        let now = Date()
        defer { touchedAt = nil; liftedAt = nil; tappedAt = nil }

        guard let tappedAt else { return }
        let build = now.timeIntervalSince(tappedAt) * 1000

        // Absolute times, not only the gap between them. The piece that was missing is what
        // happens before the push starts, and every way of catching the finger from inside the
        // app got in the way of the tap it was trying to time — a drag recogniser laid over a
        // row stopped the row opening at all. Whoever pokes the screen knows when they poked
        // it; printing the clock lets them do the subtraction.
        let line: String
        if let touchedAt {
            let held = (liftedAt ?? tappedAt).timeIntervalSince(touchedAt) * 1000
            let recognise = tappedAt.timeIntervalSince(liftedAt ?? touchedAt) * 1000
            line = String(
                format: "[open] %@: %.0f ms held down, %.0f ms lift to push, %.0f ms push to screen",
                what, held, recognise, build
            )
        } else {
            line = String(format: "[open] %@: %.0f ms push to screen", what, build)
        }

        write(line)
    }
}

/// Reports how much processor time the app is using, from inside the app.
///
/// Debug only, and asleep unless the run was started with `--measure-cpu`.
///
/// It exists because the simulator is not a phone. A mesh of gradients goes over the GPU on a
/// device and over something else entirely on a Mac pretending to be one, and the number that
/// came back there — two percent of a core — was never going to be the number here. The way
/// to know what it costs on the phone is to ask the phone.
///
/// Printed rather than filed: `devicectl … --console` streams what the app writes, so the
/// figures arrive on the Mac while the phone is still holding them up.
enum CPUMeter {

    static var isMeasuring: Bool {
        ProcessInfo.processInfo.arguments.contains("--measure-cpu")
    }

    /// Runs the whole measurement: the backdrop on, then the same screen with it off.
    ///
    /// Both halves in one launch on purpose. Two separate runs meant two unlocks, and between
    /// them a phone that had cooled down, changed its screen brightness and been picked up
    /// again — three reasons for two numbers to differ that have nothing to do with what is
    /// being measured. Back to back in one process, the only thing that changes is the switch.
    ///
    /// It also holds the screen awake for the duration, because the backdrop stops when the
    /// screen does and a measurement that ends when the phone dozes off measures a doze.
    @MainActor
    static func run(_ session: ChatSession, rounds: Int = 4, interval: TimeInterval = 30) {
        guard isMeasuring else { return }

        // Whichever backdrop is chosen, against none at all — the stars when none is.
        let original = session.backdrop
        let chosen = original == .none ? .stars : original
        let what = chosen.rawValue
        let switchOn: (Bool) -> Void = { on in
            session.backdrop = on ? chosen : .none
        }

        UIApplication.shared.isIdleTimerDisabled = true

        Task { @MainActor in
            // Long enough for the first screen to have settled: launching, loading and laying
            // out a screen is work nobody is asking about.
            try? await Task.sleep(for: .seconds(20))

            switchOn(true)
            let on = await sample(rounds: rounds, interval: interval, label: "\(what) on ")

            switchOn(false)
            try? await Task.sleep(for: .seconds(10))
            let off = await sample(rounds: rounds, interval: interval, label: "\(what) off")

            let cost = on - off
            print(String(
                format: "[cpu] ---- %.2f%% with, %.2f%% without, so the %@ costs %.2f%%"
                    + " of one core",
                on, off, what, cost
            ))
            // A phone's console is a pipe, and a pipe holds a few short lines back until the
            // app quits. The app doesn't quit after a measurement.
            fflush(stdout)

            // Back as it was: the choice is stored, and a backdrop left off would stay off.
            session.backdrop = original
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Watches for `rounds × interval` seconds and returns the average, as a share of a core.
    private static func sample(
        rounds: Int, interval: TimeInterval, label: String
    ) async -> Double {
        var previous = used()
        var total = 0.0

        for round in 1...rounds {
            try? await Task.sleep(for: .seconds(interval))

            let now = used()
            let spent = now - previous
            previous = now
            total += spent

            print(String(
                format: "[cpu] %@ — %.3f s in %.0f s = %.2f%% of one core (%d of %d)",
                label, spent, interval, spent / interval * 100, round, rounds
            ))
            fflush(stdout)
        }

        return total / (interval * Double(rounds)) * 100
    }

    /// Processor seconds this process has used, live threads and finished ones together.
    ///
    /// Both halves are needed. `TASK_THREAD_TIMES_INFO` forgets a thread the moment it exits,
    /// so on its own the total can go down; `TASK_BASIC_INFO` counts only the ones that have
    /// already gone. Neither is the answer and the sum is.
    private static func used() -> TimeInterval {
        var live = task_thread_times_info()
        var liveCount = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size
        )
        let liveResult = withUnsafeMutablePointer(to: &live) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(liveCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &liveCount)
            }
        }

        var finished = task_basic_info()
        var finishedCount = mach_msg_type_number_t(
            MemoryLayout<task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let finishedResult = withUnsafeMutablePointer(to: &finished) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(finishedCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &finishedCount)
            }
        }

        var total = 0.0
        if liveResult == KERN_SUCCESS {
            total += seconds(live.user_time) + seconds(live.system_time)
        }
        if finishedResult == KERN_SUCCESS {
            total += seconds(finished.user_time) + seconds(finished.system_time)
        }
        return total
    }

    private static func seconds(_ value: time_value_t) -> TimeInterval {
        TimeInterval(value.seconds) + TimeInterval(value.microseconds) / 1_000_000
    }
}
#endif
