import SwiftUI

/// The size of everything on the drawn keyboard, from the size of the box it
/// has to fit in.
///
/// One `unit` — the width of a letter key — governs the lot, so the keyboard
/// **scales with the window** instead of clipping or scrolling. The gap is
/// folded into each cap's width rather than added between them: a row then
/// measures `15 × unit − gap` whatever number of caps it holds, which is what
/// makes the six rows line up under one another when they have 11, 13, 14 and
/// 15 keys in them.
struct KeyboardMetrics {
    static let gap: Double = 5
    /// Height of a key as a fraction of its width. Slightly wider than tall,
    /// which is what a Mac key is.
    private static let aspect: Double = 0.92

    let unit: Double

    init(size: CGSize) {
        let rows = Double(KeyboardLayout.rows.count)
        let byWidth = (size.width + Self.gap) / KeyboardLayout.unitsPerRow
        let byHeight = (size.height - (rows - 1) * Self.gap) / (rows * Self.aspect)
        unit = max(8, min(byWidth, byHeight, 96))
    }

    var keyHeight: Double { unit * Self.aspect }
    var boardWidth: Double { KeyboardLayout.unitsPerRow * unit - Self.gap }
    var boardHeight: Double {
        let rows = Double(KeyboardLayout.rows.count)
        return rows * keyHeight + (rows - 1) * Self.gap
    }

    func width(_ cap: KeyCapSpec) -> Double { max(4, unit * cap.width - Self.gap) }

    var glyphSize: Double { min(max(unit * 0.30, 7), 16) }
    var labelSize: Double { min(max(unit * 0.175, 5.5), 10) }
    /// Below this the label is unreadable, so it is dropped rather than drawn
    /// as a smear. The colour still says which category the key belongs to.
    var showsLabels: Bool { labelSize >= 6.5 }
}

/// **The keyboard**, with this layer's bindings drawn on it.
///
/// The design is the one the user was shown during brainstorming and picked
/// this project's keymap from (`.superpowers/brainstorm/…/keyboard.html`): a
/// full keyboard, every bound key tinted by category with its action named
/// under the glyph, every unbound key visibly dimmed so the bound ones read as
/// a shape. What is added is the layer — that mockup had one static keymap, and
/// this one has four.
struct ShortcutKeyboardView: View {
    let layer: KeyModifiers
    let query: String
    let appearance: Appearance
    @Environment(\.palette) private var palette

    private var bindings: [KeyToken: ActionEntry] { ShortcutLayers.bindings(on: layer) }

    /// Room kept for the legend when sizing the board, so the two are laid out
    /// against one reading of the available space rather than fighting for it.
    private static let legendHeight: Double = 46

    var body: some View {
        // One `GeometryReader` over both, not one each: the board's height falls
        // out of `unit`, so the legend can sit directly under it instead of
        // being pushed to the bottom of the pane with a hand's width of nothing
        // in between — which is what two nested readers gave, and it looked
        // like a layout bug rather than a design.
        GeometryReader { geometry in
            let metrics = KeyboardMetrics(
                size: CGSize(
                    width: geometry.size.width,
                    height: max(0, geometry.size.height - Self.legendHeight - 12)))
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: KeyboardMetrics.gap) {
                    ForEach(Array(KeyboardLayout.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: KeyboardMetrics.gap) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cap in
                                cell(cap, metrics)
                            }
                        }
                    }
                }
                .frame(width: metrics.boardWidth, height: metrics.boardHeight)
                .frame(maxWidth: .infinity, alignment: .center)
                legend
                Spacer(minLength: 0)
            }
        }
    }

    private func cell(_ cap: KeyCapSpec, _ metrics: KeyboardMetrics) -> some View {
        let entry = cap.token.flatMap { bindings[$0] }
        return ShortcutKeyCapView(
            cap: cap,
            entry: entry,
            isFiltered: entry.map { !ShortcutSearch.matches($0, query: query) } ?? false,
            isLayerModifier: cap.modifier.map { layer.contains($0) } ?? false,
            metrics: metrics,
            appearance: appearance)
    }

    /// Which colour means what — the mockup had one, and a nine-hue keyboard
    /// needs it more than a three-hue one did. Only the categories with a key
    /// on *this* layer are listed, so it describes what is on screen rather
    /// than what exists.
    private var legend: some View {
        let categories = ActionCategory.allCases.filter { category in
            bindings.values.contains { $0.category == category }
        }
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 108), spacing: 10, alignment: .leading)],
            alignment: .leading, spacing: 4
        ) {
            ForEach(categories) { category in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(category.tint(appearance).color())
                        .frame(width: 9, height: 9)
                    Text(category.title)
                        .font(Typography.readoutSmall)
                        .foregroundStyle(palette.dimmed.color())
                        .lineLimit(1)
                }
            }
        }
    }
}

