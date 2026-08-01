#if !os(macOS)
import SwiftUI

/// **Settings, on iPad.** The macOS window's two tabs, in a sheet.
///
/// Deliberately the *same* `SettingsView` the Mac shows rather than a parallel
/// iPad layout. Two implementations of one settings screen is two places to add
/// every future preference to, and the one that gets forgotten is always the
/// platform the author is not using that week — the reason this screen was
/// missing on iPad in the first place.
///
/// What differs is only the frame around it: a `NavigationStack` for a title and
/// a **Done** button, because a sheet needs a way out that does not depend on
/// knowing you can swipe it down.
struct SettingsSheet: View {
    let model: ViewerModel
    let theme: ThemeController
    let settings: SettingsWindowController

    var body: some View {
        NavigationStack {
            SettingsView(model: model, theme: theme)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        // Closes through the controller, not `dismiss`: the
                        // sheet's presentation *is* `AuxiliaryWindow.isPresented`,
                        // and dismissing without putting that back would leave
                        // the next ⌘, toggling it "closed" and appearing dead.
                        // The same defect the shortcut and Practice sheets had.
                        Button("Done") { settings.windowState.isPresented = false }
                    }
                }
        }
    }
}
#endif
