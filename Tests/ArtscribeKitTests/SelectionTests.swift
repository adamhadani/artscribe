import Foundation
import Testing

@testable import ArtscribeKit

@Test func emptySelectionHasEmptyRange() {
    let s = Selection()
    #expect(s.isEmpty)
    #expect(s.range.isEmpty)
}

@Test func selectionNormalisesBackwardDrag() {
    var s = Selection()
    s.begin(at: 900)
    s.extend(to: 400)
    #expect(s.range == FrameRange(start: 400, count: 500))
    #expect(!s.isEmpty)
}

@Test func selectionForwardDrag() {
    var s = Selection()
    s.begin(at: 100)
    s.extend(to: 350)
    #expect(s.range == FrameRange(start: 100, count: 250))
}

@Test func clearMakesSelectionEmpty() {
    var s = Selection()
    s.begin(at: 10); s.extend(to: 99)
    s.clear()
    #expect(s.isEmpty)
}

@Test func loopRegionDefaultsDisabled() {
    let l = LoopRegion(range: FrameRange(start: 0, count: 100))
    #expect(!l.isEnabled)
}

@Test func extendBackToAnchorCollapsesToEmpty() {
    var s = Selection()
    s.begin(at: 100)
    s.extend(to: 500)
    #expect(!s.isEmpty)
    s.extend(to: 100)
    #expect(s.isEmpty)
    #expect(s.range.isEmpty)
}

// isEmpty must be derived from anchor/head, not an independently-decodable
// stored field, or corrupted/hand-edited JSON can desynchronise it from the
// range it is supposed to describe.
@Test func decodingCannotDesynchroniseIsEmptyFromAnchorAndHead() throws {
    let json = Data(#"{"anchor": 100, "head": 100, "isEmpty": false}"#.utf8)
    let decoded = try JSONDecoder().decode(Selection.self, from: json)
    #expect(decoded.isEmpty == decoded.range.isEmpty)
    #expect(decoded.isEmpty)
}

// MARK: - Translation
//
// Moving a whole selection is spec §6.2's `selection.move` pair, and every
// interesting case is at a boundary: a selection pushed against either end of
// the file must *stop*, keeping its length, rather than shrinking against the
// wall or inverting past it.

@Test func translatingMovesBothEdgesAndKeepsTheLength() {
    let moved = Selection(anchor: 100, head: 500).translated(by: 250, within: 10_000)
    #expect(moved == Selection(anchor: 350, head: 750))
    #expect(moved.range.count == 400)
}

@Test func translatingBackwardsMovesBothEdges() {
    let moved = Selection(anchor: 500, head: 100).translated(by: -50, within: 10_000)
    #expect(moved == Selection(anchor: 450, head: 50))
    #expect(moved.range == FrameRange(start: 50, count: 400))
}

/// The head-behind-anchor case has to survive the move, or a backward drag's
/// selection silently flips its anchor the first time it is moved.
@Test func translatingPreservesWhichEndIsTheAnchor() {
    let moved = Selection(anchor: 900, head: 400).translated(by: 100, within: 10_000)
    #expect(moved.anchor == 1000)
    #expect(moved.head == 500)
}

@Test func aSelectionPushedAgainstTheStartStopsWithoutShrinking() {
    let selection = Selection(anchor: 200, head: 700)
    let moved = selection.translated(by: -100_000, within: 10_000)
    #expect(moved.range == FrameRange(start: 0, count: 500))
    #expect(moved.range.count == selection.range.count)
}

@Test func aSelectionPushedAgainstTheEndStopsWithoutShrinking() {
    let selection = Selection(anchor: 9000, head: 9500)
    let moved = selection.translated(by: 100_000, within: 10_000)
    #expect(moved.range == FrameRange(start: 9500, count: 500))
    #expect(moved.range.count == selection.range.count)
    #expect(moved.range.end == 10_000)
}

/// The clamp must not invert the selection either: `end` can reach the file
/// length but never pass it, and `start` never goes below zero.
@Test func translatingNeverInvertsOrEscapesTheFile() {
    for delta in [FrameIndex.min, -1_000_000, -1, 0, 1, 1_000_000, .max] {
        let moved = Selection(anchor: 4000, head: 6000).translated(by: delta, within: 10_000)
        #expect(moved.range.start >= 0)
        #expect(moved.range.end <= 10_000)
        #expect(moved.range.count == 2000)
    }
}

@Test func translatingAnEmptySelectionDoesNothing() {
    let empty = Selection()
    #expect(empty.translated(by: 500, within: 10_000) == empty)
}

/// A selection longer than the file it is measured against cannot be placed
/// legally at all, so it is left exactly where it is rather than clamped to
/// some arbitrary end.
@Test func aSelectionLongerThanTheFileIsLeftAlone() {
    let selection = Selection(anchor: 0, head: 20_000)
    #expect(selection.translated(by: 100, within: 10_000) == selection)
}
