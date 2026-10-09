#if DEBUG
import SwiftUI
import UIKit

/// Notes the moment a finger lands, without taking the touch away from anything.
///
/// Every SwiftUI way of doing this gets in the way of the thing it is timing: a
/// `DragGesture(minimumDistance: 0)` laid over a row stopped the row opening at all, which is
/// a measurement that changes what it measures. A UIKit recogniser can be told not to: it
/// does not cancel touches in the view, does not delay them, and agrees to run alongside
/// every other recogniser. So the tap still goes where it was going, and the clock starts.
///
/// Debug only, and there to answer one question — how much of "it takes a moment to open"
/// happens before anything has been asked to open.
struct TouchClock: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false

        let recogniser = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.touched)
        )
        recogniser.minimumPressDuration = 0
        recogniser.cancelsTouchesInView = false
        recogniser.delaysTouchesBegan = false
        recogniser.delaysTouchesEnded = false
        recogniser.delegate = context.coordinator

        // On the window, not on this view: this one is a point of clear colour behind the
        // list, and the touches happen on the rows above it.
        DispatchQueue.main.async {
            view.window?.addGestureRecognizer(recogniser)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        @objc func touched(_ recogniser: UIGestureRecognizer) {
            switch recogniser.state {
            case .began: OpenStopwatch.touched()
            case .ended, .cancelled: OpenStopwatch.lifted()
            default: break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
