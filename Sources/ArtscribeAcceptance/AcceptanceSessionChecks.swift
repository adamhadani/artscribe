import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// Task 19 — session persistence (spec §7), driven through the real window.
///
/// Everything here happens on a **copy of the track in a temporary folder**,
/// never on the file the run was pointed at. A `.artscribe` file beside
/// somebody's music is the product's correct behaviour and a test run's
/// litter, and one of these checks deliberately makes a directory read-only.
/// The copy is removed at the end.
extension AcceptanceRun {

    @MainActor
    static func checkSession(model: ViewerModel, log: inout Logger, source: URL) async {
        await checkSessionMenuItems(log: &log)

        guard let scratch = makeSessionScratch(source: source, log: &log) else { return }
        defer { removeSessionScratch(scratch) }
        guard let window = NSApp.windows.first else {
            log.check("a window to close", false)
            return
        }
        let sidecar = SessionStore.sidecarURL(for: scratch.track)

        await load(model: model, url: scratch.track)
        log.check("a track with no sidecar opens unmodified", !model.isDirty)
        log.check("… and the window's close button shows no dot", !window.isDocumentEdited)
        log.check("… and nothing is recorded for it yet", model.sessionLocation == nil)

        // A real keystroke, into the real window: `W` is spec §6.2's faster.
        press(.w)
        await settle(seconds: 0.1)
        log.check("W makes the document modified", model.isDirty)
        log.check(
            "… and AppKit draws the modified dot in the close button", window.isDocumentEdited)
        log.note("speed after W", "\(model.speed.ratio)")

        await checkClosePromptCancels(model: model, window: window, sidecar: sidecar, log: &log)
        await checkSaveWritesTheSidecar(model: model, window: window, sidecar: sidecar, log: &log)
        await checkAdoptedTrackClosesWithoutAsking(
            model: model, window: window, sidecar: sidecar, log: &log)
        await checkReopenRestores(model: model, scratch: scratch, log: &log)
        await checkCorruptSidecar(model: model, scratch: scratch, log: &log)
        await checkHandEditsSurvive(model: model, scratch: scratch, log: &log)
        await checkReadOnlyFallback(model: model, scratch: scratch, log: &log)
    }

    // MARK: - The menu

    @MainActor
    private static func checkSessionMenuItems(log: inout Logger) async {
        guard let file = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu else {
            log.check("a File menu exists", false)
            return
        }
        await refreshMenu(file)
        log.note(
            "File menu",
            file.items.map(\.title).filter { !$0.isEmpty }
                .joined(separator: " | "))
        for (title, shift) in [("Save", false), ("Save As…", true)] {
            guard let item = file.items.first(where: { $0.title == title }) else {
                log.check("File ▸ \(title) exists", false)
                continue
            }
            log.check("File ▸ \(title) exists", true)
            let wanted: NSEvent.ModifierFlags = shift ? [.command, .shift] : [.command]
            log.check(
                "… bound to \(shift ? "⇧⌘S" : "⌘S")",
                item.keyEquivalent == "s" && item.keyEquivalentModifierMask == wanted)
        }
    }

    // MARK: - The close prompt

    /// The requested behaviour, end to end: closing an edited, never-saved track
    /// asks, and **Cancel genuinely cancels**.
    @MainActor
    private static func checkClosePromptCancels(
        model: ViewerModel, window: NSWindow, sidecar: URL, log: inout Logger
    ) async {
        // `windowShouldClose` is exactly what AppKit calls for ⌘W and for the
        // red button, so this is the real path rather than a stand-in — and
        // calling it directly means a run that reaches this point does not lose
        // its window to it.
        let shouldClose = window.delegate?.windowShouldClose?(window) ?? true
        await settle(seconds: 0.3)
        log.check("closing an edited, never-saved track does not just close", !shouldClose)
        guard let sheet = window.attachedSheet else {
            log.check("… it puts up a Save / Don't Save / Cancel sheet", false)
            return
        }
        log.check("… it puts up a Save / Don't Save / Cancel sheet", true)
        let titles = buttons(in: sheet).map(\.title)
        log.note("sheet buttons", titles.joined(separator: " | "))
        for expected in ["Save", "Don't Save", "Cancel"] {
            log.check("the sheet offers \(expected)", titles.contains(expected))
        }

        guard let cancel = buttons(in: sheet).first(where: { $0.title == "Cancel" }) else {
            log.check("Cancel cancels the close", false)
            return
        }
        cancel.performClick(nil)
        await settle(seconds: 0.4)
        log.check("Cancel leaves the window open", window.isVisible)
        log.check("… and the sheet gone", window.attachedSheet == nil)
        log.check("… and the changes still unsaved", model.isDirty)
        log.check(
            "… and nothing written beside the track",
            !FileManager.default.fileExists(atPath: sidecar.path))
    }

