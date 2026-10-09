import Foundation

/// What the app is drawn on: the chat list and every conversation alike.
///
/// One choice for the whole app. It used to be two — a sky under the list, and a switch for
/// the filaments under conversations only — which made opening a chat a step into another
/// room rather than further into the same one.
///
/// Every one of them has a light and a dark version, and the colour, the light and the glow
/// in the settings apply to whichever is chosen.
public enum BackdropStyle: String, CaseIterable, Sendable {
    /// The system's own white or black.
    case none
    /// Strands of light drifting across the middle.
    case filaments
    /// A night sky with constellations; by day, the sun.
    case stars
    /// A band of fine lines twisting down the screen, with dust coming off it.
    case ribbon
    /// A picture of your own, from your photo library. It stays on this phone.
    case photo

    public var displayName: String {
        switch self {
        case .none: String(localized: "None", bundle: .module)
        case .filaments: String(localized: "Filaments", bundle: .module)
        case .stars: String(localized: "Stars", bundle: .module)
        case .ribbon: String(localized: "Ribbon", bundle: .module)
        case .photo: String(localized: "Photo", bundle: .module)
        }
    }

    /// Whether the colour and the two dials for drawn light apply. A photo has its own.
    public var isDrawn: Bool {
        switch self {
        case .filaments, .stars, .ribbon: true
        case .none, .photo: false
        }
    }

    /// What the light dial turns up, in the words of what is being drawn.
    public var lightName: String {
        switch self {
        case .none: String(localized: "Light", bundle: .module)
        case .filaments: String(localized: "Filaments", bundle: .module)
        case .stars: String(localized: "Stars", bundle: .module)
        case .ribbon: String(localized: "Lines", bundle: .module)
        case .photo: String(localized: "Light", bundle: .module)
        }
    }

    /// What it is, in a few words, for the line under its name.
    public var summary: String {
        switch self {
        case .none: String(localized: "The phone's own white or black", bundle: .module)
        case .filaments: String(localized: "Strands of light drifting across", bundle: .module)
        case .stars: String(localized: "A night sky, and by day the sun", bundle: .module)
        case .ribbon: String(localized: "Fine lines twisting, lit where they turn", bundle: .module)
        case .photo: String(localized: "A picture of your own", bundle: .module)
        }
    }

    /// What it is, in light and in dark.
    public var note: String {
        switch self {
        case .none:
            String(localized: "Plain white or black, whatever the phone is set to.", bundle: .module)
        case .filaments:
            String(localized: "Strands of light drifting slowly across the middle of the screen.", bundle: .module)
        case .stars:
            String(localized: "A night sky where stars come and go, flare and fade, and now and then a constellation draws itself. By day, the light of a sun that keeps the time.", bundle: .module)
        case .ribbon:
            String(localized: "A band of fine lines twisting slowly down the screen, glowing where it turns, with dust coming off its edges.", bundle: .module)
        case .photo:
            String(localized: "A picture of your own. It stays on this phone and goes nowhere else; the veil keeps the words over it readable.", bundle: .module)
        }
    }
}