/// One key cap, in one of three states: it carries an action on this layer, it
/// *is* one of the modifiers making this layer, or it does nothing here.
///
/// The three are told apart by colour **and** by weight, never by colour alone:
/// a bound key is tinted and labelled, a live modifier is outlined in the
/// accent, and everything else is dimmed to the mockup's `.42`-ish opacity.
struct ShortcutKeyCapView: View {
    let cap: KeyCapSpec
    let entry: ActionEntry?
    /// A bound key the filter field has excluded. Dimmed, but not as far as an
    /// unbound one — it still does something, it just is not what was typed.
    let isFiltered: Bool
    /// This cap is a modifier the layer on screen is made of: the key you are
    /// holding, or the one you would hold.
    let isLayerModifier: Bool
    let metrics: KeyboardMetrics
    let appearance: Appearance
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 1) {
            Text(cap.glyph)
                .font(.system(size: metrics.glyphSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let entry, metrics.showsLabels {
                Text(entry.title)
                    .font(.system(size: metrics.labelSize))
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 2)
        .foregroundStyle(ink)
        .frame(width: metrics.width(cap), height: metrics.keyHeight)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(KeyCapStyle.surface(appearance).color())
                if let wash {
                    RoundedRectangle(cornerRadius: 5).fill(wash)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(edge, lineWidth: 1))
        .opacity(opacity)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
    }

    private var tint: RGB? { entry.map { $0.category.tint(appearance) } }

    private var ink: Color {
        if let tint { return tint.color() }
        if isLayerModifier { return palette.accent.color() }
        if cap.modifier != nil { return palette.text.color() }
        return KeyCapStyle.unboundGlyph(appearance).color()
    }

    private var wash: Color? {
        if let tint { return tint.color(opacity: KeyCapStyle.fillOpacity(appearance)) }
        if isLayerModifier { return palette.accent.color(opacity: 0.18) }
        return nil
    }

    private var edge: Color {
        if let tint { return tint.color(opacity: 0.55) }
        if isLayerModifier { return palette.accent.color(opacity: 0.7) }
        return palette.rule.color()
    }

    private var opacity: Double {
        if entry != nil { return isFiltered ? KeyCapStyle.filteredOpacity : 1 }
        if isLayerModifier { return 1 }
        // A modifier that is not part of this layer is the key you would press
        // to get to another one, so it stays legible rather than going as far
        // down as a key that does nothing anywhere.
        if cap.modifier != nil { return 0.7 }
        return KeyCapStyle.unboundOpacity
    }

    /// What the tooltip and VoiceOver say. The chord is spelled out here even
    /// though the picture implies it: a key drawn on the `⌥⇧` layer says `A`,
    /// and "⌥⇧A" is what anyone would want to be told.
    private var helpText: String {
        guard let entry, let token = cap.token else {
            return isLayerModifier ? "\(cap.glyph) — hold for this layer" : cap.glyph
        }
        let chord = entry.chords.first { $0.key == token }
        return "\(chord?.display ?? cap.glyph) — \(entry.title) (\(entry.category.title))"
    }
}