    // MARK: - Save

    @MainActor
    private static func checkSaveWritesTheSidecar(
        model: ViewerModel, window: NSWindow, sidecar: URL, log: inout Logger
    ) async {
        // Through the menu bar, as ⌘S really arrives.
        let claimed = offerToMenuBar(Key(1, "s", modifiers: .command))
        await settle(seconds: 0.3)
        log.check("⌘S is claimed by the File menu", claimed)
        log.check(
            "⌘S writes <track>.artscribe beside the track",
            FileManager.default.fileExists(atPath: sidecar.path))
        log.check("… and the modified dot goes out", !window.isDocumentEdited && !model.isDirty)
        log.check(
            "… and the session is recorded as beside the track",
            model.sessionLocation?
                .isBesideTheTrack == true)
        if let text = try? String(contentsOf: sidecar, encoding: .utf8) {
            log.note("sidecar", text.replacingOccurrences(of: "\n", with: " "))
            log.check(
                "the sidecar is readable JSON naming every field spec §7 lists",
                ["speed", "engine", "loop", "isEnabled", "viewport", "playhead"]
                    .allSatisfy { text.contains("\"\($0)\"") })
        } else {
            log.check("the sidecar can be read back", false)
        }
    }

    /// The other half of the resolution between §7's autosave and the prompt:
    /// once the file exists it is kept current, and closing stops asking.
    @MainActor
    private static func checkAdoptedTrackClosesWithoutAsking(
        model: ViewerModel, window: NSWindow, sidecar: URL, log: inout Logger
    ) async {
        // A loop, set with the real spec §6.2 keys.
        model.seek(to: model.totalFrames / 8)
        press(.a)
        model.seek(to: model.totalFrames / 4)
        press(.s)
        press(.d)
        await settle(seconds: 0.1)
        log.check("A/S set a loop and mark the document modified", model.loop.range.count > 0)
        log.check("… reflected in the close button", window.isDocumentEdited)

        let shouldClose = window.delegate?.windowShouldClose?(window) ?? false
        await settle(seconds: 0.3)
        log.check("a track that already has a sidecar closes without asking", shouldClose)
        log.check("… with no sheet on screen", window.attachedSheet == nil)
        log.check("… and the loop written on the way out", !model.isDirty)
        let onDisk = (try? String(contentsOf: sidecar, encoding: .utf8)) ?? ""
        log.check(
            "… and the loop really is in the file",
            onDisk.contains("\"count\" : \(model.loop.range.count)"))
    }

    // MARK: - Reopening

