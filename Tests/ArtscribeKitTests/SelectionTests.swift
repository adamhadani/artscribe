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
