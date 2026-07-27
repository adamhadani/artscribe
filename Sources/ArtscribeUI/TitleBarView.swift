import SwiftUI

/// The header: wordmark, the loaded file, and the decode progress bar.
struct TitleBarView: View {
    let model: ViewerModel
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text("ARTSCRIBE")
                .font(Typography.eyebrow)
                .tracking(2.2)
                .foregroundStyle(Palette.accent.color(opacity: 0.85))

            Rectangle()
                .fill(Palette.rule.color())
                .frame(width: 1, height: 14)

            Text(model.fileName ?? "No file open")
                .font(Typography.fileName)
                .foregroundStyle(
                    model.fileName == nil
                        ? Palette.dimmed.color() : Palette.text.color()
                )
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            if model.isLoading {
                HStack(spacing: 8) {
                    Text("Decoding")
                        .font(Typography.readoutSmall)
                        .foregroundStyle(Palette.dimmed.color())
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .tint(Palette.accent.color())
                        .frame(width: 130)
                    Text("\(Int((model.progress * 100).rounded()))%")
                        .font(Typography.readoutSmall)
                        .foregroundStyle(Palette.dimmed.color())
                        .monospacedDigit()
                }
            }

            Button("Open…", action: onOpen)
                .buttonStyle(.plain)
                .font(Typography.readout)
                .foregroundStyle(Palette.text.color())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(Palette.panel.color())
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Palette.rule.color(), lineWidth: 1))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.background.color())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule.color()).frame(height: 1)
        }
    }
}

/// A decode failure, shown in place rather than as a modal. The previously
/// loaded track is still on screen behind it (spec §8).
struct ErrorBannerView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.danger.color())
                .font(.system(size: 12))
            Text(message)
                .font(Typography.bannerBody)
                .foregroundStyle(Palette.text.color())
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.plain)
                .font(Typography.readoutSmall)
                .foregroundStyle(Palette.dimmed.color())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.danger.color(opacity: 0.12))
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.danger.color()).frame(width: 2)
        }
    }
}