    @MainActor
    private static func checkReopenRestores(
        model: ViewerModel, scratch: SessionScratch, log: inout Logger
    ) async {
        model.zoomIn()
        model.zoomIn()
        model.seek(to: model.totalFrames / 3)
        model.saveSession()
        let want = (
            speed: model.speed, loop: model.loop, playhead: model.playhead,
            fpp: model.viewport.framesPerPixel, start: model.viewport.startFrame
        )

        // Away to another track and back, through the same `open(url:)` the Open
        // panel uses. Going *via* another file rather than reloading in place is
        // deliberate: reloading writes the outgoing session first, so a state
        // scrambled to prove the reload is real would simply be saved over the
        // one under test.
        await load(model: model, url: scratch.otherTrack)
        await load(model: model, url: scratch.track)
        log.check("reopening restores the speed", model.speed == want.speed)
        log.check("reopening restores the loop", model.loop == want.loop)
        log.check("reopening restores the playhead", model.playhead == want.playhead)
        log.check("reopening restores the zoom", model.viewport.framesPerPixel == want.fpp)
        log.check("reopening restores the scroll position", model.viewport.startFrame == want.start)
        log.check("… and does not open the window already modified", !model.isDirty)
        log.note(
            "restored",
            "speed \(model.speed.ratio) · \(model.speed.engine) · "
                + "loop \(model.loop.range.start)+\(model.loop.range.count) · "
                + "playhead \(model.playhead) · \(model.viewport.framesPerPixel) f/px")
    }

    // MARK: - Corrupt input

    /// The sidecar is a visible, user-editable file, so this is an ordinary
    /// input rather than an exotic one. The app must survive it and say so.
    @MainActor
    private static func checkCorruptSidecar(
        model: ViewerModel, scratch: SessionScratch, log: inout Logger
    ) async {
        let corrupt = #"{"schemaVersion":1,"speed":{"ratio":0,"engine":"telepa"#
        try? Data(corrupt.utf8).write(to: SessionStore.sidecarURL(for: scratch.otherTrack))
        await load(model: model, url: scratch.otherTrack)
        log.check("a truncated sidecar does not stop the track opening", model.hasTrack)
        log.check("… the speed degrades to a usable default", model.speed.ratio == 1.0)
        log.check("… and the time ratio is finite", model.speed.timeRatio.isFinite)
        log.check("… and it is not silent about it", model.sessionNotice != nil)
        log.note("notice", model.sessionNotice ?? "none")
        model.dismissSessionNotice()
    }

    // MARK: - The file belongs to the user

    /// The P0 the user found: reopening a track rewrote its sidecar *before*
    /// reading it, so a hand edit was destroyed by looking at the track. The
    /// visible sidecar was chosen over a hidden one (spec §2) precisely so it
    /// could be edited and shared, which that made a lie.
    @MainActor
    private static func checkHandEditsSurvive(
        model: ViewerModel, scratch: SessionScratch, log: inout Logger
    ) async {
        let sidecar = SessionStore.sidecarURL(for: scratch.track)
        await load(model: model, url: scratch.track)
        model.saveSession()
        await settle(seconds: 0.1)

        // Hand-edit it the way a person would: change a value, add a note, and
        // add a key inside one Artscribe owns.
        guard var text = try? String(contentsOf: sidecar, encoding: .utf8) else {
            log.check("the sidecar can be hand-edited", false)
            return
        }
        text = text.replacingOccurrences(
            of: "\"schemaVersion\" : 1",
            with: "\"comment\" : \"B section is the hard one\",\n  \"schemaVersion\" : 1")
        text = text.replacingOccurrences(
            of: "\"isEnabled\" :", with: "\"label\" : \"chorus\",\n    \"isEnabled\" :")
        guard (try? Data(text.utf8).write(to: sidecar)) != nil,
            let before = try? Data(contentsOf: sidecar)
        else {
            log.check("the sidecar can be hand-edited", false)
            return
        }
        log.check("the sidecar can be hand-edited", true)

        // Reopening it. This is the exact gesture that used to destroy the edit.
        await load(model: model, url: scratch.track)
        let after = (try? Data(contentsOf: sidecar)) ?? Data()
        log.check("reopening a track leaves its sidecar byte-for-byte unchanged", after == before)
        log.check(
            "… and the hand-edited note is still there",
            String(data: after, encoding: .utf8)?.contains("B section is the hard one") == true)

        // And a real save keeps what it did not write.
        press(.w)
        await settle(seconds: 0.1)
        model.saveSession()
        await settle(seconds: 0.1)
        let saved = (try? String(contentsOf: sidecar, encoding: .utf8)) ?? ""
        log.check("a save keeps a key Artscribe did not write", saved.contains("\"comment\""))
        log.check(
            "… including one nested inside a key it does own", saved.contains("\"label\""))
        log.check("… while still recording the change", !model.isDirty)
    }

