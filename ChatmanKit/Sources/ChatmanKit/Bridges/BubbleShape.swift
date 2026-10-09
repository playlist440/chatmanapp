import SwiftUI

/// A message bubble, with a tail on one bottom corner when it ends a run.
public struct BubbleShape: Shape {
    public var tail: HorizontalEdge?
    public var radius: CGFloat

    public init(tail: HorizontalEdge?, radius: CGFloat = 18) {
        self.tail = tail
        self.radius = radius
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        guard let tail else { return path }

        // A small curl off the bottom corner, drawn for the right-hand side and mirrored for
        // the left. It overlaps the corner so the two read as one shape.
        var curl = Path()
        let x = rect.maxX, y = rect.maxY
        curl.move(to: CGPoint(x: x - 14, y: y - 12))
        curl.addCurve(
            to: CGPoint(x: x + 5, y: y),
            control1: CGPoint(x: x - 10, y: y - 2),
            control2: CGPoint(x: x - 2, y: y + 1)
        )
        curl.addCurve(
            to: CGPoint(x: x - 18, y: y - 2),
            control1: CGPoint(x: x - 4, y: y + 2),
            control2: CGPoint(x: x - 12, y: y + 1)
        )
        curl.closeSubpath()

        if tail == .leading {
            curl = curl.applying(
                CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1)
            )
        }
        path.addPath(curl)
        return path
    }
}
