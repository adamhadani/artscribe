#if os(macOS)

import AppKit
import Foundation
import UniformTypeIdentifiers

/// The AppKit half of session persistence: the window's modified dot and proxy
/// icon, the **Save As…** panel, and the Save / Don't Save / Cancel sheet.
///
/// None of this is testable without a window, so everything it *decides* lives
/// on `ViewerModel` (`closeAction`, `saveSession`, `discardSessionChanges`) and
/// is unit-tested there. What is here is only presentation and the delegate
/// plumbing that reaches it.
@MainActor
final class DocumentWindowChrome: NSObject, NSWindowDelegate {

    private let model: ViewerModel
    private weak var window: NSWindow?
    /// Whatever delegate SwiftUI had installed. Everything this class does not
    /// implement is forwarded there — see `forwardingTarget(for:)`.
    ///
    /// `nonisolated(unsafe)` because the two forwarding overrides below are
    /// `NSObject`'s and cannot be main-actor isolated, following the same
    /// reasoning as `KeyWindowTracker`'s observer tokens: it is written exactly
    /// once, from `adopt(_:)` on the main actor, and read only by AppKit while
    /// dispatching a delegate message — which AppKit only ever does on the main
    /// thread.
    private nonisolated(unsafe) weak var previousDelegate: (any NSWindowDelegate)?
    /// True while the sheet's answer is being carried out, so the `close()` that
    /// follows is not intercepted by `windowShouldClose` all over again.
    private var isCompletingClose = false

    init(model: ViewerModel) {
        self.model = model
        super.init()
    }

    /// Told which window this view landed in, by `WindowReader`.
    func adopt(_ window: NSWindow?) {
        guard window !== self.window else { return }
        self.window = window
        guard let window, window.delegate !== self else { return }
        previousDelegate = window.delegate
        window.delegate = self
        refresh()
    }

    /// Pushes the model's document state into the window chrome.
    ///
    /// Every write is compared first. `isDocumentEdited` and `representedURL`
    /// both redraw the title bar, and this is called from `onChange`, which
    /// SwiftUI may deliver more often than the value really moves.
    func refresh() {
        guard let window else { return }
        if window.isDocumentEdited != model.isDirty {
            window.isDocumentEdited = model.isDirty
        }
        // The proxy icon: standard for a window that stands for a file, and it
        // is what puts the track's path behind a ⌘-click on the title.
        if window.representedURL != model.trackURL {
            window.representedURL = model.trackURL
        }
    }

    // MARK: - Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isCompletingClose else { return true }
        switch model.closeAction {
        case .close:
            return true
        case .saveThenClose:
            // Spec §7's "written on close". Silent by design: the session file
            // already exists, so keeping it current is not a decision the user
            // has to be interrupted for.
            model.performClose()
            return true
        case .ask:
            presentSavePrompt(on: sender)
            return false
        }
    }

    private func presentSavePrompt(on window: NSWindow) {
        SessionPrompt.present(on: window, model: model) { [weak self] proceed in
            guard let self, proceed else { return }
            complete(close: window)
        }
    }

    private func complete(close window: NSWindow) {
        isCompletingClose = true
        window.close()
        isCompletingClose = false
    }

    // MARK: - Delegate forwarding
    //
    // SwiftUI installs its own window delegate and relies on it. Replacing it
    // outright would break whatever it does there, so this stands in front and
    // hands on everything it does not implement itself. Both overrides are
    // needed: AppKit asks `responds(to:)` before sending an optional delegate
    // message, and `forwardingTarget(for:)` is what actually delivers it.

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (previousDelegate?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        guard previousDelegate?.responds(to: selector) == true else { return nil }
        return previousDelegate
    }
}

/// The Save / Don't Save / Cancel sheet, in one place because three different
/// events ask the same question: closing the window, quitting the app, and
/// replacing the loaded track with another one. A single-window app has no
/// other way to leave a session behind, so all three have to ask it.
@MainActor
public enum SessionPrompt {

