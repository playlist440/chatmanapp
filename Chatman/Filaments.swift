import SwiftUI
import ChatmanKit

/// Filaments of light drifting behind the chat list and the conversations.
///
/// Built from the reference rather than from memory: thin bright strands waving across a dark
/// field, with sparks riding along them. Softer than the original on purpose — the strands are
/// thinner, dimmer and fewer. Not blurrier: a blurred filament is a smudge, and the whole
/// effect depends on the line staying a line.
///
/// The speed sits between the two things it was measured against: the first version of this,
/// which read as a still picture, and the reference itself, which moves about fifty times
/// faster than that and is far too busy to sit behind words you are trying to read.
///
/// Drawn rather than played. A video long enough to stop reading as a loop is tens of
/// megabytes — more than the whole app — and a decoder running behind a scrolling list
/// competes for exactly the resources the list needs. This is six curves and twenty-two dots.
/// `CPUMeter` is what says what that costs on a phone.
///
/// In the light the same strands are drawn in ink on a white page with a breath of the colour
/// across it, rather than as light on a dark one.
struct Filaments: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Which colour the light is.
    let colour: BackdropColour

    /// How far up the light is turned, over everything drawn on top of the field.
    ///
    /// One number rather than eleven, because this is the dial that gets turned. The strands
    /// were set by what looked right against an empty screen, and an empty screen is not where
    /// they live: over a conversation the same lines cut straight through the words. Reading
    /// beats atmosphere every time.
    ///
    /// A slider in the settings, the same one that turns the stars and the ribbon up and down.
    let presence: Double

    /// How much of the coloured field is there, from none of it to all of it.
    ///
    /// Its own dial, because it is its own thing. `presence` turns the drawn light up and
    /// down — the strands and the sparks — and leaves the wash of colour they lie on exactly
    /// where it was. You can end up with barely-there filaments over a green haze that is
    /// still shouting, and no amount of the first slider fixes that.
    let glow: Double

    /// Held still by whoever is drawing it, on top of its own reasons for stopping: a screen
    /// with another one on top of it, in practice.
    ///
    /// Not while scrolling any more. It used to stop then, to leave the drawing to the list;
    /// but it is six strokes twelve times a second, and a background that freezes the moment
    /// you touch the screen reads as one that broke.
    var isHeldStill: Bool = false

    /// Whether the filaments are drawn yet.
    ///
    /// The field goes up with the screen; the light follows a moment later. Building the
    /// canvas and starting its clock costs 49 milliseconds, measured, and it lands squarely in
    /// the gap between tapping a chat and seeing it. Nothing about a drift of a point a second
    /// needs to begin in that gap, and the colour being there from the first frame means
    /// there is nothing to see arriving.
    @State private var showsLight = false

    /// Redraws per second.
    ///
    /// Twelve, and tied to the speed rather than chosen for its own sake. Four was plenty
    /// while the quickest point moved a point and a quarter in a second; at five and a half it
    /// would jump more than two points between frames, and a bright thin line that jumps is a
    /// line that stutters. Twelve puts the step back under half a point.
    ///
    /// The two are not the same dial. How fast the light travels is a matter of taste; how
    /// often it is drawn is what it costs. Raising the first is what forced the second.
    static let rate: Double = 12

    #if DEBUG
    /// Counts how often it actually drew, and writes the rate out every hundred frames.
    ///
    /// Debug only, off unless the run asked for it with `--count-frames`, and the only reason
    /// it exists is that "four times a second" is a claim. `minimumInterval` is a floor, not a
    /// promise — a timeline can be asked for four and be driven at a hundred and twenty by
    /// whatever else is animating on the same screen. It came back at 4.00.
    private enum Counter {
        nonisolated(unsafe) static var frames = 0
        nonisolated(unsafe) static var started: Date?

        static let isCounting = ProcessInfo.processInfo.arguments.contains("--count-frames")

        static func tick() {
            guard isCounting else { return }

            let now = Date()
            if started == nil { started = now; frames = 0 }
            frames += 1

            guard frames % 100 == 0, let started else { return }

            let elapsed = now.timeIntervalSince(started)
            let line = "Drew \(frames) frames in \(String(format: "%.1f", elapsed))s"
                + " — \(String(format: "%.2f", Double(frames) / elapsed)) per second\n"
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("backdrop-frames.txt")

            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
    #endif

    var body: some View {
        ZStack {
            field

            // Only this layer is inside the timeline. The field underneath is outside it and
            // is never asked to draw again.
            //
            // And not at all with the filaments turned right down. At nought every strand and
            // spark is drawn at nothing, but the timeline went on redrawing a full screen of
            // nothing twelve times a second — battery spent on a picture nobody could see.
            if showsLight, presence > 0 {
                TimelineView(.animation(minimumInterval: 1 / Self.rate, paused: isStill)) { timeline in
                    // The shared clock, so the list and a conversation show the same strands,
                    // and coming back after an hour carries on rather than leaping. See
                    // `BackdropClock`.
                    let seconds = BackdropClock.seconds(at: timeline.date)

                    #if DEBUG
                    let _ = Counter.tick()
                    #endif

                    Canvas(opaque: false) { context, size in
                        // Light added to light: where two strands cross, the crossing is brighter.
                        // Painted over each other instead, they look like wire. On a white page
                        // there is no light to add, and ink simply lies on top.
                        if isDark { context.blendMode = .plusLighter }

                        for strand in Self.strands {
                            draw(strand, at: seconds, in: size, with: &context)
                        }
                        for spark in Self.sparks {
                            draw(spark, at: seconds, in: size, with: &context)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .task {
            // One beat, which is the push settling. Not a fade-in of the colour — that is
            // already there — only of the light on it.
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.easeOut(duration: 0.45)) { showsLight = true }
        }
        .allowsHitTesting(false)
    }

    private var isDark: Bool { scheme == .dark }

    /// What the strands and sparks are drawn in: light in the dark, ink in the light.
    private var strandColour: Color { isDark ? colour.light : colour.ink }

    /// Held still when nobody is looking, and for anybody who asked for less movement.
    ///
    /// The second one is not a nicety: a slow drift at the edge of perception is precisely
    /// the sort of thing that sets off motion sensitivity, because you keep catching it.
    private var isStill: Bool {
        isHeldStill || reduceMotion || scenePhase != .active
    }

    // MARK: - What doesn't move

    /// The dark it all sits on: a wash of colour across the middle, night at the corners. Or by
    /// day the white page, with a breath of the colour where the light would be.
    ///
    /// Two static gradients, drawn once. Nothing in here takes a time.
    @ViewBuilder
    private var field: some View {
        if isDark { darkField } else { lightField }
    }

    private var lightField: some View {
        ZStack {
            Color.white

            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.2),
                        .init(color: colour.wash, location: 0.52),
                        .init(color: .white, location: 0.9),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                EllipticalGradient(
                    stops: [
                        .init(color: colour.wash.opacity(0.9), location: 0),
                        .init(color: colour.wash.opacity(0), location: 1),
                    ],
                    center: UnitPoint(x: 0.34, y: 0.46),
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.62
                )
            }
            .opacity(glow)
        }
    }

    private var darkField: some View {
        ZStack {
            // Solid, and outside the fading below. Faded towards black rather than towards
            // white: at nought this is an unlit screen, which is where somebody who turns it
            // all the way down wants to be.
            //
            // It sat inside the fade at first, which made the whole backdrop see-through
            // rather than merely darker — invisible on a conversation, where the page behind
            // is black anyway, and plain as day in the settings, where it is white.
            Color.black

            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: colour.edge, location: 0),
                        .init(color: colour.edge, location: 0.22),
                        .init(color: colour.glow, location: 0.52),
                        .init(color: colour.edge, location: 0.9),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Off to one side, because a light in the middle of a screen is a stain.
                EllipticalGradient(
                    stops: [
                        .init(color: colour.glow.opacity(0.9), location: 0),
                        .init(color: colour.glow.opacity(0), location: 1),
                    ],
                    center: UnitPoint(x: 0.34, y: 0.46),
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.62
                )
                .blendMode(.plusLighter)
            }
            .opacity(glow)
        }
    }

    // MARK: - The filaments

    /// One strand of light: a line bent by two waves running along it at different speeds.
    ///
    /// Two and not one. A single sine is a skipping rope, and you can see the rhythm of it
    /// within seconds; two of different lengths beat against each other and never quite come
    /// back to the same shape.
    struct Strand: Identifiable, Sendable {
        let id: Int

        /// Where it sits down the screen, and how far it strays from there, both as a
        /// fraction of the height.
        let centre: Double
        let sway: Double
        let ripple: Double

        /// How many crests fit across the screen, for each of the two waves.
        let crests: Double
        let ripples: Double

        /// How long each takes to travel one crest along, in seconds.
        let periods: (sway: Double, ripple: Double)

        /// Where in its cycle it starts, so no two strands are ever in step.
        let phase: Double

        /// How thick and how bright the line itself is.
        let width: Double
        let alpha: Double

        /// Where it is, as a fraction of the height, at a point along the screen.
        func height(at across: Double, time seconds: Double) -> Double {
            centre
                + sway * sin(2 * .pi * (across * crests - seconds / periods.sway + phase))
                + ripple * sin(2 * .pi * (across * ripples + seconds / periods.ripple + phase * 1.7))
        }

        /// The fastest any point on it travels up or down, as a fraction of the height per
        /// second. Both waves at full tilt at once, which is the worst it can be.
        var speed: Double {
            2 * .pi * (sway / periods.sway + ripple / periods.ripple)
        }
    }

    /// Six of them, in a band across the middle, thin enough to read as light.
    ///
    /// Every period is a prime number of seconds, so the pattern only returns when all twelve
    /// come round at once.
    static let strands: [Strand] = [
        Strand(id: 0, centre: 0.40, sway: 0.052, ripple: 0.022,
               crests: 1.15, ripples: 2.7, periods: (sway: 67, ripple: 101),
               phase: 0.00, width: 1.5, alpha: 0.34),
        Strand(id: 1, centre: 0.455, sway: 0.044, ripple: 0.026,
               crests: 1.35, ripples: 3.1, periods: (sway: 71, ripple: 103),
               phase: 0.37, width: 1.1, alpha: 0.26),
        Strand(id: 2, centre: 0.495, sway: 0.058, ripple: 0.019,
               crests: 0.95, ripples: 2.3, periods: (sway: 73, ripple: 107),
               phase: 0.81, width: 1.8, alpha: 0.40),
        Strand(id: 3, centre: 0.535, sway: 0.038, ripple: 0.028,
               crests: 1.55, ripples: 3.5, periods: (sway: 79, ripple: 109),
               phase: 1.44, width: 1.0, alpha: 0.22),
        Strand(id: 4, centre: 0.58, sway: 0.049, ripple: 0.021,
               crests: 1.05, ripples: 2.9, periods: (sway: 83, ripple: 113),
               phase: 2.02, width: 1.3, alpha: 0.29),
        Strand(id: 5, centre: 0.63, sway: 0.041, ripple: 0.024,
               crests: 1.25, ripples: 2.5, periods: (sway: 89, ripple: 97),
               phase: 2.71, width: 0.9, alpha: 0.18),
    ]

    /// How many points make up one strand.
    ///
    /// Ninety-six. A thin bright line is where straight segments show, and at forty-eight you
    /// could see the corners on a phone this wide.
    private static let steps = 96

    private func draw(
        _ strand: Strand, at seconds: Double, in size: CGSize,
        with context: inout GraphicsContext
    ) {
        var path = Path()
        for step in 0...Self.steps {
            let across = Double(step) / Double(Self.steps)
            let point = CGPoint(
                x: size.width * across,
                y: size.height * strand.height(at: across, time: seconds)
            )
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }

        // Faded out at both ends, so the strands come from somewhere and go somewhere rather
        // than stopping dead against the edge of the screen.
        func shading(_ alpha: Double) -> GraphicsContext.Shading {
            .linearGradient(
                Gradient(stops: [
                    .init(color: strandColour.opacity(0), location: 0),
                    .init(color: strandColour.opacity(alpha), location: 0.22),
                    .init(color: strandColour.opacity(alpha), location: 0.78),
                    .init(color: strandColour.opacity(0), location: 1),
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            )
        }

        // The halo first and the line over it. Two strokes rather than a blur: a blur pass
        // costs a full screen of work every frame and softens the line it is meant to sit
        // under, and a soft line is no longer a filament.
        let alpha = strand.alpha * presence
        context.stroke(path, with: shading(alpha * 0.16), lineWidth: strand.width * 7)
        context.stroke(path, with: shading(alpha), lineWidth: strand.width)
    }

    // MARK: - The sparks

    /// A speck of light riding one of the strands.
    struct Spark: Identifiable, Sendable {
        let id: Int

        /// Which strand it sits on, where along it, and how far off it.
        let strand: Int
        let along: Double
        let above: Double

        let size: Double

        /// How long one blink takes, and where in that it starts.
        let period: Double
        let phase: Double

        /// How bright it is now.
        ///
        /// Raised to the fifth, so it spends four fifths of its time dark and only briefly
        /// catches. A sine on its own gives twenty-two specks all swelling and fading like a
        /// heartbeat, which reads as a machine; cubed was still six of them alight at any
        /// moment, which is a string of fairy lights.
        func brightness(at seconds: Double) -> Double {
            let swing = (sin(2 * .pi * (seconds / period + phase)) + 1) / 2
            let squared = swing * swing
            return squared * squared * swing
        }
    }

    /// Twenty-two of them, scattered along the strands.
    ///
    /// Written out rather than generated, so the picture is the same on every phone and on
    /// every launch, and so this file is the whole truth about what gets drawn.
    static let sparks: [Spark] = {
        let places: [(Int, Double, Double, Double, Double, Double)] = [
            (0, 0.14, 0.004, 1.7, 7.3, 0.11), (0, 0.42, -0.010, 1.2, 9.1, 0.63),
            (0, 0.71, 0.012, 1.9, 6.1, 0.28), (1, 0.09, -0.006, 1.3, 8.3, 0.85),
            (1, 0.33, 0.011, 2.1, 5.9, 0.42), (1, 0.62, -0.013, 1.5, 10.7, 0.07),
            (1, 0.88, 0.005, 1.1, 7.9, 0.71), (2, 0.21, 0.013, 2.3, 6.7, 0.35),
            (2, 0.48, -0.008, 1.4, 11.3, 0.92), (2, 0.66, 0.009, 1.8, 8.9, 0.19),
            (2, 0.93, -0.011, 1.2, 5.3, 0.56), (3, 0.17, 0.007, 1.6, 9.7, 0.78),
            (3, 0.39, -0.012, 2.0, 6.3, 0.24), (3, 0.75, 0.010, 1.3, 12.1, 0.49),
            (4, 0.06, -0.005, 1.1, 7.1, 0.66), (4, 0.29, 0.012, 1.9, 10.1, 0.13),
            (4, 0.55, -0.009, 1.5, 8.1, 0.88), (4, 0.83, 0.006, 1.2, 5.7, 0.31),
            (5, 0.24, -0.011, 1.7, 11.9, 0.59), (5, 0.51, 0.008, 1.4, 6.9, 0.04),
            (5, 0.78, -0.007, 1.0, 9.3, 0.82), (5, 0.96, 0.010, 1.6, 7.7, 0.45),
        ]

        return places.enumerated().map { index, place in
            Spark(
                id: index, strand: place.0, along: place.1, above: place.2,
                size: place.3, period: place.4, phase: place.5
            )
        }
    }()

    private func draw(
        _ spark: Spark, at seconds: Double, in size: CGSize,
        with context: inout GraphicsContext
    ) {
        let brightness = spark.brightness(at: seconds)
        guard brightness > 0.02 else { return }

        let strand = Self.strands[spark.strand]
        let y = size.height * (strand.height(at: spark.along, time: seconds) + spark.above)
        let centre = CGPoint(x: size.width * spark.along, y: y)

        // The same fade as the strands: a spark hanging in the empty margin has nothing to
        // have come off.
        let edge = min(spark.along, 1 - spark.along)
        let fade = min(1, edge / 0.18)
        guard fade > 0 else { return }

        let halo = spark.size * 4
        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - halo, y: centre.y - halo, width: halo * 2, height: halo * 2
            )),
            with: .radialGradient(
                Gradient(colors: [
                    strandColour.opacity(0.22 * brightness * fade * presence),
                    strandColour.opacity(0),
                ]),
                center: centre, startRadius: 0, endRadius: halo
            )
        )

        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - spark.size / 2, y: centre.y - spark.size / 2,
                width: spark.size, height: spark.size
            )),
            with: .color(strandColour.opacity(0.85 * brightness * fade * presence))
        )
    }
}

#Preview("Dark") {
    Filaments(colour: .purple, presence: 0.55, glow: 1)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    Filaments(colour: .purple, presence: 0.55, glow: 1)
        .ignoresSafeArea()
        .preferredColorScheme(.light)
}
