import SwiftUI

/// The header: wordmark, the loaded file, and the decode progress bar.
struct TitleBarView: View {
    let model: ViewerModel
    let onOpen: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            Text("ARTSCRIBE")
                .font(Typography.eyebrow)
                .tracking(2.2)
                .foregroundStyle(palette.accent.color(opacity: 0.85))

            Rectangle()
                .fill(palette.rule.color())
                .frame(width: 1, height: 14)

            Text(model.fileName ?? "No file open")
                .font(Typography.fileName)
                .foregroundStyle(
                    model.fileName == nil
                        ? palette.dimmed.color() : palette.text.color()
                )
                .lineLimit(1)
                .truncationMode(.middle)

            // The read-only sidecar fallback used to be indicated here. Task 19
            // parked it in the title bar because there was no inspector to put
            // it in; spec §7 and §8 always said the inspector, and Task 20 built
            // one — see `InspectorView.fallbackNotice`.

            Spacer(minLength: 12)

            if model.isLoading {
                HStack(spacing: 8) {
                    Text(model.loadPhase?.label ?? "Loading…")
                        .font(Typography.readoutSmall)
                        .foregroundStyle(palette.dimmed.color())
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .tint(palette.accent.color())
                        .frame(width: 130)
                    Text("\(Int((model.progress * 100).rounded()))%")
                        .font(Typography.readoutSmall)
                        .foregroundStyle(palette.dimmed.color())
                        .monospacedDigit()
                }
            }

            Button("Open…", action: onOpen)
                .buttonStyle(.plain)
                .font(Typography.readout)
                .foregroundStyle(palette.text.color())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(palette.panel.color())
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(palette.rule.color(), lineWidth: 1))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(palette.background.color())
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.rule.color()).frame(height: 1)
        }
    }
}

/// A decode failure, shown in place rather than as a modal. The previously
/// loaded track is still on screen behind it (spec §8).
struct ErrorBannerView: View {
    @Environment(\.palette) private var palette
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(palette.danger.color())
                .font(.system(size: 12))
            Text(message)
                .font(Typography.bannerBody)
                .foregroundStyle(palette.text.color())
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.plain)
                .font(Typography.readoutSmall)
                .foregroundStyle(palette.dimmed.color())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(palette.danger.color(opacity: 0.12))
        .overlay(alignment: .leading) {
            Rectangle().fill(palette.danger.color()).frame(width: 2)
        }
    }
}
