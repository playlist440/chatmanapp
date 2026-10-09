import SwiftUI

/// Which typeface the words are set in.
///
/// Arial Nova is not among them, and can't be: iOS carries Arial, Arial Bold and Arial
/// Rounded, but no Nova and no Light weight of any of them. Shipping the font file instead
/// would need a licence from Monotype that a copy of Windows or Office doesn't grant — and
/// this app is meant to be given away, which is exactly the thing such a licence forbids.
///
/// What is here are faces iOS already has, so nothing is bundled and nothing is owed. The
/// two Helveticas are the closest in shape to what Arial Nova is: upright, open, no
/// mannerisms.
public enum Typeface: String, CaseIterable, Sendable {
    case system
    case systemLight

    /// Reads a choice saved by an older version, which offered Helvetica, Arial and Avenir too.
    /// Those went when the app moved to the system's text styles, where they no longer took
    /// effect; a light one becomes Light, the rest Standard.
    public init(stored: String?) {
        if let stored, let face = Typeface(rawValue: stored) {
            self = face
        } else if stored?.localizedCaseInsensitiveContains("light") == true {
            self = .systemLight
        } else {
            self = .system
        }
    }

    public var displayName: String {
        switch self {
        case .system: String(localized: "Standard", bundle: .module)
        case .systemLight: String(localized: "Light", bundle: .module)
        }
    }

    /// The weight for everything that doesn't ask for one of its own: names, messages, lines.
    public var weight: Font.Weight? {
        self == .systemLight ? .light : nil
    }

    public func font(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo style: Font.TextStyle = .body
    ) -> Font {
        // `Font.Weight` can't be compared, so the heavy cuts are named rather than measured.
        let isEmphasised = [.semibold, .bold, .heavy, .black].contains(weight)
        if self == .systemLight, !isEmphasised {
            return .system(size: size, weight: .light)
        }
        return .system(size: size, weight: weight)
    }
}

private struct TypefaceKey: EnvironmentKey {
    static let defaultValue: Typeface = .system
}

public extension EnvironmentValues {
    /// The typeface chosen in settings. Read by ``SwiftUI/View/chatmanFont(size:weight:relativeTo:)``.
    var chatmanTypeface: Typeface {
        get { self[TypefaceKey.self] }
        set { self[TypefaceKey.self] = newValue }
    }
}

public extension View {

    /// Sets text in whichever face was chosen, at the size given.
    func chatmanFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo style: Font.TextStyle = .body
    ) -> some View {
        modifier(ChatmanFont(size: size, weight: weight, style: style))
    }
}

private struct ChatmanFont: ViewModifier {
    @Environment(\.chatmanTypeface) private var typeface

    let size: CGFloat
    let weight: Font.Weight
    let style: Font.TextStyle

    func body(content: Content) -> some View {
        content.font(typeface.font(size: size, weight: weight, relativeTo: style))
    }
}
