import SwiftUI

/// The window's content: the viewer, in the chosen theme.
///
/// It exists only to own `preferredColorScheme`, and it exists because that
/// modifier has to sit somewhere whose body is re-evaluated when the preference
/// changes. A `Scene` body is not reliably re-evaluated by an `@Observable`
/// change — the same trap `ViewerCommands` records for `Commands` bodies — so
/// putting it in the `App` would leave the window on whatever theme it launched
/// in. A `View` body tracks observation properly.
///
/// The scheme handed over is always explicit, never `nil` — `ThemeController`
/// resolves `System` against macOS itself. Passing `nil` here is the bug that
/// `ThemeController`'s documentation records: it clears the window's override
/// but leaves the `\.colorScheme` environment on the last explicit scheme, so
/// the chrome goes light while everything Artscribe draws stays dark.
public struct ViewerWindow: View {
    private let model: ViewerModel
    private let theme: ThemeController

    public init(model: ViewerModel, theme: ThemeController) {
        self.model = model
        self.theme = theme
    }

    public var body: some View {
        DocumentView(model: model)
            .preferredColorScheme(theme.colorScheme)
            // The menu bar and the open panel are AppKit's and do not follow
            // `preferredColorScheme`; this keeps them in step.
            .onAppear { theme.applyToApplication() }
    }
}
