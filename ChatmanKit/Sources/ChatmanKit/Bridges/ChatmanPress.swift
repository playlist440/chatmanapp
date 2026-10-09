import SwiftUI

/// A button that gives a little under the finger.
///
/// `.buttonStyle(.plain)` is what the app reaches for whenever a button has to look like
/// something other than a button — a face, a pill, a row. What `.plain` also takes away is any
/// sign that the tap landed, and on a face you are aiming at in a sideways-scrolling row that
/// is the difference between a button and a picture.
///
/// Scale and nothing else. A tint would fight the glass, and a glow would be a notification.
public struct ChatmanPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    /// How far it sinks. Small on purpose: you should feel it rather than watch it.
    private let scale: CGFloat

    public init(scale: CGFloat = 0.94) {
        self.scale = scale
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Faded when it can't be pressed, the way a system button is. A plain style
            // does this by itself; a style of our own has to be told, or a button that does
            // nothing looks exactly like one that does.
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            // Springy coming back, so letting go feels like letting go of something.
            .animation(.spring(response: 0.26, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == ChatmanPress {
    /// Plain, but it answers when you touch it.
    static var chatmanPress: ChatmanPress { ChatmanPress() }

    /// The same, for something large enough that a full sink would be a lurch.
    static var chatmanPressGently: ChatmanPress { ChatmanPress(scale: 0.97) }
}

/// A row that lights up the instant you touch it.
///
/// Not the same job as `ChatmanPress`. That one is for something shaped like a picture, where
/// a little give under the finger is the whole answer. A list row is wide and flat, and what
/// it owes you is the thing a system list does for free and a plain button does not: the
/// moment your finger lands, before anything has been asked to open, the row says it heard
/// you.
///
/// This matters more than it sounds. Whatever comes next takes as long as it takes; what
/// makes an app feel slow is a press that lands on nothing.
public struct ChatmanRowPress: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.09) : .clear)
            // Down at once, back gently. Fading in the highlight would put the delay back in
            // by the front door.
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.25),
                       value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == ChatmanRowPress {
    /// For a row in a list: it answers on touch, not on lift.
    static var chatmanRow: ChatmanRowPress { ChatmanRowPress() }
}

/// Modifiers that only matter once the screen is standing still.
///
/// A conversation cannot begin sliding in until it has been built, so everything built before
/// the first frame is time spent looking at the screen you are leaving. Measured on an opening
/// conversation: the long-press menus on eleven bubbles cost 28 ms and the field's photo,
/// file and camera pickers 59 ms — a fifth of the wait, for things that cannot be reached
/// until the wait is over.
///
/// So they are attached a moment later. Nothing is lost: a menu you cannot open yet and a
/// picker you cannot tap yet are not features, they are furniture being carried in.
public extension View {

    /// A long-press menu, once there is something to press.
    @ViewBuilder
    func chatmanMenu<Items: View>(
        _ isReady: Bool, @ViewBuilder items: () -> Items
    ) -> some View {
        // Always attached, with nothing in it until the screen has arrived. Adding the menu
        // when `isReady` turned true rebuilt every bubble at that moment, and a tap landing
        // then was lost.
        contextMenu { if isReady { items() } }
    }

    #if !os(watchOS)
    /// The same, with a preview of what is being pressed. No such thing on a watch.
    @ViewBuilder
    func chatmanMenu<Items: View, Preview: View>(
        _ isReady: Bool,
        @ViewBuilder items: () -> Items,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        contextMenu { if isReady { items() } } preview: { preview() }
    }
    #endif
}
