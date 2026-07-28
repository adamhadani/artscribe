import Testing

@testable import ArtscribeUI

/// The close rule on its own, as a table. It is four lines of code in the model
/// and the single most consequential decision in the feature, so it is pinned
/// here rather than only exercised through a loaded track.
@Suite("Session close policy")
struct SessionClosePolicyTests {

    @Test("nothing to save means nothing to ask")
    func nothingToSave() {
        #expect(
            SessionClosePolicy.action(
                canSave: false, isDirty: true, hasStoredSession: true, lastSaveFailed: true)
                == .close)
    }

    @Test("a track with no session file is only worth asking about once it is edited")
    func neverSaved() {
        #expect(
            SessionClosePolicy.action(
                canSave: true, isDirty: false, hasStoredSession: false, lastSaveFailed: false)
                == .close)
        #expect(
            SessionClosePolicy.action(
                canSave: true, isDirty: true, hasStoredSession: false, lastSaveFailed: false)
                == .ask)
    }

    @Test("a track that already has a session file is kept up to date without asking")
    func alreadySaved() {
        for dirty in [true, false] {
            #expect(
                SessionClosePolicy.action(
                    canSave: true, isDirty: dirty, hasStoredSession: true, lastSaveFailed: false)
                    == .saveThenClose)
        }
    }

    /// The case that makes the fallback honest: if the last write failed
    /// outright, closing silently would be exactly the silent loss spec §7
    /// forbids, so it asks even though a file exists.
    @Test("a failed save turns closing back into a question")
    func failedSaveAsks() {
        #expect(
            SessionClosePolicy.action(
                canSave: true, isDirty: true, hasStoredSession: true, lastSaveFailed: true)
                == .ask)
        // But only while there is something to lose.
        #expect(
            SessionClosePolicy.action(
                canSave: true, isDirty: false, hasStoredSession: true, lastSaveFailed: true)
                == .saveThenClose)
    }
}
