// Replaced in Task 1 by real ArtscribeKit tests.
//
// `swift test` errors with "no tests found" if the package has zero test
// targets or a test target with zero test functions — it does not simply
// report "0 tests" the way the task brief anticipated. This placeholder
// keeps `make check` green until Task 1 adds real coverage.
import Testing

@testable import ArtscribeKit

@Suite struct PlaceholderTests {
    @Test func placeholderCompiles() {
        _ = Placeholder.self
        #expect(Bool(true))
    }
}
