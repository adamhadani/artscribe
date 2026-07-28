import SwiftUI

/// **The list**, generated from `ActionCatalog` and narrowed by the same filter
/// the keyboard reads.
///
/// It is here because the keyboard cannot do this half. A picture of a keyboard
/// answers *"what can I press"* beautifully and *"what is the shortcut for
/// Zoom to Selection"* not at all — you have to already know which key to look
/// at, which is the thing you came to find out. So the window offers both, over
/// one field.
///
/// **An action with no shortcut is still in here.** Stop, Clear Loop and the
/// two Scroll items are menu items and nothing else; a window headed "Keyboard
/// Shortcuts" that could not find them at all would send you hunting through
/// the menu bar for something it claims to be the index of. They are drawn as
/// *Menu only* rather than with a blank where the key should be.
struct ShortcutListView: View {
    let context: MenuContext
    let query: String
    let appearance: Appearance
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                let groups = ShortcutSearch.grouped(query: query)
                if groups.isEmpty {
                    Text("Nothing matches “\(query)”.")
                        .font(Typography.readout)
                        .foregroundStyle(palette.dimmed.color())
                        .padding(.top, 6)
                }
                ForEach(groups, id: \.category) { group in
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
            HStack(spacing: 6) {
                // The same swatch the keyboard's legend draws, so a colour seen
                // on a key can be followed straight to its group here.
                RoundedRectangle(cornerRadius: 2)
                    .fill(category.tint(appearance).color())
                    .frame(width: 9, height: 9)
                Eyebrow(category.title.uppercased())
            }
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
                    .font(Typography.actionName)
                    .foregroundStyle(palette.text.color())
                    .fixedSize(horizontal: false, vertical: true)
                if let note = entry.note {
                    Text(note)
                        .font(Typography.readoutSmall)
                        .foregroundStyle(palette.dimmed.color())
                }
            }
            Spacer(minLength: 8)
            if entry.chords.isEmpty {
                Text(entry.menu.map { "\($0.menuTitle) menu" } ?? "Menu only")
                    .font(Typography.readoutSmall)
                    .foregroundStyle(palette.dimmed.color())
            } else {
                // More than one chord is normal — the normal nudge answers to
                // both `Z` and `←`. The menu can only draw the first; this is
                // the only place the alternates are visible at all.
                HStack(spacing: 4) {
                    ForEach(entry.chords, id: \.self) { chord in
                        KeyCapView(chord: chord)
                    }
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
