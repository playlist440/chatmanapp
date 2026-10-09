import SwiftUI

/// The colours of a monogram, steady for a name: the same person is the same colour on every
/// screen and every launch.
public enum Monogram {
    /// Soft, like the system's own: no colour so bright that a list of them shouts.
    private static let hues: [(Double, Double)] = [
        (0.58, 0.62), (0.53, 0.57), (0.75, 0.80), (0.87, 0.92), (0.02, 0.06),
        (0.08, 0.11), (0.35, 0.40), (0.46, 0.50), (0.65, 0.70)
    ]

    public static func gradient(for name: String) -> LinearGradient {
        // Not `hashValue`, which changes from one launch to the next.
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        let (top, bottom) = hues[sum % hues.count]
        return LinearGradient(
            colors: [
                Color(hue: top, saturation: 0.38, brightness: 0.86),
                Color(hue: bottom, saturation: 0.52, brightness: 0.66)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
