import SwiftUI

// One page of the welcome tour and the key chip it draws. Split out of
// `WelcomeSheet.swift` only because that file reached the 400-line cap;
// the sheet, its navigation and the page data are still over there.

struct WelcomePageView: View {
    /// A page's own margin. Wider than `Metrics.gutter` because the text
    /// inside is centred prose with a hard `readingWidth` cap, and a narrow
    /// margin under a cap reads as an accident.
    private static let pageInset: CGFloat = 30
    /// A fixed column for the legend's glyphs, so the sentences beside
    /// them line up however wide each symbol draws.
    private static let glyphColumn: CGFloat = 20
    /// Narrower than `readingWidth`: the legend is two short columns,
    /// not prose, and it is centred under a paragraph that is.
    private static let legendWidth: CGFloat = 340

    let page: WelcomePage
    let surface: EmptyStatePrompt.Surface
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: Metrics.gutter) {
            Spacer(minLength: 0)
            Image(systemName: page.symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(palette.accent.color())
            Text(page.title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(palette.text.color())
            Text(page.body)
                .font(Typography.readout)
                .foregroundStyle(palette.dimmed.color())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !page.controls.isEmpty { legend }
            if !page.keys.isEmpty { chips }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.pageInset)
        .frame(maxWidth: Metrics.readingWidth)
    }

    /// The buttons, drawn as the bar draws them, one per row with what they do.
    ///
    /// Left-aligned inside a centred block: three icons and three sentences read
    /// as a key to the transport bar, and centring each row would leave the
    /// glyphs in a ragged column that no longer looks like the thing it
    /// describes.
    private var legend: some View {
        VStack(alignment: .leading, spacing: Metrics.lg) {
            ForEach(page.controls) { note in
                HStack(alignment: .firstTextBaseline, spacing: Metrics.lg) {
                    Image(systemName: note.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.accent.color())
                        // A fixed column so the sentences line up regardless of
                        // how wide each glyph happens to be.
                        .frame(width: Self.glyphColumn, alignment: .center)
                    VStack(alignment: .leading, spacing: Metrics.hairline) {
                        HStack(spacing: Metrics.sm) {
                            Text(note.name)
                                .font(Typography.readoutSmall)
                                .foregroundStyle(palette.text.color())
                            if WelcomePage.showsKeys(on: surface) {
                                KeyChip(key: note.shortcut)
                            }
                        }
                        Text(note.meaning)
                            .font(Typography.readoutSmall)
                            .foregroundStyle(palette.dimmed.color())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, Metrics.xxs)
        .frame(maxWidth: Self.legendWidth)
    }

    private var chips: some View {
        HStack(spacing: Metrics.gutter) {
            ForEach(page.keys) { note in
                HStack(spacing: Metrics.sm) {
                    KeyChip(key: note.key)
                    Text(note.label)
                        .font(Typography.readoutSmall)
                        .foregroundStyle(palette.dimmed.color())
                }
            }
        }
        .padding(.top, Metrics.xs)
    }
}

/// A key, drawn as a keycap.
struct KeyChip: View {
    let key: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(key)
            .font(Typography.readoutSmall)
            .foregroundStyle(palette.dimmed.color())
            .padding(.horizontal, Metrics.sm)
            .padding(.vertical, Metrics.xxs)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                    .fill(palette.background.color())
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                    .stroke(palette.rule.color(), lineWidth: 1))
    }
}
