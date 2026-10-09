#if canImport(UIKit)
import SwiftUI

public extension View {

    /// Glass, as far as the system wants it.
    ///
    /// Liquid Glass is a system-wide look with a system-wide dial, and this reads that dial
    /// rather than deciding for itself. Somebody who turned transparency down did so because
    /// text over a blurred background is hard for them to read — and a messaging app is
    /// nothing but text over backgrounds. So when that setting is on, the glass becomes a
    /// plain fill: same shape, same size, nothing showing through.
    ///
    /// Reduced motion is read too. The shimmer that follows a finger across a glass control
    /// is motion, and asking for less of it should mean less of it here as well.
    ///
    /// - Parameters:
    ///   - shape: What the glass is cut to.
    ///   - interactive: Whether it reacts to touch.
    ///   - tint: A colour to carry, for controls that are meant to stand out.
    func chatmanGlass(
        in shape: some Shape, interactive: Bool = false, tint: Color? = nil
    ) -> some View {
        modifier(ChatmanGlass(shape: shape, interactive: interactive, tint: tint))
    }
}

private struct ChatmanGlass<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Read so that switching between light and dark builds the glass again.
    ///
    /// Glass is drawn by the system into a layer of its own, and a layer with something
    /// endlessly animating inside it — a spinner, say — is not always redrawn when the
    /// appearance changes underneath it. Turning the app dark while the list was still
    /// fetching left the word "Chats" white on a black screen until the spinner finished and
    /// something else forced a redraw.
    ///
    /// Not reproducible in a simulator, which redraws more eagerly than a phone does. This is
    /// here because the failure is plain to see and the guard costs nothing: reading the value
    /// makes this a dependency, and the identity below makes the rebuild certain.
    @Environment(\.colorScheme) private var scheme

    let shape: S
    let interactive: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(solid, in: shape)
        } else {
            content.glassEffect(glass, in: shape).id(scheme)
        }
    }

    private var glass: Glass {
        // Regular, which is what the system's own bars use and what its Liquid Glass
        // setting acts on. `clear` was tried twice and is the wrong tool both times. Over a
        // chat header there is usually nothing behind it but a white screen, so the controls
        // refract away to nothing. And on the two large plates of the conversation list,
        // where there is plenty behind them, it simply goes too far: the chats sliding under
        // the pinned faces stop being a hint of movement and start being a second thing to
        // read. What reads as "milky" is glass over emptiness —
        // scroll a conversation up underneath it and it behaves like everywhere else.
        var glass = Glass.regular

        if let tint { glass = glass.tint(tint) }
        if interactive, !reduceMotion { glass = glass.interactive() }
        return glass
    }

    /// What stands in for glass when it isn't wanted: opaque, and still telling the two kinds
    /// of control apart by the same colour the glass would have carried.
    private var solid: AnyShapeStyle {
        if let tint { AnyShapeStyle(tint) }
        else { AnyShapeStyle(.fill.tertiary) }
    }
}
#endif
