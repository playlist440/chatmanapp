#if canImport(UIKit)
import SwiftUI

/// Reactions, sitting on the corner of the message they belong to.
///
/// On a small badge of material over the corner, the way Messages draws them. Bare, they sat
/// straight on a photo and covered part of it, or vanished against a busy picture.
///
/// Shared between the phone and the watch so the two can't drift. Only the size differs, and
/// only because the screens do.
public struct Tapbacks: View {
    private let reactions: [String: Int]
    private let size: CGFloat

    public init(reactions: [String: Int], size: CGFloat = 26) {
        self.reactions = reactions
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(reactions.sorted(by: { $0.key < $1.key }), id: \.key) { emoji, count in
                HStack(spacing: 1) {
                    Text(emoji)
                        .font(.system(size: size * 0.7))

                    // Only when more than one person said it. A "1" beside every reaction is
                    // a number that never tells you anything.
                    if count > 1 {
                        Text("\(count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, size * 0.3)
        .frame(minWidth: size * 1.25, minHeight: size * 1.25)
        // On a badge of its own, as in Messages: a small rounded plate that sits over the
        // corner of the bubble and keeps the emoji off whatever the bubble holds.
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(.background, lineWidth: 2) }
        .accessibilityElement(children: .combine)
    }
}
#endif
