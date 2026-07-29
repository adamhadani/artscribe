/// What a window must do when it is asked to close.
public enum SessionCloseAction: Equatable, Sendable {
    /// Nothing is stored for this track and nothing was changed, or there is no
    /// track at all.
    case close
    /// A session file already exists, so it is brought up to date and the window
    /// goes. This is the ordinary path and it never interrupts anybody.
    case saveThenClose
    /// Save / Don't Save / Cancel. Reached when this track has no session file
    /// yet and has been edited, or when the last attempt to write one failed.
    case ask
}

/// The close rule, as a pure function.
///
/// It is deliberately not a method on the model: it is the single most
/// consequential decision in this feature — get it wrong in one direction and
/// the app nags on every window close, in the other and it silently drops loop
/// points — and it should be readable and testable as a table rather than
/// inferred from four `if`s in the middle of a view.
public enum SessionClosePolicy {
    public static func action(
        canSave: Bool, isDirty: Bool, hasStoredSession: Bool, lastSaveFailed: Bool
    ) -> SessionCloseAction {
        guard canSave else { return .close }
        // A file exists but the last write to it failed, and there are changes
        // that are not in it. Closing quietly here is exactly the silent loss
        // spec §7 forbids, so it asks and lets Save As… find somewhere writable.
        if lastSaveFailed && isDirty { return .ask }
        guard hasStoredSession else {
            // Never saved. Only worth a question once there is something in the
            // window that is not on disk — and it is a question rather than a
            // silent write because the file lands in the user's music folder,
            // visibly, and that is their decision to make (spec §2).
            return isDirty ? .ask : .close
        }
        // Has a location, so it is kept up to date: the macOS rule for a
        // document that has been saved once. The write also carries the
        // viewport and playhead, which are persisted but never dirty.
        return .saveThenClose
    }
}
