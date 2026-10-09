import Testing
import Foundation
@testable import Chatman

/// Writes a measurement where the machine running the tests can read it back.
///
/// `print` from a test bundle in a simulator goes nowhere you can reach from a terminal, and
/// a number nobody can read is not a measurement.
private func report(_ line: String) {
    print(line)
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("backdrop-bench.txt")

    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    } else {
        try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// What the drifting flares cost, and what they do.
///
/// The claim being made is that they are cheaper than a video and that you can't see them
/// move. Both are measurable, so both are measured here rather than asserted in a comment.
@Suite("Filaments")
struct FilamentsTests {

    @Test("A frame of it is a rounding error")
    func frameCost() {
        let frames = 20_000
        var sink = 0.0

        let clock = ContinuousClock()
        let taken = clock.measure {
            for i in 0..<frames {
                let seconds = Double(i) * 0.25
                // What a frame actually works out: every point of every strand, then every
                // spark. Anything less than this is measuring a smaller job than the one that
                // runs four times a second.
                for strand in Filaments.strands {
                    for step in 0...96 {
                        sink += strand.height(at: Double(step) / 96, time: seconds)
                    }
                }
                for spark in Filaments.sparks {
                    sink += spark.brightness(at: seconds)
                }
            }
        }

        #expect(sink != 0)

        let perFrame = taken / frames
        let microseconds = Double(perFrame.components.attoseconds) / 1e12
        report("Per frame: \(String(format: "%.1f", microseconds)) µs of arithmetic")
        report("Per second at \(Int(Filaments.rate)) fps: "
            + String(format: "%.1f", microseconds * Filaments.rate) + " µs of CPU")

        // Half a millisecond a frame. The real cost is the drawing, not the sines — on an
        // iPhone 13 Pro the whole thing came to 3.3 ms a frame — but this catches somebody
        // putting real work in the wave functions later.
        #expect(microseconds < 500)
    }

    @Test("It moves without catching your eye")
    func tooSlowToSee() {
        // Between the two things it was judged against. The first version of this moved at
        // 0.94 points a second and read as a photograph; the reference it is modelled on works
        // out at roughly fifty points a second on a screen this tall, which is lively enough
        // to pull your eye off the messages. This sits between them, nearer the calm end.
        let tallest = 874.0  // an iPhone 13 Pro, in points
        let fastest = (Filaments.strands.map(\.speed).max() ?? 0) * tallest

        report("Fastest strand: \(String(format: "%.2f", fastest)) points per second"
            + " — \(String(format: "%.0f", fastest * 60)) points in a minute")

        #expect(fastest < 8.0)

        // And measured from the drawn positions, in case the shortcut above ever stops
        // matching what ends up on screen.
        var measured = 0.0
        let step = 0.25

        for frame in 0..<8_000 {
            let now = Double(frame) * step
            for strand in Filaments.strands {
                for place in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    let a = strand.height(at: place, time: now)
                    let b = strand.height(at: place, time: now + step)
                    measured = max(measured, abs(b - a) / step * tallest)
                }
            }
        }

        #expect(measured <= fastest + 0.01)
    }

    @Test("The strands stay in their band")
    func staysInBand() {
        // Nothing wanders up behind the header or down under the composer. A filament that
        // creeps out from under a message is one you notice, and noticing is the failure.
        var highest = 1.0
        var lowest = 0.0

        for frame in 0..<8_000 {
            let now = Double(frame) * 0.25
            for strand in Filaments.strands {
                for step in 0...24 {
                    let y = strand.height(at: Double(step) / 24, time: now)
                    highest = min(highest, y)
                    lowest = max(lowest, y)
                }
            }
        }

        report("Band: \(String(format: "%.3f", highest)) to \(String(format: "%.3f", lowest))"
            + " of the height")

        #expect(highest > 0.2)
        #expect(lowest < 0.8)
    }

    @Test("The sparks don't blink together")
    func sparksAreScattered() {
        // Twenty-two specks pulsing in time is a heartbeat, and a heartbeat is a machine.
        // What matters is that the usual picture is a few alight and most of them dark —
        // moments where a lot of them happen to catch are fine, and the reference has them.
        var busiest = 0
        var total = 0
        let frames = 4_000

        for frame in 0..<frames {
            let now = Double(frame) * 0.25
            let lit = Filaments.sparks.filter { $0.brightness(at: now) > 0.5 }.count
            busiest = max(busiest, lit)
            total += lit
        }

        let usual = Double(total) / Double(frames)
        report("Sparks alight: \(String(format: "%.1f", usual)) on average,"
            + " \(busiest) at the busiest, of \(Filaments.sparks.count)")

        #expect(usual < Double(Filaments.sparks.count) * 0.25)
        #expect(busiest < Filaments.sparks.count)
    }

    @Test("And it doesn't come back around")
    func neverRepeats() {
        // Every period is a prime number of seconds: the picture only returns when all of
        // them come round at once.
        var periods: [Double] = []
        for strand in Filaments.strands {
            periods.append(strand.periods.sway)
            periods.append(strand.periods.ripple)
        }

        #expect(Set(periods).count == periods.count)

        let years = periods.reduce(1, *) / (60 * 60 * 24 * 365.25)
        report("Repeats after \(String(format: "%.2e", years)) years")
        #expect(years > 1_000_000)

        // And in the meantime it really is somewhere else.
        let moved = Filaments.strands
            .map { abs($0.height(at: 0.5, time: 1_800) - $0.height(at: 0.5, time: 0)) }
            .reduce(0, +)

        report("Moved in half an hour: \(String(format: "%.0f", moved * 874)) points,"
            + " added up over six strands")
        #expect(moved * 874 > 50)
    }
}
