import ArtscribeKit
import Foundation

/// Session persistence: the `.artscripture` sidecar (spec §7), the dirty flag,
/// Save, Save As, and what closing the window has to do about it.
///
/// ## The model, in one paragraph
///
/// Artscripture keeps a small, visible `<track>.artscripture` file next to each track
/// and treats it the way modern macOS treats a document that has a location:
/// **once it exists, it is kept up to date for you** — written a couple of
/// seconds after you change something and again when you close the window — so
/// loop points cannot be lost. ⌘S is therefore a checkpoint rather than a
/// necessity; it writes immediately instead of waiting. What Artscripture will not
/// do is create that file behind your back, because it lands in your music
/// folder where you can see it. So the *first* time you change the speed or set
/// a loop on a track that has no session file, closing the window asks: Save,
/// Don't Save, or Cancel. After that it never asks again.
///
/// ## Why that shape
///
/// Spec §7 asks for autosave ("written on close and debounced during editing")
/// and the user asked for the classic Save / Don't Save / Cancel prompt. Those
/// two are mutually exclusive *for the same document state*: a file that always
/// matches the working state has nothing to prompt about. The resolution above
/// is macOS's own — a document with a location autosaves in place and closes
/// silently, a document without one is asked about — and it keeps both halves
/// meaningful. It also keeps the prompt reachable and frequent enough to
/// matter, since every new track starts without a session file.
///
/// ## What counts as an edit
///
/// Speed, stretch engine, and the loop (its range and whether it is engaged).
/// Those are the decisions a user makes *about the track*, and the ones they
/// would answer a "save changes?" question about.
///
/// The playhead, the viewport and the selection are **not** edits. They are
/// where you happen to be looking. Marking the document dirty on every playhead
/// tick would leave it permanently modified sixty times a second, which would
/// make the dot and the prompt say nothing at all. They are still *persisted* —
/// spec §7 lists viewport and playhead, and coming back to a track where you
/// left it is most of the point — they simply ride along on whatever write
/// happens rather than causing one.
///
/// Volume is deliberately not persisted at all: `ViewerModel` already treats it
/// as a property of your headphones rather than of the file, and it survives a
/// load precisely because it is not per-track.
extension ViewerModel {

    // MARK: - Wiring

    /// Gives the model somewhere to read and write sessions. Optional, like
    /// `attach(recents:)`: a model built by a unit test has no store and
    /// therefore touches no disk.
    public func attach(sessions store: SessionStore) {
        sessions = store
    }

    /// False with no track loaded or no store attached, which is what Save and
    /// Save As check before doing anything.
    public var canSaveSession: Bool { sessions != nil && trackURL != nil && hasTrack }

    /// What the window's title bar shows. The modified state is deliberately
    /// *not* spelled into it — AppKit already draws that as the dot in the close
    /// button, and saying it twice is how a title bar starts shouting.
    public var windowTitle: String {
        trackURL?.lastPathComponent ?? fileName ?? "Artscripture"
    }

    /// True when this track's session had to go into Application Support
    /// because its own folder would not take a file. Surfaced in the title bar
    /// as well as in the notice, because the notice is dismissible and this is a
    /// standing condition (spec §7).
    public var isSessionStoredAwayFromTheTrack: Bool {
        guard let sessionLocation else { return false }
        return !sessionLocation.isBesideTheTrack
    }

    /// Everything the sidecar holds, as of right now.
    public var sessionState: SessionState? {
        guard hasTrack else { return nil }
        return SessionState(
            speed: speed,
            pitch: pitch,
            loop: loop,
            viewport: viewport.state,
            playhead: playhead,
            track: TrackIdentity(sampleRate: sampleRate, frameCount: totalFrames),
            showTrackMarks: markers.isVisible)
    }

    /// What the Save As… panel opens on: the canonical sidecar, which is both
    /// the name that reloads and the name a user sharing one would expect.
    public var suggestedSessionSaveURL: URL? {
        trackURL.map { SessionStore.sidecarURL(for: $0) }
    }

    public func dismissSessionNotice() {
        sessionNotice = nil
    }

    // MARK: - Editing

    /// Called from the two chokepoints that change durable state —
    /// `applySpeed` and `applyLoop` — after they have decided something really
    /// moved. Both already return early on a no-op, so setting the speed to the
    /// speed it is at does not modify the document.
    func markSessionEdited() {
        guard canSaveSession else { return }
        if !isDirty { isDirty = true }
        scheduleAutosave()
    }

