#if os(watchOS)
import Foundation
import WatchKit

/// Keeps the number on the watch face honest while the app isn't running.
///
/// There is no push here. A free developer account gets no notification certificate, so
/// nothing arrives on its own and the count would otherwise be as old as the last time the
/// app was opened — which, for something you glance at to decide whether to open the app at
/// all, makes it worse than useless.
///
/// What watchOS does give is background refresh: a complication on the active face earns the
/// app a handful of short wake-ups an hour. Each one is a few seconds — enough for one sync
/// that returns immediately, and a redraw.
@MainActor
public enum BackgroundRefresh {

    /// Matched against the identifier SwiftUI's `backgroundTask(.appRefresh:)` waits on.
    public static let identifier = "chatman.unread"

    /// Asks for the next wake-up.
    ///
    /// The date is a request, not a promise: watchOS decides when, and how often, based on
    /// how much the app is used and what else the watch is doing. Asking for fifteen minutes
    /// is asking for the most it will normally give.
    public static func schedule(after seconds: TimeInterval = 15 * 60) {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: seconds),
            userInfo: identifier as NSString
        ) { _ in }
    }
}
#endif
