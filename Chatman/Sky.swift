import SwiftUI
import ChatmanKit

/// The sky behind Chatman: stars at night, the sun by day.
///
/// One picture for the list and every conversation, so the app has a ground of its own rather
/// than the system's white or black. Dark is a night sky: stars at three distances that come
/// out and go again, and every so often a real constellation that draws itself and fades.
/// Light is the same idea by day: the light of a sun just off the screen, a few broad rays,
/// and dust that only shows where a ray passes through it. The sun keeps the time — low and
/// rosy on the left in the morning, high and white at midday, low and golden on the right
/// towards evening, and a cool dusk once it has gone down. The phone's clock is all it asks.
///
/// Everything in it is worked out from the time alone. There is nothing stored and nothing to
/// keep in step: the list and a conversation opened from it draw the same sky at the same
/// moment because they are asked about the same moment, and a sky shown after an hour away
/// is simply the sky an hour later.
///
/// Settled in a prototype first, and drawn here with the same shapes, colours and speeds.
///
/// The colour chosen in the settings is the haze across the night and the lines of a
/// constellation; by day it leans the sun's light a little its way. The light dial is how
/// bright the stars, the rays and the dust are, the glow dial how much haze or sunlight
/// there is.
struct Sky: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// How far the screen in front has scrolled. Read while drawing, never observed.
    let depth: SkyDepth

    var colour: BackdropColour = .blue
    var presence: Double = 0.4
    var glow: Double = 0.3

    /// Whether the screen in front is being scrolled. See `rate`.
    var isScrolling = false

    /// Whether something else is on top, so there is nobody to draw for.
    var isCovered = false

    /// Drawings per second.
    ///
    /// Twenty at rest. The quickest star moves six tenths of a point a second, three
    /// hundredths of a point a step at this rate — far less than a pixel.
    ///
    /// This is the dial that matters. Drawing a screenful has a fixed price whatever is in it:
    /// measured in the simulator, a sky that redrew twenty times a second and drew nothing
    /// cost five of the six percent of a core the full sky did. Gathering the stars into fewer
    /// paths and drawing on the graphics chip were both tried, and neither was cheaper; fewer
    /// stars could save at most the one percent that is left.
    ///
    /// While the screen scrolls, as often as the screen itself: the near stars follow half of
    /// the scroll, and at twenty a second a flick moves them in visible jumps.
    private var rate: Double {
        // Smooth enough to follow a thumb; 120 cost a frame's worth of work on every
        // tick while the list was trying to keep up with the finger.
        if isScrolling { return 60 }
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? 8 : 15
    }

    private var isStill: Bool {
        reduceMotion || isCovered || scenePhase != .active
    }

    var body: some View {
        let dark = scheme == .dark

        ZStack {
            // The ground, drawn once — or once a minute by day, as the sun moves.
            if dark {
                Canvas(opaque: true) { context, size in
                    NightSky.field(in: &context, size: size, look: look)
                }
            } else {
                TimelineView(.everyMinute) { timeline in
                    Canvas(opaque: true) { context, size in
                        DaySky.field(in: &context, size: size, sun: DaySky.sun(at: timeline.date, look: look), look: look)
                    }
                }
            }

            TimelineView(.animation(minimumInterval: 1 / rate, paused: isStill)) { timeline in
                #if DEBUG
                let _ = SkyFrames.tick()
                #endif
                Canvas { context, size in
                    // The shared clock, for the movement; the wall clock, for where the sun is.
                    let time = BackdropClock.seconds(at: timeline.date)
                    if dark {
                        NightSky.draw(in: &context, size: size, time: time, offset: depth.offset, look: look)
                    } else {
                        DaySky.draw(
                            in: &context, size: size, time: time, offset: depth.offset,
                            sun: DaySky.sun(at: timeline.date, look: look), look: look
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var look: SkyLook {
        SkyLook(colour: colour, presence: presence, glow: glow)
    }
}

/// The three settings, as the drawing needs them.
struct SkyLook {
    let colour: BackdropColour
    let presence: Double
    let glow: Double

    /// How much brighter or dimmer than as first drawn: one at the light dial's starting point
    /// of forty percent, a third at nought, nearly double at full.
    var light: Double { 0.35 + 1.62 * presence }

    /// The same for the glow dial, which starts at thirty percent.
    var haze: Double { glow / 0.3 }
}

#if DEBUG
/// How often the sky actually draws, written out every two hundred frames.
///
/// Debug only, and off unless the run asks with `--count-frames`. A timeline asked for twenty
/// a second can be driven far faster by something else animating on the same screen, and
/// what it costs follows what it does, not what it was asked.
enum SkyFrames {
    nonisolated(unsafe) static var frames = 0
    nonisolated(unsafe) static var started: Date?
    static let isCounting = ProcessInfo.processInfo.arguments.contains("--count-frames")

    static func tick() {
        guard isCounting else { return }
        let now = Date()
        if started == nil { started = now; frames = 0 }
        frames += 1
        guard frames % 200 == 0, let started else { return }
        let elapsed = now.timeIntervalSince(started)
        print(String(format: "[sky] %d frames in %.1f s — %.1f a second", frames, elapsed, Double(frames) / elapsed))
        fflush(stdout)
    }
}
#endif

/// Where the screen in front of the sky has scrolled to.
///
/// A plain box and deliberately not observable. It changes on every frame of a scroll, and an
/// observed value would rebuild whatever read it that often; the sky is redrawing on a clock
/// anyway, and simply looks in here each time it does.
final class SkyDepth {
    var offset: Double = 0
}

// MARK: - Shared

/// Far, middle and near.
private struct SkyLayer {
    /// How much of the list each one has.
    let share: Double
    /// Radius in points, smallest and largest.
    let size: ClosedRange<Double>
    let alpha: Double
    /// How fast it drifts, in points a second.
    let drift: CGVector
    /// How much of a scroll it follows. Distant things barely move; near ones a little more.
    /// That is what makes it depth rather than wallpaper, and it means a hard flick sends
    /// nothing streaking past.
    let depth: Double

    static let all = [
        SkyLayer(share: 0.55, size: 0.45...0.65, alpha: 0.5, drift: CGVector(dx: -0.16, dy: 0.05), depth: 0.1),
        SkyLayer(share: 0.30, size: 0.65...0.9, alpha: 0.78, drift: CGVector(dx: -0.32, dy: 0.09), depth: 0.25),
        SkyLayer(share: 0.15, size: 0.9...1.25, alpha: 1, drift: CGVector(dx: -0.56, dy: 0.15), depth: 0.5),
    ]

    static func pick(_ unit: Double) -> Int {
        unit < all[0].share ? 0 : unit < all[0].share + all[1].share ? 1 : 2
    }
}

/// A number between nought and one that is always the same for the same question.
///
/// What lets the sky be worked out rather than remembered: the fifth star's third life is
/// wherever this says, every time anybody asks.
private enum Dice {
    static func roll(_ a: Int, _ b: Int, _ salt: UInt64) -> Double {
        var z = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15
        z ^= UInt64(bitPattern: Int64(b)) &* 0xBF58_476D_1CE4_E5B9
        z ^= salt &* 0x94D0_49BB_1331_11EB
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}

private func smooth(_ value: Double) -> Double {
    let x = min(1, max(0, value))
    return x * x * (3 - 2 * x)
}

private func wrap(_ value: Double, _ span: Double) -> Double {
    let r = value.truncatingRemainder(dividingBy: span)
    return r < 0 ? r + span : r
}

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
    Color(red: r / 255, green: g / 255, blue: b / 255)
}

/// The soft light round the brightest stars. Drawn one at a time; there are only a handful.
private func halo(_ context: inout GraphicsContext, at centre: CGPoint, radius: Double, colour: Color, alpha: Double) {
    guard alpha > 0.01 else { return }
    let reach = radius * 9
    context.fill(
        Path(ellipseIn: CGRect(x: centre.x - reach, y: centre.y - reach, width: reach * 2, height: reach * 2)),
        with: .radialGradient(
            Gradient(stops: [
                .init(color: colour.opacity(0.44 * alpha), location: 0),
                .init(color: colour.opacity(0.13 * alpha), location: 0.35),
                .init(color: colour.opacity(0), location: 1),
            ]),
            center: centre, startRadius: 0, endRadius: reach
        )
    )
}

/// One star or speck of dust.
///
/// One fill each, on purpose. Gathering them into a few paths was tried and cost more, not
/// less: a path with dots all over the screen is filled over the whole screen, where a single
/// dot touches a few pixels.
private func dot(_ context: inout GraphicsContext, at centre: CGPoint, radius: Double, colour: Color, alpha: Double) {
    guard alpha > 0.01 else { return }
    context.fill(
        Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
        with: .color(colour.opacity(alpha))
    )
}

// MARK: - Night

enum NightSky {
    /// How many stars are in the sky at once.
    static let count = 150

    private static let warm = rgb(255, 244, 228)
    private static let cool = rgb(212, 225, 255)

    /// Nearly black, with a breath of the chosen colour across the middle.
    static func field(in context: inout GraphicsContext, size: CGSize, look: SkyLook) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [
                .init(color: rgb(3, 5, 11), location: 0),
                .init(color: rgb(7, 12, 28), location: 0.48),
                .init(color: rgb(3, 4, 10), location: 1),
            ]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
        ))

        // Added rather than laid over, so it lights the dark rather than tinting it.
        var light = context
        light.blendMode = .plusLighter
        glow(in: &light, centre: CGPoint(x: size.width * 0.32, y: size.height * 0.42),
             radii: CGSize(width: size.width * 0.9, height: size.height * 0.55),
             stops: [(look.colour.light, min(0.4, 0.1 * look.haze), 0), (look.colour.light, 0, 0.7)])
    }

    /// One star's place in the sky: how long each of its lives lasts, and how it twinkles.
    ///
    /// A star lives out one cycle — comes out, drifts, goes — and is then somewhere else. So
    /// there is always the same number in the sky and never a moment when one blinks off.
    private struct Place {
        let cycle: Double
        let shift: Double
        let twinkle: Double
        let twinklePhase: Double
    }

    private static let places: [Place] = (0..<count).map { i in
        Place(
            cycle: 26 + 32 * Dice.roll(i, 0, 1),
            shift: 1000 * Dice.roll(i, 0, 2),
            twinkle: 0.5 + 1.1 * Dice.roll(i, 0, 3),
            twinklePhase: 2 * .pi * Dice.roll(i, 0, 4)
        )
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, time: Double, offset: Double, look: SkyLook) {
        // A little wider and taller than the screen, so a star wraps round out of sight.
        let span = CGSize(width: size.width + 40, height: size.height + 40)

        // The cooler stars lean towards the chosen colour, a third of the way. Stars are
        // stars; a sky of purple ones would be a theme.
        let cool = Self.cool.mix(with: look.colour.light, by: 0.32)
        let flaring = flares(at: time)

        for (i, place) in places.enumerated() {
            let clock = time + place.shift
            let generation = (clock / place.cycle).rounded(.down)
            let age = clock - generation * place.cycle
            let life = Int(generation)

            let fade = 4 + 3 * Dice.roll(i, life, 5)
            var presence = smooth(age / fade) * smooth((place.cycle - age) / fade)

            // One in eight goes out early instead of fading at the end of its life: a last
            // brief swell, then gone in under a second — the way a star does when something
            // passes in front of it.
            var swell = 0.0
            if Dice.roll(i, life, 12) < 0.125 {
                let goes = place.cycle * (0.35 + 0.4 * Dice.roll(i, life, 13))
                swell = 0.9 * smooth((age - goes + 0.9) / 0.6) * (1 - smooth((age - goes) / 0.5))
                presence *= 1 - smooth((age - goes) / 0.8)
            }
            guard presence > 0 else { continue }

            // And now and then one flares and settles again. See `flares`.
            let flare = flaring.first { $0.star == i }?.amount ?? 0
            let lift = 1 + 1.7 * flare + swell

            let layer = SkyLayer.all[SkyLayer.pick(Dice.roll(i, life, 6))]
            let bright = Dice.roll(i, life, 7) < 0.06
            let radius = (layer.size.lowerBound
                + Dice.roll(i, life, 8) * (layer.size.upperBound - layer.size.lowerBound))
                * (bright ? 1.45 : 1) * (1 + 0.55 * flare + 0.25 * swell)

            let x = wrap(Dice.roll(i, life, 9) * span.width + layer.drift.dx * age + 20, span.width) - 20
            let y = wrap(Dice.roll(i, life, 10) * span.height + layer.drift.dy * age
                         - offset * layer.depth + 20, span.height) - 20

            let twinkle = 0.82 + 0.18 * sin(place.twinkle * time + place.twinklePhase)
            let alpha = min(1, presence * twinkle * layer.alpha * 0.92 * (bright ? 1 : 0.85) * look.light * lift)
            let tone = Dice.roll(i, life, 11) < 0.5 ? 0 : 1
            let point = CGPoint(x: x, y: y)

            let colour = tone == 0 ? warm : cool
            if bright || flare > 0.05 || swell > 0.05 {
                halo(&context, at: point, radius: radius, colour: colour,
                     alpha: bright ? alpha : alpha * max(flare, swell))
            }
            dot(&context, at: point, radius: radius, colour: colour, alpha: alpha)
        }

        drawConstellation(in: &context, size: size, time: time, offset: offset, look: look)
    }

    // MARK: Flares

    /// A star that brightens for a few seconds and settles again.
    ///
    /// One every seven seconds, picked at random from the whole sky, so it can be any of
    /// them — far, near, bright or faint — and it is the star itself doing it, where it was.
    /// Up in a second, back down over two. Not every one is seen: a star that happens to be
    /// between lives when its turn comes stays dark, which keeps the rhythm from being one.
    private static let flareSlot = 7.0

    private static func flares(at time: Double) -> [(star: Int, amount: Double)] {
        let k = Int((time / flareSlot).rounded(.down))
        // This slot's and the last one's, which may still be fading.
        return [k - 1, k].compactMap { slot in
            let start = Double(slot) * flareSlot + 3 * Dice.roll(slot, 3, 61)
            let t = time - start
            guard t >= 0, t < 3.4 else { return nil }
            let amount = smooth(t / 1.0) * (1 - smooth((t - 1.2) / 2.2))
            let star = min(count - 1, Int(Dice.roll(slot, 3, 62) * Double(count)))
            return (star, amount)
        }
    }

    // MARK: Constellations

    /// A real constellation, simplified: where each star sits in a unit box, how bright it is
    /// (nought the brightest), which ones are joined, and how tall it is for its width.
    private struct Figure {
        let stars: [(x: Double, y: Double, magnitude: Int)]
        let lines: [(Int, Int)]
        let ratio: Double
    }

    private static let figures: [Figure] = [
        // Orion
        Figure(stars: [(0.18, 0.12, 0), (0.8, 0.2, 1), (0.5, 0, 2), (0.37, 0.52, 1), (0.5, 0.49, 1),
                       (0.63, 0.46, 1), (0.27, 0.96, 2), (0.86, 0.9, 0)],
               lines: [(0, 2), (2, 1), (0, 3), (1, 5), (3, 4), (4, 5), (3, 6), (5, 7)], ratio: 1.35),
        // Cassiopeia
        Figure(stars: [(0, 0.25, 1), (0.24, 0.86, 1), (0.48, 0.45, 1), (0.74, 0.95, 2), (1, 0.1, 2)],
               lines: [(0, 1), (1, 2), (2, 3), (3, 4)], ratio: 0.5),
        // The Great Bear
        Figure(stars: [(0, 0.55, 1), (0.2, 0.3, 1), (0.38, 0.22, 1), (0.56, 0.3, 2), (0.6, 0.72, 1),
                       (0.92, 0.86, 1), (0.98, 0.36, 0)],
               lines: [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 3)], ratio: 0.5),
        // The Swan
        Figure(stars: [(0.55, 0, 0), (0.5, 0.38, 1), (0.45, 0.63, 3), (0.36, 1, 1), (0.04, 0.3, 2),
                       (0.26, 0.34, 3), (0.77, 0.5, 3), (0.98, 0.63, 2)],
               lines: [(0, 1), (1, 2), (2, 3), (4, 5), (5, 1), (1, 6), (6, 7)], ratio: 1),
        // The Lyre
        Figure(stars: [(0.25, 0, 0), (0.45, 0.28, 2), (0.72, 0.35, 2), (0.62, 0.95, 2), (0.36, 0.88, 2),
                       (0.1, 0.18, 3)],
               lines: [(0, 1), (1, 2), (2, 3), (3, 4), (4, 1), (0, 5)], ratio: 1.1),
        // The Lion
        Figure(stars: [(0.18, 0.86, 0), (0.2, 0.56, 2), (0.28, 0.36, 1), (0.34, 0.13, 2), (0.2, 0.05, 3),
                       (0.07, 0.13, 2), (0.68, 0.3, 2), (0.72, 0.63, 2), (1, 0.55, 1)],
               lines: [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (2, 6), (6, 8), (8, 7), (7, 0)], ratio: 0.6),
    ]

    /// One every forty seconds, somewhere in the first half of that time. The longest takes
    /// under sixteen seconds from first light to gone, so two never overlap.
    private static let slot = 40.0

    /// Which one a slot shows: never the same one twice running.
    private static func figure(for slot: Int) -> Int {
        func raw(_ k: Int) -> Int { min(figures.count - 1, Int(Dice.roll(k, 1, 21) * Double(figures.count))) }
        let now = raw(slot)
        return now == raw(slot - 1) ? (now + 1) % figures.count : now
    }

    private static func drawConstellation(
        in context: inout GraphicsContext, size: CGSize, time: Double, offset: Double, look: SkyLook
    ) {
        let k = Int((time / slot).rounded(.down))
        let start = Double(k) * slot + 2 + 18 * Dice.roll(k, 1, 20)
        let t = time - start
        let figure = figures[figure(for: k)]

        // First the stars, then the lines one after another, a moment to look, and away.
        let lineStart = 1.2, step = 0.55
        let fadeFrom = lineStart + Double(figure.lines.count) * step + 6.5
        guard t >= 0, t < fadeFrom + 3 else { return }

        let scale = size.width / 340
        let width = ((figure.ratio > 1 ? 96 : 128) + 34 * Dice.roll(k, 1, 22)) * scale
        let height = width * figure.ratio
        let layer = SkyLayer.all[1]
        let x = 24 + Dice.roll(k, 1, 23) * max(1, size.width - width - 48) + layer.drift.dx * t
        let y0 = size.height * 0.2 + Dice.roll(k, 1, 24) * max(1, size.height * 0.5 - height)
        // Wrapped as a whole, with room enough that the jump from top to bottom happens out
        // of sight. Wrapping star by star would tear it in half at the edge.
        let margin = height + 30
        let y = wrap(y0 + layer.drift.dy * t - offset * layer.depth + margin, size.height + margin * 2) - margin

        let out = 1 - smooth((t - fadeFrom) / 3)
        let presence = smooth(t / 1.8) * out
        let points = figure.stars.map { CGPoint(x: x + $0.x * width, y: y + $0.y * height) }

        // Each line stops just short of the stars it joins, so a star stays a point of light
        // rather than a knot in a wire.
        let gap = 3.0
        for (n, line) in figure.lines.enumerated() {
            let drawn = smooth((t - lineStart - Double(n) * step) / step)
            guard drawn > 0 else { continue }
            let a = points[line.0], b = points[line.1]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > gap * 2 + 1 else { continue }
            let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
            let from = CGPoint(x: a.x + ux * gap, y: a.y + uy * gap)
            let reach = (length - gap * 2) * drawn
            var path = Path()
            path.move(to: from)
            path.addLine(to: CGPoint(x: from.x + ux * reach, y: from.y + uy * reach))
            context.stroke(path, with: .color(look.colour.light.opacity(min(0.8, 0.36 * out * look.light))),
                           style: StrokeStyle(lineWidth: 0.85, lineCap: .round))
        }

        let radii = [1.7, 1.45, 1.15, 0.9], alphas = [1, 0.95, 0.8, 0.62]
        for (point, star) in zip(points, figure.stars) {
            let alpha = min(1, alphas[star.magnitude] * 0.92 * presence * look.light)
            if star.magnitude == 0 { halo(&context, at: point, radius: radii[0], colour: warm, alpha: alpha) }
            dot(&context, at: point, radius: radii[star.magnitude], colour: warm, alpha: alpha)
        }
    }
}

// MARK: - Day

enum DaySky {
    /// Where the sun is and what colour its light is.
    ///
    /// Positions as shares of the screen from its top left: below nought is above the screen,
    /// beyond one past its edge. The sun never stands on the screen itself — a disc in the
    /// middle of a chat list is a sticker, the light coming from somewhere is a mood.
    struct Sun {
        var x: Double
        var y: Double
        var colour: (r: Double, g: Double, b: Double)
        var strength: Double

        var light: Color { rgb(colour.r, colour.g, colour.b) }
    }

    /// Through the day, as it goes in the Netherlands in autumn: up at half past seven, down at
    /// a quarter past seven. Near enough all year round for a light you only half notice.
    private static let day: [(hour: Double, sun: Sun)] = [
        (0, Sun(x: 0.5, y: -0.9, colour: (200, 206, 236), strength: 0.22)),
        (5.5, Sun(x: -0.1, y: 0.3, colour: (206, 200, 236), strength: 0.32)),
        (7.5, Sun(x: -0.18, y: 0.1, colour: (255, 188, 162), strength: 0.8)),
        (9.5, Sun(x: 0.1, y: -0.12, colour: (255, 220, 180), strength: 0.62)),
        (13.5, Sun(x: 0.55, y: -0.38, colour: (255, 242, 210), strength: 0.55)),
        (17, Sun(x: 0.95, y: -0.12, colour: (255, 212, 158), strength: 0.62)),
        (19.25, Sun(x: 1.18, y: 0.1, colour: (255, 174, 118), strength: 0.82)),
        (21, Sun(x: 1.1, y: 0.3, colour: (202, 198, 236), strength: 0.32)),
        (24, Sun(x: 0.5, y: -0.9, colour: (200, 206, 236), strength: 0.22)),
    ]

    static func sun(at date: Date, look: SkyLook) -> Sun {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600

        var i = 0
        while i < day.count - 2, hour >= day[i + 1].hour { i += 1 }
        let a = day[i], b = day[i + 1]
        let f = smooth((hour - a.hour) / (b.hour - a.hour))
        func mix(_ p: Double, _ q: Double) -> Double { p + (q - p) * f }

        // Leant a quarter of the way to the chosen colour. Any more and it stops being the
        // sun: the time of day is what its colour is for.
        let lean = look.colour.wash.resolve(in: EnvironmentValues())
        func toward(_ own: Double, _ other: Float) -> Double { own + (Double(other) * 255 - own) * 0.25 }

        return Sun(
            x: mix(a.sun.x, b.sun.x), y: mix(a.sun.y, b.sun.y),
            colour: (toward(mix(a.sun.colour.r, b.sun.colour.r), lean.red),
                     toward(mix(a.sun.colour.g, b.sun.colour.g), lean.green),
                     toward(mix(a.sun.colour.b, b.sun.colour.b), lean.blue)),
            strength: mix(a.sun.strength, b.sun.strength)
        )
    }

    /// White, warmed where the sun is.
    static func field(in context: inout GraphicsContext, size: CGSize, sun: Sun, look: SkyLook) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [rgb(255, 254, 252), .white]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
        ))

        glow(in: &context, centre: CGPoint(x: sun.x * size.width, y: sun.y * size.height),
             radii: CGSize(width: size.width * 1.5, height: size.height * 0.95),
             stops: [(sun.light, min(1, sun.strength * 0.55 * look.haze), 0),
                     (sun.light, min(1, sun.strength * 0.18 * look.haze), 0.38),
                     (sun.light, 0, 0.72)])
    }

    // MARK: Rays

    /// A broad, soft beam fanning out from the sun.
    private struct Ray {
        /// Where it points, relative to the middle of the screen as seen from the sun.
        let bearing: Double
        let halfWidth: Double
        let strength: Double
        /// How long a slow sway and a slow coming and going take, in seconds. Primes, so the
        /// seven never fall into step.
        let sway: Double
        let breathe: Double
        let phase: Double
        let breathePhase: Double
    }

    private static let rays: [Ray] = [-0.52, -0.36, -0.2, -0.05, 0.1, 0.26, 0.42].enumerated().map { i, bearing in
        Ray(
            bearing: bearing,
            halfWidth: 0.02 + 0.028 * Dice.roll(i, 0, 31),
            strength: 0.08 + 0.06 * Dice.roll(i, 0, 32),
            sway: [37, 41, 43, 47, 53, 59, 61][i],
            breathe: [23, 29, 31, 37, 41, 43, 47][i],
            phase: 2 * .pi * Dice.roll(i, 0, 33),
            breathePhase: 2 * .pi * Dice.roll(i, 0, 34)
        )
    }

    /// Now and then one ray fills out for a few seconds and settles again: the day's answer to
    /// a constellation. One every forty-five seconds.
    private static let beamSlot = 45.0

    private static func boost(for index: Int, at time: Double) -> Double {
        let k = Int((time / beamSlot).rounded(.down))
        guard min(rays.count - 1, Int(Dice.roll(k, 2, 35) * Double(rays.count))) == index else { return 1 }
        let t = time - (Double(k) * beamSlot + 5 + 25 * Dice.roll(k, 2, 36))
        guard t >= 0, t < 11 else { return 1 }
        return 1 + 1.4 * smooth(t / 3) * (1 - smooth((t - 7) / 4))
    }

    // MARK: Dust

    private struct Mote {
        let cycle: Double
        let shift: Double
    }

    private static let moteCount = 80

    private static let motes: [Mote] = (0..<moteCount).map { i in
        Mote(cycle: 14 + 22 * Dice.roll(i, 0, 41), shift: 1000 * Dice.roll(i, 0, 42))
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, time: Double, offset: Double, sun: Sun, look: SkyLook) {
        let source = CGPoint(x: sun.x * size.width, y: sun.y * size.height)
        let toward = atan2(size.height * 0.62 - source.y, size.width * 0.5 - source.x)
        let length = hypot(size.width, size.height) * 1.6

        // The rays as they are now: pointing, width and strength.
        let now = rays.enumerated().map { i, ray -> (angle: Double, halfWidth: Double, strength: Double) in
            let angle = toward + ray.bearing + 0.03 * sin(2 * .pi * time / ray.sway + ray.phase)
            let breath = (sin(2 * .pi * time / ray.breathe + ray.breathePhase) + 1) / 2
            let strength = ray.strength * (0.3 + 0.7 * breath * breath) * sun.strength * boost(for: i, at: time) * look.light
            return (angle, ray.halfWidth, strength)
        }

        for ray in now {
            var beam = Path()
            beam.move(to: source)
            beam.addLine(to: CGPoint(x: source.x + cos(ray.angle - ray.halfWidth) * length,
                                     y: source.y + sin(ray.angle - ray.halfWidth) * length))
            beam.addLine(to: CGPoint(x: source.x + cos(ray.angle + ray.halfWidth) * length,
                                     y: source.y + sin(ray.angle + ray.halfWidth) * length))
            beam.closeSubpath()
            context.fill(beam, with: .linearGradient(
                Gradient(stops: [
                    .init(color: sun.light.opacity(ray.strength), location: 0),
                    .init(color: sun.light.opacity(ray.strength * 0.55), location: 0.45),
                    .init(color: sun.light.opacity(0), location: 1),
                ]),
                startPoint: source,
                endPoint: CGPoint(x: source.x + cos(ray.angle) * length, y: source.y + sin(ray.angle) * length)
            ))
        }

        // Dust: all but invisible in the shade, catching the light where a ray passes through
        // it, the way it does in a sunny room. Darker than the light it is in — a white speck
        // on a white page is nothing at all.
        let ink = rgb(sun.colour.r * 0.66, sun.colour.g * 0.56, sun.colour.b * 0.36)
        let span = CGSize(width: size.width + 40, height: size.height + 40)
        let layerAlpha = [0.45, 0.7, 0.85]

        for (i, mote) in motes.enumerated() {
            let clock = time + mote.shift
            let generation = (clock / mote.cycle).rounded(.down)
            let age = clock - generation * mote.cycle
            let life = Int(generation)

            let fade = 3 + 3 * Dice.roll(i, life, 43)
            let presence = smooth(age / fade) * smooth((mote.cycle - age) / fade)
            guard presence > 0 else { continue }

            let pick = Dice.roll(i, life, 44)
            let layer = pick < 0.5 ? 0 : pick < 0.82 ? 1 : 2
            let pace = Double(layer + 1) * 0.6
            let drift = CGVector(dx: (0.12 + 0.3 * Dice.roll(i, life, 45)) * pace,
                                 dy: -(0.1 + 0.35 * Dice.roll(i, life, 46)) * pace)
            let wobble = sin(2 * .pi * time / (6 + 9 * Dice.roll(i, life, 47)) + 6 * Dice.roll(i, life, 48))
                * (2 + 5 * Dice.roll(i, life, 49))

            let x = wrap(Dice.roll(i, life, 50) * span.width + drift.dx * age + wobble + 20, span.width) - 20
            let y = wrap(Dice.roll(i, life, 51) * span.height + drift.dy * age
                         - offset * SkyLayer.all[layer].depth + 20, span.height) - 20

            let bearing = atan2(y - source.y, x - source.x)
            var lit = 0.0
            for ray in now {
                let off = abs(wrap(bearing - ray.angle + .pi, 2 * .pi) - .pi)
                lit += ray.strength / 0.1 * max(0, 1 - off / (ray.halfWidth * 1.3))
            }

            let alpha = min(1, presence * (0.08 + 0.92 * min(1, lit)) * layerAlpha[layer] * 0.62 * look.light)
            let radius = [0.55, 0.85, 1.3][layer] * (0.8 + 0.5 * Dice.roll(i, life, 52))
            dot(&context, at: CGPoint(x: x, y: y), radius: radius, colour: ink, alpha: alpha)
        }
    }
}

/// A soft, oval pool of colour: the sun's warmth by day, the blue across the middle at night.
///
/// Oval because a screen is tall and a round glow on it is a spotlight. Drawn as a circle in a
/// squashed space, which is the only way to get an oval gradient out of a canvas.
private func glow(
    in context: inout GraphicsContext, centre: CGPoint, radii: CGSize,
    stops: [(colour: Color, alpha: Double, at: Double)]
) {
    var oval = context
    oval.translateBy(x: centre.x, y: centre.y)
    oval.scaleBy(x: radii.width / radii.height, y: 1)
    let r = radii.height
    oval.fill(
        Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)),
        with: .radialGradient(
            Gradient(stops: stops.map { .init(color: $0.colour.opacity($0.alpha), location: $0.at) }),
            center: .zero, startRadius: 0, endRadius: r
        )
    )
}

#Preview("Night") {
    Sky(depth: SkyDepth())
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
}

#Preview("Day") {
    Sky(depth: SkyDepth())
        .ignoresSafeArea()
        .preferredColorScheme(.light)
}
