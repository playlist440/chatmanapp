import Foundation

/// How much a photo taken in the app is squeezed before it goes out.
///
/// The camera hands back an uncompressed frame, which for a modern phone is a dozen megabytes
/// or more. Sending that over cellular to say "I'm here" is a poor trade, so it's encoded
/// first — but how far is a judgement about your connection and your patience, not something
/// an app should decide on your behalf and never mention.
public enum PhotoQuality: String, Sendable, CaseIterable, Identifiable {

    /// Ninety per cent: the point past which the file keeps growing and the picture doesn't
    /// visibly improve.
    case balanced

    /// No squeezing at all. Every pixel the camera saw, at several times the size.
    case maximum

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .balanced: String(localized: "Balanced", bundle: .module)
        case .maximum: String(localized: "Maximum", bundle: .module)
        }
    }

    public var explanation: String {
        switch self {
        case .balanced:
            String(localized: "Photos you take are around a megabyte. You won't see the difference; your data allowance will.", bundle: .module)
        case .maximum:
            String(localized: "Photos you take are sent uncompressed — often more than ten megabytes each. Worth it on wifi, painful on a train.", bundle: .module)
        }
    }

    /// What to hand `jpegData(compressionQuality:)`.
    public var compression: Double {
        switch self {
        case .balanced: 0.9
        case .maximum: 1
        }
    }
}
