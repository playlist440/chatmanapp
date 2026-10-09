import SwiftUI

/// What colour the light behind the messages is.
///
/// The names are the colours of the light, not of the screen. In the dark every one of these
/// is a near-black field with something bright drawn over it: "yellow" is a dark room lit by
/// something yellow, and "white" is the same room lit by snow. In the light it turns round —
/// a white page with a breath of the colour across it, and the drawing done in ink.
public enum BackdropColour: String, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, pink, brown, white, black

    public var displayName: String {
        switch self {
        case .red: String(localized: "Red", bundle: .module)
        case .orange: String(localized: "Orange", bundle: .module)
        case .yellow: String(localized: "Yellow", bundle: .module)
        case .green: String(localized: "Green", bundle: .module)
        case .blue: String(localized: "Blue", bundle: .module)
        case .purple: String(localized: "Purple", bundle: .module)
        case .pink: String(localized: "Pink", bundle: .module)
        case .brown: String(localized: "Brown", bundle: .module)
        case .white: String(localized: "White", bundle: .module)
        case .black: String(localized: "Black", bundle: .module)
        }
    }

    /// What it is, in the words that were asked for.
    public var note: String {
        switch self {
        case .red: String(localized: "A warm and bold primary colour, like an apple", bundle: .module)
        case .orange: String(localized: "Red and yellow mixed, like a sunset", bundle: .module)
        case .yellow: String(localized: "A bright primary colour, like the sun", bundle: .module)
        case .green: String(localized: "A cool secondary colour, like grass and leaves", bundle: .module)
        case .blue: String(localized: "A primary colour, like a clear sky or the ocean", bundle: .module)
        case .purple: String(localized: "A secondary colour, like grapes", bundle: .module)
        case .pink: String(localized: "A light tint of red, like a flamingo", bundle: .module)
        case .brown: String(localized: "Earthy and natural, like wood or chocolate", bundle: .module)
        case .white: String(localized: "All visible light at once, like snow", bundle: .module)
        case .black: String(localized: "The absence of light, like the night sky", bundle: .module)
        }
    }

    /// The lit part of the field, where the filaments run.
    public var glow: Color {
        switch self {
        case .red: Self.tone(0x2A, 0x08, 0x0E)
        case .orange: Self.tone(0x24, 0x10, 0x04)
        case .yellow: Self.tone(0x1E, 0x19, 0x05)
        case .green: Self.tone(0x06, 0x1C, 0x0D)
        case .blue: Self.tone(0x06, 0x18, 0x30)
        case .purple: Self.tone(0x20, 0x0A, 0x28)
        case .pink: Self.tone(0x2A, 0x0B, 0x1A)
        case .brown: Self.tone(0x20, 0x15, 0x0B)
        case .white: Self.tone(0x14, 0x16, 0x1A)
        case .black: Self.tone(0x09, 0x09, 0x0C)
        }
    }

    /// The corners, where the light doesn't reach.
    public var edge: Color {
        switch self {
        case .red: Self.tone(0x0D, 0x03, 0x05)
        case .orange: Self.tone(0x0D, 0x06, 0x02)
        case .yellow: Self.tone(0x0B, 0x09, 0x02)
        case .green: Self.tone(0x02, 0x0A, 0x05)
        case .blue: Self.tone(0x02, 0x07, 0x12)
        case .purple: Self.tone(0x0A, 0x04, 0x0E)
        case .pink: Self.tone(0x0E, 0x04, 0x09)
        case .brown: Self.tone(0x0A, 0x07, 0x04)
        case .white: Self.tone(0x06, 0x07, 0x08)
        case .black: Self.tone(0x00, 0x00, 0x00)
        }
    }

    /// The filaments themselves, and the sparks along them.
    public var light: Color {
        switch self {
        case .red: Self.tone(0xFF, 0x7A, 0x7A)
        case .orange: Self.tone(0xFF, 0xAE, 0x66)
        case .yellow: Self.tone(0xFF, 0xE8, 0x8A)
        case .green: Self.tone(0x86, 0xE8, 0xA4)
        case .blue: Self.tone(0x8A, 0xC8, 0xFF)
        case .purple: Self.tone(0xCE, 0x9F, 0xFF)
        case .pink: Self.tone(0xFF, 0xA8, 0xCE)
        case .brown: Self.tone(0xE0, 0xBA, 0x8C)
        case .white: Self.tone(0xFF, 0xFF, 0xFF)
        case .black: Self.tone(0xD0, 0xD4, 0xDC)
        }
    }

    /// The drawing on a light page: strong enough to be seen on white, never a shout.
    ///
    /// Not `light` darkened. A yellow line on white is invisible at any brightness, so each
    /// one is the colour as it would be printed rather than as it would shine.
    public var ink: Color {
        switch self {
        case .red: Self.tone(0xC2, 0x3C, 0x3C)
        case .orange: Self.tone(0xC8, 0x6A, 0x1E)
        case .yellow: Self.tone(0xA8, 0x86, 0x10)
        case .green: Self.tone(0x2C, 0x8E, 0x55)
        case .blue: Self.tone(0x2C, 0x72, 0xC8)
        case .purple: Self.tone(0x80, 0x52, 0xC8)
        case .pink: Self.tone(0xC4, 0x50, 0x86)
        case .brown: Self.tone(0x86, 0x5E, 0x3E)
        case .white: Self.tone(0x80, 0x86, 0x90)
        case .black: Self.tone(0x2E, 0x31, 0x38)
        }
    }

    /// The breath of colour across a light page, where `glow` is the wash on a dark one.
    public var wash: Color {
        switch self {
        case .red: Self.tone(0xFF, 0xDC, 0xD8)
        case .orange: Self.tone(0xFF, 0xE4, 0xCC)
        case .yellow: Self.tone(0xFF, 0xF0, 0xC0)
        case .green: Self.tone(0xD8, 0xF2, 0xE0)
        case .blue: Self.tone(0xD6, 0xE8, 0xFF)
        case .purple: Self.tone(0xEA, 0xDE, 0xFF)
        case .pink: Self.tone(0xFF, 0xDE, 0xEC)
        case .brown: Self.tone(0xEE, 0xE2, 0xD2)
        case .white: Self.tone(0xF0, 0xF2, 0xF5)
        case .black: Self.tone(0xE4, 0xE5, 0xE8)
        }
    }

    private static func tone(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}