    /// Asks, then carries out the answer.
    ///
    /// A **sheet**, not `NSAlert.runModal`. `runModal` blocks the main thread
    /// until it is answered, which would make the prompt unreachable from the
    /// acceptance harness — the harness drives the app from the main actor, so
    /// it could never get far enough to click the button it is waiting on. A
    /// sheet is also what a document window should use: it belongs to the
    /// window it is asking about.
    ///
    /// - Parameter completion: `true` when the caller may go ahead — the
    ///   session was saved, or the user chose to abandon it. `false` on Cancel,
    ///   and on a save that could not land anywhere, so nothing closes over the
    ///   top of the message explaining what just failed.
    static func present(
        on window: NSWindow, model: ViewerModel, completion: @escaping (Bool) -> Void
    ) {
        guard window.attachedSheet == nil else { return completion(false) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save the session for “\(model.windowTitle)”?"
        alert.informativeText =
            "The speed and loop points you set are not saved yet. Saving writes "
            + "“\(model.suggestedSessionSaveURL?.lastPathComponent ?? "a .artscribe file")” "
            + "next to the track, and Artscribe keeps it up to date from then on."
        // Added right-to-left, which is how AppKit lays them out: Save is the
        // default at the right, Cancel beside it, Don't Save off on its own.
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        // The standard key equivalent for this button on macOS.
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command

        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                model.saveSession()
                completion(!model.lastSaveFailed)
            case .alertThirdButtonReturn:
                model.discardSessionChanges()
                completion(true)
            default:
                completion(false)
            }
        }
    }

    /// Asks whether the current session may be left behind, and answers.
    ///
    /// `completion(true)` means go ahead — there was nothing to lose, it was
    /// saved, or the user chose to abandon it. `completion(false)` means the
    /// user cancelled, or the save failed, and whatever was about to happen must
    /// not. Used by ⌘Q and by every route that replaces the loaded track.
    ///
    /// The completion may run synchronously; a caller that must not be
    /// re-entered (⌘Q's `reply(toApplicationShouldTerminate:)`) has to defer it
    /// itself.
    public static func whenSafeToLeave(
        _ model: ViewerModel, completion: @escaping (Bool) -> Void
    ) {
        switch model.closeAction {
        case .close:
            completion(true)
        case .saveThenClose:
            model.performClose()
            completion(true)
        case .ask:
            guard let window = NSApp.windows.first(where: \.isVisible) else {
                // Nowhere to ask from. Writing the sidecar unasked is the lesser
                // evil against losing loop points the user spent time on, which
                // is the one outcome spec §7 rules out.
                model.saveSession()
                completion(true)
                return
            }
            present(on: window, model: model, completion: completion)
        }
    }
}

/// The **Save As…** panel.
enum SessionPanels {

    /// A dynamic type rather than a declared one: `.artscribe` is not registered
    /// with Launch Services, and declaring it would mean claiming the extension
    /// in `Info.plist` for a file the app never opens directly. Conforming it to
    /// JSON is honest — that is exactly what it is — and gives the panel
    /// something to filter on.
    static var sessionType: UTType? {
        UTType(filenameExtension: SessionStore.fileExtension, conformingTo: .json)
    }

    /// Runs the modal save panel, defaulted to the canonical sidecar path.
    ///
    /// It opens on the track's own folder and the track's own sidecar name
    /// deliberately: that is the one place the file also *reloads* from, so the
    /// default answer to "save as" is the answer that keeps working.
    @MainActor
    static func runSavePanel(suggesting url: URL) -> URL? {
        let panel = NSSavePanel()
        if let sessionType { panel.allowedContentTypes = [sessionType] }
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.message =
            "Artscribe reloads a session from “\(url.lastPathComponent)” beside the track. "
            + "Saving anywhere else keeps a copy you can share, but reopening the track will not "
            + "find it."
        panel.prompt = "Save"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

#endif
