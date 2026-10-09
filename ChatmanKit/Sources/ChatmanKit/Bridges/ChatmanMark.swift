#if canImport(UIKit)
import SwiftUI
import WidgetKit

/// Chatman's mark: two overlapping speech bubbles, with the waiting count inside the front one.
///
/// Follows the drawing made for the watch — the bubble behind sits up and to the right with its
/// tail on the other side, so the two read as two even where they overlap — but drawn rather
/// than loaded from the asset catalogue, for two reasons. A watch face renders everything in a
/// single tint, so a colourful picture arrives there as a grey smudge; and the number has to
/// sit *inside* the shape at whatever size the slot happens to be, which an image can't do.
///
/// The number is punched out of the bubble instead of drawn on top of it. That keeps it legible
/// however the system decides to tint the complication: whatever colour the bubble becomes, the
/// digits are the gap in it.
public struct ChatmanMark: View {

    /// How many conversations are waiting. Nothing is drawn inside when this is zero — the
    /// mark is still the mark, which is the point.
    private let count: Int

    public init(count: Int = 0) {
        self.count = count
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            // Everything is drawn inside a square well within the circle the watch face cuts
            // this to. The corners of a full-width square fall outside that circle, which is
            // where the second bubble used to go — and why it arrived on the face as a sliver
            // with its top sliced off.
            let content = side * 0.80
            let front = content * 0.78
            let back = content * 0.60
            // A deeper overlap than the drawing has, because at this size the gap between
            // two bubbles is worth more than the space between them.
            let gap = content * 0.055

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    SpeechBubble(tail: .trailing)
                        .fill(.primary)
                        .frame(width: back, height: back)
                        .offset(x: content - back, y: 0)

                    // The front bubble's own outline, slightly fattened and punched straight
                    // through the one behind it.
                    SpeechBubble(tail: .leading)
                        .fill(.black)
                        .frame(width: front + gap * 2, height: front + gap * 2)
                        .offset(x: -gap, y: content - front - gap)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .opacity(0.55)
                // Yellow behind, white in front, on the faces that have a colour to give.
                .widgetAccentable()

                SpeechBubble(tail: .leading)
                    .fill(.primary)
                    .frame(width: front, height: front)
                    .overlay(alignment: .center) {
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: front * 0.5, weight: .bold, design: .rounded))
                                .minimumScaleFactor(0.4)
                                .lineLimit(1)
                                .padding(.horizontal, front * 0.08)
                                // Knocked out, so the digits are the hole in the bubble.
                                .blendMode(.destinationOut)
                                .offset(y: -front * 0.07)
                        }
                    }
                    .compositingGroup()
                    .offset(x: 0, y: content - front)
            }
            .frame(width: content, height: content)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A rounded speech bubble with a tail at one of its bottom corners.
struct SpeechBubble: Shape {

    /// Which side the tail hangs from. The two bubbles point away from each other, the way
    /// they do in the drawing.
    var tail: HorizontalEdge = .leading

    func path(in rect: CGRect) -> Path {
        // The tail lives in the bottom fifth, so the body keeps its own proportions whatever
        // the slot is.
        let body = CGRect(
            x: rect.minX, y: rect.minY,
            width: rect.width, height: rect.height * 0.82
        )
        let radius = min(body.width, body.height) * 0.3

        var path = Path()
        path.addRoundedRect(in: body, cornerSize: CGSize(width: radius, height: radius))

        let near: CGFloat = tail == .leading ? 0.24 : 0.76
        let tip: CGFloat = tail == .leading ? 0.13 : 0.87
        let far: CGFloat = tail == .leading ? 0.52 : 0.48

        path.move(to: CGPoint(x: body.minX + body.width * near, y: body.maxY - radius * 0.2))
        path.addLine(to: CGPoint(x: body.minX + body.width * tip, y: rect.maxY))
        path.addLine(to: CGPoint(x: body.minX + body.width * far, y: body.maxY - radius * 0.2))
        path.closeSubpath()

        return path
    }
}
#endif
