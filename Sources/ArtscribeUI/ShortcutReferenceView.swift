import SwiftUI

/// **The shortcut reference**, generated from `ActionCatalog`.
///
/// Not a hand-written list. The catalog is what the menu bar is built from and
/// what the window resolves a key press against, so a shortcut cannot be
/// changed without this page changing with it — which is the whole reason the
/// catalog exists. See `ActionCatalogTests` for the guard, and `ActionCatalog`
/// for the argument.
///
/// It is designed to be *kept open while working*, so legibility beats
/// decoration: one row per action, the name on the left in a proportional face
/// because it is prose, the chords on the right as monospaced key caps because
/// they are values to be compared down a column. Actions with no shortcut —
/// Stop, Clear Loop, Scroll Left/Right — are menu items and belong in the menu;
/// listing them here under the heading "shortcuts" would be a lie with a blank
/// where the key should be.
struct ShortcutReferenceView: View {
    let context: MenuContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(ActionCatalog.reference, id: \.category) { group in
                    section(group.category, group.entries)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    private func section(_ category: ActionCategory, _ entries: [ActionEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(category.title.uppercased())
                .padding(.bottom, 6)
            ForEach(entries) { entry in
                ShortcutRow(entry: entry, context: context)
            }
        }
    }
}

/// One action: what it does, and what to press.
struct ShortcutRow: View {
    let entry: ActionEntry
    let context: MenuContext
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(ActionTitle.reference(entry.id, context))
                    .font(Typography.inspectorRow)
                    .foregroundStyle(palette.text.color())
                    .fixedSize(horizontal: false, vertical: true)
                if let note = entry.note {
                    Text(note)
                        .font(Typography.readoutSmall)
                        .foregroundStyle(palette.dimmed.color())
                }
            }
            Spacer(minLength: 8)
            // More than one chord is normal — the normal nudge answers to both
            // `Z` and `←`. The menu can only draw the first; this is the only
            // place the alternates are visible at all.
            HStack(spacing: 4) {
                ForEach(entry.chords, id: \.self) { chord in
                    KeyCapView(chord: chord)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// A shortcut, drawn as a recessed key cap.
///
/// Filled with `background` rather than `panel`: in both themes that is the
/// darker/duller of the two, so the cap reads as set into the panel rather than
/// floating on it, and the same one shape works in light and dark without being
/// two designs.
struct KeyCapView: View {
    let chord: KeyChord
    @Environment(\.palette) private var palette

    var body: some View {
        Text(chord.display)
            .font(Typography.keyCap)
            .foregroundStyle(palette.text.color())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4).fill(palette.background.color())
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(palette.rule.color(), lineWidth: 1)
            )
            .fixedSize()
    }
}
