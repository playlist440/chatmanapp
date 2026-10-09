import SwiftUI
import Observation

/// What the list's surroundings are doing: how far the pinned faces have folded away, how far
/// the shelf is open, and where each of them ends on screen.
///
/// Kept apart from the list on purpose. All of this changes on every frame of a scroll, and a
/// value the list itself reads would make the list build itself again sixty times a second —
/// every row, every name, on an iPhone 13. As an object of its own, only the few views that
/// actually draw these read them: the faces, the shelf and the fades. The list only hands the
/// object on, and handing on a reference is not reading what is in it.
@MainActor
@Observable
final class ListChrome {

    // MARK: Pinned faces

    /// How far the pinned faces have folded, from 0 (full size, names and all) to 1 (small,
    /// names gone). Follows the list exactly: see ``follow(from:to:)``.
    var pinnedCollapse: CGFloat = 0

    /// Where the pinned band starts on screen, and how tall it is.
    ///
    /// Both are the band's layout, and folding never touches its layout: the faces shrink,
    /// slide and fade as a matter of drawing, inside a row that keeps its height. So these
    /// change when the row itself does — a chat pinned, a message arriving — and never
    /// because of a scroll. Nothing measured here is fed back into the size of what was
    /// measured, which is what keeps a fold from being able to feed on itself.
    private(set) var pinnedTop: CGFloat = 0
    private(set) var pinnedFullHeight: CGFloat = 0

    /// How tall the band is folded: the small faces and the band's own margins.
    static let pinnedFoldedHeight: CGFloat = PinnedSizes.foldedFace + 26

    /// Where the faces end on screen right now, for the fade under them. Worked out rather
    /// than measured, for the reason above.
    var pinnedBottom: CGFloat {
        guard pinnedFullHeight > 0 else { return 0 }
        let folding = max(0, pinnedFullHeight - Self.pinnedFoldedHeight)
        return pinnedTop + pinnedFullHeight - folding * pinnedCollapse
    }

    /// Where the band was laid out. Half a point either way is rounding, not movement.
    func placePinned(_ frame: CGRect) {
        if abs(pinnedTop - frame.minY) > 0.5 { pinnedTop = frame.minY }
        if abs(pinnedFullHeight - frame.height) > 0.5 { pinnedFullHeight = frame.height }
    }

    /// No band any more: nothing for the fade to reach down to.
    func removePinned() {
        pinnedTop = 0
        pinnedFullHeight = 0
    }

    // MARK: Shelf

    /// How far the shelf is open, from 0 (tiles) to 1 (cards).
    var shelfOpenness: CGFloat = 0

    /// Whether a finger is moving the shelf itself, which is not a list scroll.
    var shelfDragging = false

    // MARK: Where things are

    var headerBottom: CGFloat = 114
    var shelfTop: CGFloat = 0

    /// Whether the list is moving because somebody is scrolling it, or coasting after they
    /// did. Anything else that moves it — a row arriving, the search field sliding in — is
    /// not a scroll, and the faces and the shelf keep still for it.
    var isScrolling = false

    /// Where the list has scrolled to, for the sky behind it. A box the sky looks in while it
    /// draws, and not observed: see `SkyDepth`.
    let depth = SkyDepth()

    /// Folds and unfolds with the list, point for point.
    ///
    /// Not a trigger for an animation. Scroll down by half the distance the faces take to
    /// fold, and they are half folded; scroll up by as much, anywhere in the list, and they
    /// are back. At the very top they are always whole. The shelf closes the same way, one
    /// point of scrolling for one point of shelf, whichever way the list goes — opening it
    /// again is something you do on purpose, with the handle.
    func follow(from old: CGFloat, to new: CGFloat) {
        if new <= 0 {
            if pinnedCollapse != 0 { pinnedCollapse = 0 }
        }

        guard isScrolling else { return }
        let moved = new - old

        if new > 0 {
            let travel = max(40, pinnedFullHeight - Self.pinnedFoldedHeight)
            let folded = min(1, max(0, pinnedCollapse + moved / travel))
            if folded != pinnedCollapse { pinnedCollapse = folded }
        }

        if !shelfDragging, shelfOpenness > 0 {
            shelfOpenness = max(0, shelfOpenness - abs(moved) / 54)
        }
    }
}

/// The sizes a pinned face goes between.
enum PinnedSizes {
    static let face: CGFloat = 68
    static let foldedFace: CGFloat = 46
    static let column: CGFloat = 90
    static let foldedColumn: CGFloat = 58
}