    /// Debounced, per spec §7. Only for a track whose sidecar already exists:
    /// creating one unasked is the thing the close prompt exists to ask about.
    private func scheduleAutosave() {
        guard sessionLocation != nil else { return }
        autosaveTask?.cancel()
        let delay = autosaveDelay
        // A `Task` created on the main actor inherits it, so the write happens
        // where every other model mutation does — no hop, no re-entrancy.
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.writeSession()
        }
    }

    // MARK: - Save

    /// **File ▸ Save (⌘S).** Writes now instead of waiting for the debounce, and
    /// creates the sidecar if this track has never had one.
    public func saveSession() {
        guard canSaveSession else { return }
        cancelAutosave()
        writeSession()
    }

    /// **File ▸ Save As…**, with a destination already chosen.
    ///
    /// A sidecar is identified by its name and its folder — that is how
    /// reopening a track finds it — so "save it somewhere else" cannot mean the
    /// same thing here as it does for a normal document. Two outcomes:
    ///
    /// - The canonical `<track>.artscripture` beside the track: this **is** the
    ///   session file, so it is adopted and everything continues there. That is
    ///   the useful case when the folder was read-only earlier and is not now.
    /// - Anywhere else: a **copy**, for sharing a set of loop points or
    ///   archiving them. The window keeps its own session where it was, and the
    ///   user is told plainly that reopening the track will not find this file —
    ///   because the alternative, silently redirecting the live session to a
    ///   path nothing reloads from, is the silent loss spec §7 exists to
    ///   prevent.
    /// Whichever way it goes, the unknown keys in the session this window read
    /// are carried into the file it writes — a copy meant for a bandmate that
    /// silently dropped the note you typed into the original would be a strange
    /// kind of copy.
    public func saveSession(to url: URL) {
        guard let sessions, let track = trackURL, let state = sessionState else { return }
        let written: Data
        do {
            written = try sessions.write(state, to: url, preserving: preservedSidecar)
        } catch {
            lastSaveFailed = true
            sessionNotice =
                "Could not save the session to “\(url.lastPathComponent)”: "
                + "\(error.localizedDescription)"
            return
        }
        guard SessionStore.isCanonicalSidecar(url, for: track) else {
            sessionNotice =
                "Saved a copy to “\(url.lastPathComponent)”. Reopening this track loads "
                + "“\(SessionStore.sidecarURL(for: track).lastPathComponent)” from the track's own "
                + "folder, so the copy is for sharing or keeping — this window's session is "
                + "unchanged."
            return
        }
        cancelAutosave()
        adopt(
            SessionSave(
                location: .sidecar(url), fellBack: false, reason: nil, contents: written))
    }

    /// **Don't Save.** Nothing is written, and the document stops claiming to
    /// have unsaved changes so the close can proceed.
    public func discardSessionChanges() {
        cancelAutosave()
        isDirty = false
    }

    private func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    /// The one place a session is written for this window.
    private func writeSession() {
        guard let sessions, let track = trackURL, let state = sessionState else { return }
        do {
            adopt(try sessions.save(state, for: track, preserving: preservedSidecar))
        } catch {
            lastSaveFailed = true
            sessionNotice =
                "This track's session could not be saved, next to the track or in Application "
                + "Support: \(error.localizedDescription) Your loop points are still here, but "
                + "they will be gone when this window closes."
        }
    }

    private func adopt(_ saved: SessionSave) {
        sessionLocation = saved.location
        isDirty = false
        lastSaveFailed = false
        // What is now on disk, and the bytes to lay the next write over. The
        // bytes just written already carry everything that was preserved, so
        // this keeps unknown keys alive across a whole session of saves rather
        // than only the first one.
        savedState = sessionState
        preservedSidecar = saved.contents
        // The *reason* is worth keeping even though the notice is not: the banner
        // can say "you do not have permission to write to that folder", which is
        // the difference between a mystery and an explanation.
        sessionFallbackReason = saved.fellBack ? saved.reason : nil
        // A previous fallback notice is stale once the sidecar works again. Kept
        // for sessions saved by an older build, which could still have raised one.
        if !saved.fellBack, isSessionNoticeAboutStorage { sessionNotice = nil }
    }

    /// Whether the standing notice is the fallback one, so a successful sidecar
    /// write can clear it without also clearing a "this file was damaged"
    /// message the user has not read yet.
    private var isSessionNoticeAboutStorage: Bool {
        sessionNotice?.contains("Application Support") == true
    }

    /// What the standing banner says. One sentence for the fact, one for what it
    /// means to the reader, and the reason in between when the filesystem gave
    /// one — "could not be written to" invites the question this answers.
    ///
    /// This replaced a dismissible notice with the same content. Two banners
    /// stating one condition is not twice as clear; it is a screen the reader
    /// stops reading.
    public static func fallbackNotice(reason: String?) -> String {
        "This track's folder will not accept a session file"
            + (reason.map { " (\($0))" } ?? "")
            + ", so the session is stored in Application Support instead. Your loop points are "
            + "safe and will come back when you reopen the track, but the file is not beside the "
            + "track and will not travel with it."
    }

    // MARK: - Restore

    /// Adopts a track's stored session, or leaves the model on defaults when
    /// there is none. Called by `adopt(_:url:startedAt:token:)` once the audio
    /// is in place, because everything read here is clamped against the
    /// recording's real length.
    ///
    /// Internal rather than private so `ViewerModel+Loading` can reach it, and
    /// so the unit tests can build the state `open(url:)` would leave without
    /// running the decode pipeline.
    func adoptSession(for url: URL) {
        cancelAutosave()
        trackURL = url
        isDirty = false
        lastSaveFailed = false
        sessionLocation = nil
        sessionNotice = nil
        savedState = nil
        preservedSidecar = nil

        guard let sessions,
            let read = sessions.load(
                for: url, frameCount: totalFrames, sampleRate: sampleRate)
        else { return }

        sessionLocation = read.location
        preservedSidecar = read.original
        let state = read.restoration.state
        speed = state.speed
        pitch = state.pitch
        loop = state.loop
        playhead = Swift.max(0, Swift.min(state.playhead, totalFrames))
        reachedEnd = playhead >= totalFrames && totalFrames > 0
        viewport.restore(state.viewport)
        // The lane is only *shown* when the file also has a cue sheet, which
        // `showsTrackMarks` decides — this restores the user's choice, not the
        // presence of markers, so a sidecar saying "hidden" does not have to be
        // rewritten when its album has no cue sheet to hide.
        markers.setVisible(state.showTrackMarks)
        // Recorded *after* the restore, so it is the state the app is actually
        // running rather than the file's literal contents. A hand-edited value
        // that had to be clamped therefore does not register as "the file is out
        // of date" and does not provoke a write to correct it — the user is told
        // about the repair and left to decide.
        savedState = sessionState
        sessionNotice = Self.restoreNotice(for: read)
    }

    /// Pushes a restored session at the audio graph, once there is one.
    ///
    /// Separate from `adoptSession` because the graph is built *after* it: the
    /// engine is constructed for the restored stretch engine and told the
    /// restored time ratio by `openSession`, and only the loop and the position
    /// still have to be sent.
    func applyRestoredSession() {
        guard let session else { return }
        if loop.range.count > 0 || loop.isEnabled {
            session.push(.setLoop(loop.range, loop.isEnabled))
        }
        if playhead != 0 { session.push(.seek(playhead)) }
    }

    /// What to say about a session file that was not read exactly as written.
    /// `nil` when there is nothing to say.
    static func restoreNotice(for read: SessionRead) -> String? {
        var parts: [String] = []
        if let failure = read.failure {
            parts.append(
                "The session file for this track could not be read — \(failure.message). "
                    + "The track is open with default settings; saving will replace it.")
        } else if !read.restoration.repairs.isEmpty {
            let named = read.restoration.repairs.map(\.label)
            parts.append(
                "Part of this track's session file could not be used: "
                    + "\(list(named)). Everything else was restored.")
        }
        // **Deliberately silent about the storage location.** That is a standing
        // condition, not an event, and `SessionFallbackBanner` states it for as
        // long as it is true. Saying it here as well put two banners on screen
        // describing one fact in two orders of words — one dismissible, one not.
        // This notice is for things that *happened*: a damaged file, a repair.
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "a, b and c" — the Oxford-comma-free English list, because these end up
    /// in a sentence a user reads rather than a log line.
    private static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - Closing

    /// What closing this window has to do about the session. See
    /// `SessionClosePolicy`.
    public var closeAction: SessionCloseAction {
        SessionClosePolicy.action(
            canSave: canSaveSession, isDirty: isDirty,
            hasStoredSession: sessionLocation != nil, lastSaveFailed: lastSaveFailed)
    }

    /// True when what would be written differs from what is on disk.
    ///
    /// Broader than `isDirty` on purpose: it includes the playhead and the
    /// viewport, which spec §7 persists but which are never *edits* (see this
    /// file's header). So closing a track whose position moved records where you
    /// were, and closing one nobody touched writes nothing at all.
    public var hasUnwrittenChanges: Bool { sessionState != savedState }

    /// The `.saveThenClose` half of the decision, and the "written on close"
    /// half of spec §7. Called by the window before it goes away, by ⌘Q, and by
    /// anything that replaces the loaded track.
    ///
    /// **Guarded, not unconditional.** An unguarded write here rewrote the
    /// sidecar of any track that was merely looked at, which for a file the user
    /// is invited to hand-edit means their edit disappears the next time they
    /// glance at the track.
    public func performClose() {
        cancelAutosave()
        guard canSaveSession, hasUnwrittenChanges else { return }
        writeSession()
    }
}
