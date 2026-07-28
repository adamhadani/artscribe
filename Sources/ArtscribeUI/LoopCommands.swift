import SwiftUI

/// The **Loop** menu — the app's signature feature, given its own place in the
/// menu bar.
///
/// It was the last block of a 36-item Playback menu, which is where a feature
/// goes to be undiscoverable: looping a passage is the reason this app exists,
/// and `A`/`S`/`D`/`F`/`G` are the five keys a new user most needs to find. It
/// is also where the Practice hub (speed-ramping repetitions) lands later, so
/// the menu has somewhere to grow that is not "the bottom of Playback".
///
/// A `CommandMenu`, unlike `EditCommands`: macOS builds no Loop menu of its
/// own, so there is nothing to merge with and nothing to duplicate.
public struct LoopCommands: Commands {
    private let model: ViewerModel

    public init(model: ViewerModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandMenu("Loop") {
            LoopItems(model: model)
        }
    }
}

/// The loop items, in a `View` for the two reasons `PlaybackMenu` records: a
/// `Commands` body does not re-evaluate when an `@Observable` changes, so both
/// the `Loop` checkmark and every `.disabled(…)` here would go stale in one;
/// and the plain letters must stand down while another window holds the
/// keyboard, or `A` typed into Settings sets a loop point.
struct LoopItems: View {
    let model: ViewerModel
    private let keyWindow = KeyWindowTracker.shared

    var body: some View {
        Group {
            Button("Set Loop In") { model.setLoopIn() }
                .keyboardShortcut("a", modifiers: [])
            Button("Set Loop Out") { model.setLoopOut() }
                .keyboardShortcut("s", modifiers: [])
            Toggle(
                "Loop",
                isOn: Binding(
                    get: { model.loop.isEnabled },
                    // Compared rather than blindly toggled: a `Binding` set to
                    // the value it already holds must be a no-op, or the item
                    // inverts the state it was asked to confirm.
                    set: { isOn in if isOn != model.loop.isEnabled { model.toggleLoop() } })
            )
            .keyboardShortcut("d", modifiers: [])
            .disabled(model.loop.range.isEmpty && !model.loop.isEnabled)
            Button("Restart Loop") { model.restartLoop() }
                .keyboardShortcut("f", modifiers: [])
                .disabled(model.loop.range.isEmpty)

            Divider()

            Button("Selection → Loop") { model.loopFromSelection() }
                .keyboardShortcut("g", modifiers: [])
                .disabled(model.selection.isEmpty)
            Button("Clear Loop") { model.clearLoop() }
                .disabled(model.loop.range.isEmpty)
        }
        .disabled(!model.hasTrack || !keyWindow.documentIsKey)
    }
}
