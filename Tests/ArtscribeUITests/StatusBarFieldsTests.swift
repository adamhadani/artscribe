import CoreGraphics  // CGFloat, the unit the column widths are in
import Testing

@testable import ArtscribeUI

/// The status bar's priority logic. Views are not snapshot-tested here, so what
/// gets asserted is the part that is actually a decision: which readouts survive
/// as the window narrows, and in what order they are given up.
@Suite("Status bar fields")
struct StatusBarFieldsTests {

    /// The property that matters most. Position, volume and speed are the three
    /// a transcription app cannot be honest without — speed especially, since a
    /// forgotten 50% changes what you are hearing and spec §8 forbids that going
    /// unsaid.
    @Test("the essential fields survive every arrangement")
    func essentialNeverDropped() {
        for (level, fields) in StatusBarFields.candidates.enumerated() {
            for required in StatusBarFields.essential {
                #expect(
                    fields.contains(required),
                    "\(required.rawValue) was dropped at level \(level)")
            }
        }
    }

    /// A field dropped at one width must not come back at a narrower one.
    /// Something reappearing as you shrink the window would read as a glitch.
    @Test("each arrangement is a strict subset of the one before it")
    func monotonic() {
        let candidates = StatusBarFields.candidates
        for level in 1..<candidates.count {
            let wider = Set(candidates[level - 1])
            let narrower = Set(candidates[level])
            #expect(narrower.isSubset(of: wider), "level \(level) is not a subset of \(level - 1)")
            #expect(narrower.count < wider.count, "level \(level) dropped nothing")
        }
    }

    /// Dropping must not reshuffle the row — the fields that remain stay in the
    /// same left-to-right order, so your eye keeps finding them in the same place.
    @Test("order is preserved as fields are dropped")
    func orderPreserved() {
        for fields in StatusBarFields.candidates {
            let expected = StatusBarFields.displayOrder.filter { fields.contains($0) }
            #expect(fields == expected)
        }
    }

    /// The two lists have to partition the fields between them. A field in
    /// neither could never be dropped *and* was never declared essential — it
    /// would simply sit there forcing the row wide with nobody having decided
    /// that it should.
    @Test("every field is either essential or droppable, and none is both")
    func partition() {
        let essential = Set(StatusBarFields.essential)
        let droppable = Set(StatusBarFields.dropOrder)
        #expect(essential.isDisjoint(with: droppable))
        #expect(
            essential.union(droppable) == Set(StatusBarFields.Field.allCases),
            "a field is in neither list")
        #expect(Set(StatusBarFields.displayOrder) == Set(StatusBarFields.Field.allCases))
        #expect(StatusBarFields.displayOrder.count == StatusBarFields.Field.allCases.count)
    }

    /// Measured against the layout it has to fit in: `StatusBarView` uses 14 pt
    /// between columns and 14 pt of padding each side.
    ///
    /// The widest arrangement needs 1144 pt, which is what made the old
    /// fixed-width row clip on a narrow window instead of adapting. The
    /// narrowest has to fit a window someone might genuinely use — 560 pt is
    /// about half a 13-inch laptop screen.
    @Test("the arrangements span from the full row down to something narrow enough to be useful")
    func widths() {
        func width(_ fields: [StatusBarFields.Field]) -> CGFloat {
            let columns = fields.reduce(0) { $0 + StatusBarFields.width(of: $1) }
            return columns + CGFloat(fields.count) * 14 + 28
        }
        let widest = width(StatusBarFields.candidates[0])
        let narrowest = width(StatusBarFields.candidates[StatusBarFields.candidates.count - 1])

        #expect(widest > 1100, "the full row is \(widest) pt — the drop logic is not needed")
        #expect(
            narrowest < 560,
            "the narrowest arrangement still needs \(narrowest) pt, so a small window clips")
        #expect(narrowest < widest)
    }
}
