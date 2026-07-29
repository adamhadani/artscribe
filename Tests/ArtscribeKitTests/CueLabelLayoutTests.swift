import Testing

@testable import ArtscribeKit

/// Label packing and the current-track lookup.
///
/// Extracted from the view precisely so these can be tested — the project does
/// not snapshot-test views, so anything worth asserting has to be pure.
@Suite("Cue label layout")
struct CueLabelLayoutTests {

    private func items(_ pairs: [(Double, Double)]) -> [CueLabelLayout.Item] {
        pairs.enumerated().map {
            CueLabelLayout.Item(x: $1.0, labelWidth: $1.1, index: $0)
        }
    }

    /// The load-bearing invariant, and the reason the feature is worth having at
    /// all: you can always see *where* tracks begin, even when there is no room
    /// to say what they are called.
    @Test("every marker keeps its tick no matter how tight the packing")
    func ticksAlwaysSurvive() {
        let crowded = items((0..<20).map { (Double($0) * 4, 80) })
        let placed = CueLabelLayout.place(crowded, width: 100)
        #expect(placed.count == 20)
        #expect(placed.map(\.x) == crowded.map(\.x))
        // And essentially none of them could have been labelled.
        #expect(placed.filter { $0.labelX != nil }.count <= 1)
    }

    @Test("labels that fit are all drawn")
    func roomyLayout() {
        let placed = CueLabelLayout.place(items([(0, 40), (200, 40), (400, 40)]), width: 600)
        #expect(placed.allSatisfy { $0.labelX != nil })
        #expect(placed.map(\.labelX) == [2, 202, 402])
    }

    /// A label reaching past the following tick would sit over another track's
    /// mark, reading as though it named that track.
    @Test("a label is dropped rather than run under the next tick")
    func dropsRatherThanOverlaps() {
        // 100pt wide label with only 50pt before the next marker.
        let placed = CueLabelLayout.place(items([(0, 100), (50, 20)]), width: 400)
        #expect(placed[0].labelX == nil)
        #expect(placed[1].labelX != nil)
        // The ticks are untouched.
        #expect(placed.map(\.x) == [0, 50])
    }

    @Test("a label is dropped rather than clipped at the right edge")
    func dropsAtTheRightEdge() {
        let placed = CueLabelLayout.place(items([(380, 40)]), width: 400)
        #expect(placed[0].labelX == nil)
        #expect(placed[0].x == 380)
    }

    /// Each label is judged only against its own slot. A crowded track loses its
    /// name without taking its neighbour's with it — the alternative, letting a
    /// long name push later labels out, makes a single wordy title blank half
    /// the lane.
    @Test("a label that will not fit does not cost its neighbour its label")
    func droppingIsLocal() {
        // 60pt of text with 30pt of room; the next two have room to spare.
        let placed = CueLabelLayout.place(items([(0, 60), (30, 20), (200, 20)]), width: 400)
        #expect(placed[0].labelX == nil)
        #expect(placed[1].labelX != nil)
        #expect(placed[2].labelX != nil)
    }

    /// The property the `occupiedUntil` cursor used to be there to enforce, now
    /// a consequence of the slot rule. Asserted rather than assumed, because it
    /// is the reason that code could be deleted.
    @Test("placed labels never overlap one another, whatever the spacing")
    func placedLabelsNeverOverlap() {
        let widths: [Double] = [10, 90, 25, 200, 5, 60, 45]
        let xs: [Double] = [0, 20, 55, 120, 130, 300, 480]
        let placed = CueLabelLayout.place(
            items(Array(zip(xs, widths))), width: 600)
        let drawn = placed.enumerated().compactMap { position, placement in
            placement.labelX.map { ($0, $0 + widths[position]) }
        }
        for (earlier, later) in zip(drawn, drawn.dropFirst()) {
            #expect(earlier.1 <= later.0, "\(earlier) runs into \(later)")
        }
    }

    @Test("no markers lays out nothing rather than trapping")
    func empty() {
        #expect(CueLabelLayout.place([], width: 400).isEmpty)
    }

    // MARK: - Which track am I in

    private static let starts: [FrameIndex] = [1000, 5000, 9000]

    @Test("the current marker is the last one at or before the playhead")
    func currentMarker() {
        #expect(CueLabelLayout.currentMarker(at: 1000, starts: Self.starts) == 0)
        #expect(CueLabelLayout.currentMarker(at: 4999, starts: Self.starts) == 0)
        #expect(CueLabelLayout.currentMarker(at: 5000, starts: Self.starts) == 1)
        #expect(CueLabelLayout.currentMarker(at: 100_000, starts: Self.starts) == 2)
    }

    /// Not a degenerate case to paper over: a cue sheet whose first `INDEX 01`
    /// is at 00:00:33 leaves a third of a second belonging to no track at all,
    /// and claiming it belongs to track 1 would be a lie about where track 1
    /// starts.
    @Test("before the first marker there is no current track")
    func beforeTheFirstMarker() {
        #expect(CueLabelLayout.currentMarker(at: 0, starts: Self.starts) == nil)
        #expect(CueLabelLayout.currentMarker(at: 999, starts: Self.starts) == nil)
        #expect(CueLabelLayout.currentMarker(at: 0, starts: []) == nil)
    }

    /// The lookup runs on every displayed frame, so it is a binary search — and
    /// a binary search is exactly the kind of code that is right for 3 elements
    /// and wrong for 13. The corpus's longest album has 13 tracks.
    @Test("the search agrees with a linear scan across a realistic album")
    func agreesWithLinearScan() {
        let starts: [FrameIndex] = (0..<13).map { FrameIndex($0) * 44100 * 200 }
        for frame in stride(from: FrameIndex(0), to: 13 * 44100 * 200, by: 44100 * 37) {
            let linear = starts.lastIndex { $0 <= frame }
            #expect(CueLabelLayout.currentMarker(at: frame, starts: starts) == linear)
        }
    }
}
