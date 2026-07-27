import ArtscribeKit
import SwiftUI

/// The viewer window.
///
/// Keyboard handling lives here rather than in the lanes so the bindings work
/// wherever the pointer is. It is deliberately a flat `switch` for now: Plan 2
/// replaces it with the real `BindingTable`.
public struct DocumentView: View {
    private let model: ViewerModel
    @FocusState private var hasKeyboardFocus: Bool
    @State private var trackpad = TrackpadMonitor()

    public init(model: ViewerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            TitleBarView(model: model) { ViewerActions.open(model) }

            if let message = model.errorMessage {
                ErrorBannerView(message: message) { model.dismissError() }
            }

            if model.hasTrack {
                OverviewStripView(model: model)
                    .frame(height: 58)
                TimeRulerView(model: model)
                WaveformLanesView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView()
            }

            StatusBarView(model: model)
        }
        .background(Palette.background.color())
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onKeyPress(phases: [.down, .repeat], action: handle)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url: url)
            return true
        }
        .onAppear {
            hasKeyboardFocus = true
            trackpad.start(model: model)
        }
        .onDisappear { trackpad.stop() }
    }

    // MARK: - Commands

    /// The agreed left-hand cluster. `⌘`-modified keys belong to the menu bar,
    /// so anything carrying Command is passed straight through.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard !press.modifiers.contains(.command) else { return .ignored }
        switch press.key {
        case KeyEquivalent("e"):
            model.zoomOut()
        case KeyEquivalent("r"):
            model.zoomIn()
        case KeyEquivalent("z"):
            model.scrollLeft()
        case KeyEquivalent("x"):
            model.scrollRight()
        case .escape:
            model.clearSelection()
        default:
            return .ignored
        }
        return .handled
    }
}

/// What the window says before anything is loaded. An empty screen is an
/// invitation to act, so it names both ways in.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Drop an audio file here")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.text.color())
            Text("or press ⌘O to choose one")
                .font(Typography.readout)
                .foregroundStyle(Palette.dimmed.color())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.panel.color())
    }
}
