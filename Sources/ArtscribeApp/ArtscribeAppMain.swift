import AppKit
import ArtscribeUI
import SwiftUI

@main
struct ArtscribeAppMain: App {
    @State private var model = ViewerModel()

    init() {
        // A SwiftPM executable is not an app bundle, so AppKit starts it as an
        // accessory with no menu bar and no way to take keyboard focus. Asking
        // for the regular activation policy up front fixes both.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Artscribe", id: "viewer") {
            DocumentView(model: model)
                .frame(minWidth: 720, minHeight: 420)
                .preferredColorScheme(.dark)
                .task { start() }
        }
        .defaultSize(width: 1280, height: 720)
        .commands { ViewerCommands(model: model) }
    }

    @MainActor
    private func start() {
        NSApplication.shared.activate()
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }
}
