import SwiftUI

/// Actions the menu bar and the window share, so a command has exactly one
/// implementation regardless of how it was invoked.
public enum ViewerActions {
    @MainActor
    public static func open(_ model: ViewerModel) {
        guard let url = AudioFileTypes.runOpenPanel() else { return }
        model.open(url: url)
    }
}

/// The menu bar. ⌘-shortcuts live here because menu key equivalents work even
/// when nothing in the window has focus; the unmodified left-hand cluster is
/// handled by `DocumentView` and only *listed* here, so it stays discoverable
/// without the menu swallowing plain letter keys.
///
/// Nothing here uses `.disabled(…)`. A `Commands` body is not re-evaluated when
/// an `@Observable` model changes the way a `View` body is, so a state-dependent
/// enablement goes stale: ⌘9 measurably stopped firing after a selection was
/// made because the item was still marked disabled from launch. Every action
/// below is already a guarded no-op in `ViewerModel`, so an always-enabled item
/// is both correct and honest. Greying out returns in Plan 2 with the real
/// binding table behind it.
public struct ViewerCommands: Commands {
    private let model: ViewerModel

    public init(model: ViewerModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { ViewerActions.open(model) }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("View") {
            Button("Fit Whole File") { model.fitWholeFile() }
                .keyboardShortcut("0", modifiers: .command)
            Button("Zoom to Selection") { model.zoomToSelection() }
                .keyboardShortcut("9", modifiers: .command)

            Divider()

            Button("Zoom In  (R)") { model.zoomIn() }
            Button("Zoom Out  (E)") { model.zoomOut() }
            Button("Scroll Left  (Z)") { model.scrollLeft() }
            Button("Scroll Right  (X)") { model.scrollRight() }

            Divider()

            Button("Select All") { model.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
            Button("Clear Selection  (Esc)") { model.clearSelection() }
        }
    }
}
