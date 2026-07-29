/// Which track labels to draw, and where, at the current zoom.
///
/// At album zoom a dozen track names compete for the same strip of pixels. This
/// is the label-decluttering problem digital maps solve, and the rule taken from
/// them is the one that matters: **the mark always survives; only the label
/// degrades.** Where tracks begin has to stay legible at every zoom, because
/// that is the entire point of the feature. A name that will not fit is dropped
/// whole rather than elided into a smear — two half-readable labels are worse
/// than one readable one.
///
/// Pure, and in `ArtscribeKit` for it: the view measures its own text and hands
/// the widths in, so the packing can be tested without rendering anything.
public enum CueLabelLayout {

    /// One marker's place on screen.
    public struct Placement: Equatable, Sendable {
        /// Where the tick goes. Always drawn.
        public var x: Double
        /// Where the label's leading edge goes, or `nil` when it was dropped.
        public var labelX: Double?
        public var markerIndex: Int

        public init(x: Double, labelX: Double?, markerIndex: Int) {
            self.x = x
            self.labelX = labelX
            self.markerIndex = markerIndex
        }
    }

    /// A marker as the layout needs it: where it sits, and how wide its name
    /// would be if drawn.
    public struct Item: Equatable, Sendable {
        public var x: Double
        public var labelWidth: Double
        public var index: Int

        public init(x: Double, labelWidth: Double, index: Int) {
            self.x = x
            self.labelWidth = labelWidth
            self.index = index
        }
    }

    /// The gap kept between a label and the next tick, so a name never runs into
    /// the mark that follows it.
    public static let padding: Double = 8

    /// Places each label in its own slot, and drops the ones that do not fit.
    ///
    /// **A label lives between its own tick and the next one**, and is dropped
    /// whole if it cannot. That single rule does all the decluttering: a label
    /// running past the following tick would sit over another track's mark and
    /// read as naming *that* track, which is worse than saying nothing.
    ///
    /// It also means **labels can never collide with each other** — each one
    /// ends before the next one begins, by construction. An earlier draft
    /// carried an `occupiedUntil` cursor to resolve label-versus-label overlap;
    /// a test showed it could never fire, and bookkeeping that looks load-bearing
    /// and is not costs more than it saves.
    ///
    /// Each marker is judged only against its own neighbours, so a label does
    /// not flicker as the viewport scrolls: whether it fits depends on the gap
    /// to the next track, not on what happened to be drawn to its left.
    ///
    /// - Parameters:
    ///   - items: markers in ascending `x`. Not sorted here: `CueSheet.parse`
    ///     already sorts, and re-sorting would hide a caller that did not.
    ///   - width: the lane's width. A label is dropped rather than clipped at
    ///     the right edge.
    public static func place(_ items: [Item], width: Double) -> [Placement] {
        var placements: [Placement] = []
        placements.reserveCapacity(items.count)
        for (position, item) in items.enumerated() {
            let labelX = item.x + 2
            let nextTick = position + 1 < items.count ? items[position + 1].x : width
            let fits =
                labelX >= 0
                && labelX + item.labelWidth + padding <= nextTick
                && labelX + item.labelWidth <= width
            placements.append(
                Placement(x: item.x, labelX: fits ? labelX : nil, markerIndex: item.index))
        }
        return placements
    }

    /// Which marker the playhead is inside — the track you are listening to.
    ///
    /// The last marker at or before `frame`. Returns `nil` before the first,
    /// which is a real state: a cue sheet whose first track starts at 00:00:33
    /// leaves a third of a second of lead-in belonging to no track.
    ///
    /// Binary search rather than a scan because this is asked on every frame the
    /// playhead moves, which is 62 times a second.
    public static func currentMarker(
        at frame: FrameIndex, starts: [FrameIndex]
    ) -> Int? {
        guard let first = starts.first, frame >= first else { return nil }
        var low = 0
        var high = starts.count - 1
        var answer = 0
        while low <= high {
            let middle = (low + high) / 2
            if starts[middle] <= frame {
                answer = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return answer
    }
}