    // MARK: - The read-only fallback (spec §7)

    @MainActor
    private static func checkReadOnlyFallback(
        model: ViewerModel, scratch: SessionScratch, log: inout Logger
    ) async {
        await load(model: model, url: scratch.track)
        try? FileManager.default.removeItem(at: SessionStore.sidecarURL(for: scratch.track))
        guard
            (try? FileManager.default.setAttributes(
                [.posixPermissions: 0o555], ofItemAtPath: scratch.directory.path)) != nil
        else {
            log.skip(
                "a read-only folder falls back to Application Support",
                because: "this run could not make the scratch folder read-only")
            return
        }
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scratch.directory.path)
        }

        press(.w)
        await settle(seconds: 0.1)
        model.saveSession()
        await settle(seconds: 0.2)
        log.check(
            "a read-only folder falls back to Application Support",
            model.sessionLocation.map { !$0.isBesideTheTrack } ?? false)
        log.check("… the loop points are not silently lost", !model.isDirty)
        log.check(
            "… and the fallback is surfaced, not swallowed", model.isSessionStoredAwayFromTheTrack)
        // The **standing banner**, not the dismissible notice. Both used to say
        // this and the user saw one condition described twice; the notice is for
        // things that happened, the banner for things that are still true.
        let banner = ViewerModel.fallbackNotice(reason: model.sessionFallbackReason)
        log.check("… in words that name where it went", banner.contains("Application Support"))
        log.check(
            "… and only once — no second, dismissible notice about the same thing",
            model.sessionNotice == nil)
        log.note("fallback banner", banner)
        if let url = model.sessionLocation?.url {
            log.check(
                "… and the file really is there",
                FileManager.default.fileExists(atPath: url.path))
        }
        model.dismissSessionNotice()
    }

    // MARK: - Scratch copy

    struct SessionScratch {
        let root: URL
        let directory: URL
        let track: URL
        /// A second copy, for the corrupt-sidecar check. It needs a track the
        /// window has *never* adopted: opening a file writes the outgoing
        /// session first (spec §7's "written on close"), so a corrupt sidecar
        /// written for the currently-loaded track would be replaced by a valid
        /// one before it was ever read.
        let otherTrack: URL
    }

    @MainActor
    private static func makeSessionScratch(source: URL, log: inout Logger) -> SessionScratch? {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("artscribe-acceptance-session-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("tracks")
        let track = directory.appendingPathComponent(source.lastPathComponent)
        let otherTrack = directory.appendingPathComponent("corrupt-\(source.lastPathComponent)")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: track)
            try FileManager.default.copyItem(at: source, to: otherTrack)
        } catch {
            log.skip(
                "session persistence",
                because: "the track could not be copied to a scratch "
                    + "folder (\(error.localizedDescription)), and these checks must never write "
                    + "beside real media")
            return nil
        }
        return SessionScratch(
            root: root, directory: directory, track: track, otherTrack: otherTrack)
    }

    @MainActor
    private static func removeSessionScratch(_ scratch: SessionScratch) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scratch.directory.path)
        try? FileManager.default.removeItem(at: scratch.root)
        try? FileManager.default.removeItem(at: AcceptanceMain.sessionFallbackDirectory)
    }

    @MainActor
    private static func load(model: ViewerModel, url: URL) async {
        let started = Date()
        model.open(url: url)
        while model.isLoading || !model.hasTrack {
            if Date().timeIntervalSince(started) > 60 { break }
            await settle(seconds: 0.05)
        }
        await settle(seconds: 0.2)
    }

    /// Every `NSButton` in a sheet, however deeply `NSAlert` nested it.
    @MainActor
    private static func buttons(in window: NSWindow) -> [NSButton] {
        guard let root = window.contentView else { return [] }
        var found: [NSButton] = []
        var stack = [root]
        while let view = stack.popLast() {
            if let button = view as? NSButton { found.append(button) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }
}
