import SwiftUI
import ChatmanKit

/// What the app is drawn on, as chosen in the settings: nothing, the filaments, the stars or
/// the ribbon — in light or in dark, in the chosen colour.
///
/// The list and every conversation put this behind themselves, so opening a chat is going
/// further into the same place rather than into another one. Each of the three keeps the
/// same clock (see `BackdropClock`), so the picture a conversation opens on is the picture
/// the list was showing at that moment.
struct Backdrop: View {
    @Environment(ChatSession.self) private var session

    /// How far the screen in front has scrolled, read while drawing and never observed.
    let depth: SkyDepth

    /// Whether the screen in front is being scrolled, so what follows it can keep up.
    var isScrolling = false

    /// Whether something else is on top, so there is nobody to draw for.
    var isCovered = false

    var body: some View {
        BackdropPicture(
            style: session.backdrop,
            colour: session.backdropColour,
            presence: session.backdropPresence,
            glow: session.backdropGlow,
            veil: session.backdropVeil,
            blur: session.backdropBlur,
            depth: depth,
            isScrolling: isScrolling,
            isCovered: isCovered
        )
    }
}

/// One backdrop, drawn from what it is given rather than from the settings — so the settings
/// can show the one being chosen, as it is being chosen.
struct BackdropPicture: View {
    let style: BackdropStyle
    let colour: BackdropColour
    let presence: Double
    let glow: Double
    var veil: Double = 0.35
    var blur: Double = 0.2
    let depth: SkyDepth
    var isScrolling = false
    var isCovered = false

    var body: some View {
        Group {
            switch style {
            case .none:
                Color(.systemBackground)
            case .filaments:
                Filaments(colour: colour, presence: presence, glow: glow, isHeldStill: isCovered)
            case .stars:
                Sky(
                    depth: depth, colour: colour, presence: presence, glow: glow,
                    isScrolling: isScrolling, isCovered: isCovered
                )
            case .ribbon:
                Ribbon(
                    depth: depth, colour: colour, presence: presence, glow: glow,
                    isScrolling: isScrolling, isCovered: isCovered
                )
            case .photo:
                PhotoBackdrop(veil: veil, blur: blur)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The time every backdrop runs on: the wall clock, less the time the app was away.
///
/// Shared, so the list and a conversation opened from it are drawn at the same moment and
/// show the same picture. And with the time away taken out, so coming back to the app after
/// an hour carries on from where it was rather than leaping an hour's worth of drift in the
/// one frame you are looking straight at.
@MainActor
enum BackdropClock {
    private static var away: TimeInterval = 0
    private static var leftAt: Date?

    /// Seconds on the backdrops' own clock at a moment on the wall clock.
    ///
    /// Stopped where it was while the app is away. Coming back, a backdrop can draw before
    /// the app has said it is back, and without this that one frame would leap ahead by the
    /// whole time away and then jump back.
    static func seconds(at date: Date) -> TimeInterval {
        (leftAt ?? date).timeIntervalSinceReferenceDate - away
    }

    /// The app has gone to the background.
    static func pause() {
        if leftAt == nil { leftAt = .now }
    }

    /// And it is back.
    static func resume() {
        guard let leftAt else { return }
        away += Date.now.timeIntervalSince(leftAt)
        self.leftAt = nil
    }
}

/// A band of fine lines twisting slowly down the screen, glowing where it turns edge-on,
/// with dust coming off its sides.
///
/// Drawn on the graphics chip, by `Ribbon.metal`, one pixel at a time. Eighty-four lines the
/// height of the screen and a few hundred specks of dust would be thousands of strokes a frame
/// in a canvas — work for the processor, on the same thread that has to keep a list
/// scrolling. In a shader each pixel answers for itself in a handful of sums, which the
/// graphics chip does for a whole screen in a fraction of a millisecond; what is left for the
/// processor is handing over a few numbers, as often as the picture moves.
///
/// Light and dark are the same drawing turned round: light lines and dust on a dark page, or
/// ink on a white one. The colour chosen in the settings is the light where the band turns
/// and the wash across the page; the lines themselves stay neutral, the way the reference
/// has them, so the colour reads as light falling on them rather than as paint.
struct Ribbon: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let depth: SkyDepth
    let colour: BackdropColour
    let presence: Double
    let glow: Double
    var isScrolling = false
    var isCovered = false

    /// Drawings per second. Twenty at rest, where the quickest part moves under a point a
    /// second; as often as the screen while scrolling, where it follows the list.
    private var rate: Double {
        // Smooth enough to follow a thumb; 120 cost a frame's worth of work on every
        // tick while the list was trying to keep up with the finger.
        if isScrolling { return 60 }
        // At rest the motion is slow enough that ten frames a second can't be told from
        // twenty, and it is half the work for as long as the screen is open.
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? 6 : 10
    }

    private var isStill: Bool {
        reduceMotion || isCovered || scenePhase != .active
    }

    /// The four slow movements, in seconds for one full turn. Primes, so the shape only comes
    /// back when all four do — which is never, for anybody looking. Slow enough that you see
    /// it has moved rather than watch it move: twice as fast as this, it drew the eye away
    /// from whatever was written over it.
    private static let periods: (Double, Double, Double, Double) = (157, 101, 137, 211)

    var body: some View {
        let dark = scheme == .dark

        TimelineView(.animation(minimumInterval: 1 / rate, paused: isStill)) { timeline in
            let seconds = BackdropClock.seconds(at: timeline.date)
            let phase = SIMD4<Float>(
                Float(Self.turn(seconds, Self.periods.0)),
                Float(Self.turn(seconds, Self.periods.1)),
                Float(Self.turn(seconds, Self.periods.2)),
                Float(Self.turn(seconds, Self.periods.3))
            )
            let specks = SIMD2<Float>(
                // The dust drifts down three and a half points a second, wrapped at the seven
                // thousand points its pattern repeats over. See `Ribbon.metal`.
                Float((seconds * 3.5).truncatingRemainder(dividingBy: 7000)),
                // And twinkles on a clock that goes round once an hour.
                Float(Self.turn(seconds, 3600))
            )
            let scrolled = Float(depth.offset)
            let colours = (
                ground: dark ? Color.black : Color.white,
                wash: dark ? colour.glow : colour.wash,
                ink: dark ? Color(white: 0.9) : Color(white: 0.32),
                accent: dark ? colour.light : colour.ink
            )
            let amounts = SIMD3<Float>(Float(presence), Float(glow), dark ? 1 : 0)

            Rectangle()
                .fill(colours.ground)
                .visualEffect { content, proxy in
                    content.colorEffect(ShaderLibrary.ribbon(
                        .float2(proxy.size),
                        .float4(phase.x, phase.y, phase.z, phase.w),
                        .float2(specks.x, specks.y),
                        .float(scrolled),
                        .color(colours.ground),
                        .color(colours.wash),
                        .color(colours.ink),
                        .color(colours.accent),
                        .float3(amounts.x, amounts.y, amounts.z)
                    ))
                }
        }
    }

    /// How far round a clock of this many seconds has gone, from nought to one.
    private static func turn(_ seconds: Double, _ period: Double) -> Double {
        let turns = seconds / period
        return turns - turns.rounded(.down)
    }
}

#Preview("Ribbon, dark") {
    Ribbon(depth: SkyDepth(), colour: .yellow, presence: 0.6, glow: 0.6)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
}

#Preview("Ribbon, light") {
    Ribbon(depth: SkyDepth(), colour: .yellow, presence: 0.6, glow: 0.6)
        .ignoresSafeArea()
        .preferredColorScheme(.light)
}
