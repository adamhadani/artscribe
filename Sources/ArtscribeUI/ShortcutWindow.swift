import SwiftUI

#if os(macOS)
import AppKit
#endif

/// **The shortcut reference, as its own window**: a keyboard with the bindings
/// drawn on it, a list beside it, and one filter over both.
///
/// It was an inspector page in Task 20 and the user asked for this instead —
/// "clear and legible but also visually intuitive". A separate window rather
/// than a panel is what that costs: the reference is a thing you keep open on a
/// second display while you learn the keymap, and a panel inside the document
/// window can only be that by taking width from the waveform, which is the one
/// thing this app is for.
///
/// Three decisions worth keeping:
///
/// * **The keyboard is the mockup the user already approved**
///   (`.superpowers/brainstorm/…/keyboard.html`) — they chose this project's
///   entire keymap off it. Category tinting, dimmed unbound keys, the action
///   named under the glyph. Not a new design.
/// * **Layers follow the modifiers you hold** (see `ShortcutLayers`), and can
///   also be pinned from the picker for anyone who cannot hold two keys at
///   once. That is an accessibility requirement, not a nicety.
/// * **Everything comes from `ActionCatalog`.** No second list. The window
///   cannot show a shortcut the app does not have, and
///   `everyActionInTheCatalogIsReachableInTheWindow` is what stops the reverse.
public struct ShortcutWindow: View {
    private let context: MenuContext
    private let theme: ThemeController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What is being held **right now**. `@State` and compared before writing,
    /// so a `.flagsChanged` for a key this app does not read cannot invalidate
    /// the whole keyboard.
    @State private var held: KeyModifiers = []
    #if os(macOS)
    /// Reads held modifiers so the keyboard can switch layers under your thumb.
    /// macOS only: it is an `NSEvent` monitor, and on iPad a hardware keyboard
    /// is optional — which is exactly why the pinned-layer picker exists, and
    /// why it was built as an accessibility requirement rather than a nicety.
    /// That picker is the whole layer story on iPad.
    @State private var modifiers = ModifierMonitor()
    #endif
    /// The list width at the instant the divider was grabbed. `nil` when it is
    /// not being dragged — a `DragGesture`'s translation is cumulative, so the
    /// starting width has to be remembered rather than accumulated, or the
    /// divider accelerates away from the pointer.
    @State private var dragOrigin: Double?

    /// Small enough to fit beside a browser on a laptop, wide enough that the
    /// keyboard is legible at the default split. Hoisted out of the `frame`
    /// modifier so `theWindowMinimumLeavesRoomForBothMinimums` can check the
    /// constants against each other.
    public static let minimumWidth: Double = 760
    public static let minimumHeight: Double = 460

    /// Wider than the drawn divider, because a 1 pt line is not a thing
    /// anyone can grab.
    private static let dividerGrab: CGFloat = 9
    private static let searchFieldWidth: CGFloat = 220

    public init(context: MenuContext, theme: ThemeController) {
        self.context = context
        self.theme = theme
    }

    private var shortcuts: ShortcutWindowController { context.shortcuts }
    private var appearance: Appearance { colorScheme == .dark ? .dark : .light }
    private var palette: Palette { Palette.of(appearance) }
    private var layer: KeyModifiers {
        ShortcutLayers.effective(held: held, pinned: shortcuts.pinnedLayer)
    }

    public var body: some View {
        @Bindable var shortcuts = shortcuts
        return VStack(spacing: 0) {
            header(query: $shortcuts.query)
            Rectangle().fill(palette.rule.color()).frame(height: Metrics.hairline)
            // One reader over the whole split. The list's width is *computed*
            // rather than expressed as a min/ideal/max frame, because the
            // divider has to be somewhere the reader put it and a flexible
            // frame cannot be dragged.
            GeometryReader { geometry in
                let listWidth = ShortcutSplit.listWidth(
                    preferred: shortcuts.listWidth, totalWidth: geometry.size.width)
                HStack(spacing: 0) {
                    ShortcutKeyboardView(
                        layer: layer, query: shortcuts.query, appearance: appearance
                    )
                    .padding(Metrics.gutter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Spec §12 and the brief: Reduce Motion turns the layer
                    // cross-fade off rather than shortening it. A keyboard that
                    // repaints eight keys at once is exactly the kind of movement
                    // the setting exists for.
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: layer)

                    divider(totalWidth: geometry.size.width)

                    ShortcutListView(
                        context: context, query: shortcuts.query, appearance: appearance
                    )
                    .frame(width: listWidth)
                    .background(palette.panel.color())
                }
            }
        }
        // **A minimum on macOS; the whole sheet on iPad.**
        //
        // A `minWidth`/`minHeight` is a floor a resizable window sits above —
        // right for a window the reader drags to whatever size suits. A sheet is
        // not resizable, so the same modifier makes it exactly its minimum and
        // no more: on a 13-inch iPad the keyboard was drawn at about a third of
        // the available width with empty space around it, and the list beside it
        // was clipped mid-entry.
        //
        // `ShortcutKeyboardView` already scales — one `unit` derived from the
        // space it is given governs every key — so filling the sheet is the
        // whole fix. Nothing about the keyboard's own layout changes.
        #if os(macOS)
        .frame(minWidth: Self.minimumWidth, minHeight: Self.minimumHeight)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(palette.background.color())
        .environment(\.palette, palette)
        .preferredColorScheme(theme.colorScheme)
        // Both are macOS window concepts. On iPad this view is a sheet: it has
        // no `NSWindow` to adopt or autosave, and no `NSEvent` monitor to read
        // held modifiers from — the pinned-layer picker is the whole layer story
        // there, which is what it was built for.
        #if os(macOS)
        .background(WindowReader(onWindow: configure))
        .onAppear {
            modifiers.start { held in
                // Compared before writing: `@State` invalidates on every set,
                // and AppKit sends `.flagsChanged` for keys nothing here reads.
                if held != self.held { self.held = held }
            }
        }
        .onDisappear {
            modifiers.stop()
            held = []
        }
        #endif
    }

    // MARK: - The divider

    /// The hairline between the panes, and the handle for moving it.
    ///
    /// It is **one point wide in layout and nine points wide to the pointer**:
    /// an overlay carries the hit area, so widening the grab target costs the
    /// panes no width and leaves no gutter in the background colour where the
    /// seam should be. The cursor changes on hover, which is the only thing that
    /// says the divider moves at all.
    ///
    /// Why it can be moved: the keyboard is a 2.7:1 object that only grows
    /// taller by growing wider, so at a tall window there is height under it
    /// that nothing in this window can fill — and how much of the width to spend
    /// buying that height back, versus on a list wide enough to read a long
    /// action and its chord on one line, is a judgement about the reader's
    /// screen, not one this file can make for them.
    private func divider(totalWidth: Double) -> some View {
        Rectangle()
            .fill(palette.rule.color())
            .frame(width: ShortcutSplit.dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: Self.dividerGrab)
                    .contentShape(Rectangle())
                    // SwiftUI's own pointer style, as the ruler and the lanes
                    // already use — not an `NSCursor.push()`/`pop()` pair, which
                    // has to be balanced by hand and is not if the pointer
                    // leaves while a drag is still running.
                    #if os(macOS)
                .pointerStyle(.columnResize)
                    #endif
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let origin = dragOrigin ?? shortcuts.listWidth
                                if dragOrigin == nil { dragOrigin = origin }
                                // Dragging left widens the list: it is the pane
                                // on the right, so its width grows as the
                                // divider's x falls.
                                shortcuts.listWidth = ShortcutSplit.listWidth(
                                    preferred: origin - value.translation.width,
                                    totalWidth: totalWidth)
                            }
                            .onEnded { _ in dragOrigin = nil }
                    )
            }
            .accessibilityElement()
            .accessibilityLabel("Divider between the keyboard and the list")
    }

    // MARK: - Chrome

    private func header(query: Binding<String>) -> some View {
        HStack(spacing: Metrics.xl) {
            Eyebrow("KEYBOARD SHORTCUTS")

            HStack(spacing: Metrics.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.dimmed.color())
                // One field over both surfaces: it narrows the list *and*
                // quiets every key on the keyboard that is not a match.
                TextField("Filter", text: query)
                    .textFieldStyle(.plain)
                    .font(Typography.readout)
                    .foregroundStyle(palette.text.color())
                if !query.wrappedValue.isEmpty {
                    Button {
                        query.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(palette.dimmed.color())
                    }
                    .buttonStyle(.plain)
                    .help("Clear the filter")
                }
            }
            .padding(.horizontal, Metrics.md)
            .padding(.vertical, Metrics.xs)
            .frame(width: Self.searchFieldWidth)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.control).fill(palette.panel.color())
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.control).stroke(
                    palette.rule.color(), lineWidth: 1))

            Spacer(minLength: Metrics.md)
            layerPicker
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.lg)
        .background(palette.background.color())
    }

    /// The layer switch, and the sentence explaining that it is optional.
    ///
    /// It **shows the effective layer and writes the pinned one**, which is the
    /// whole trick: holding `⌥` moves the picker to `⌥` and letting go moves it
    /// back, so the held gesture is legible as the same control the picker is,
    /// and a click is the way to get there without holding anything.
    private var layerPicker: some View {
        HStack(spacing: Metrics.lg) {
            Text(held.isEmpty ? "Hold ⇧ ⌥ ⌘ — or pick a layer" : "Holding")
                .font(Typography.readoutSmall)
                .foregroundStyle(held.isEmpty ? palette.dimmed.color() : palette.accent.color())
                // One line, and the first thing to give way. Without this the
                // hint wrapped to five lines at the window's minimum width and
                // took a third of the header with it — measured at 760×460,
                // where the header grew from 43 pt to 84.
                .lineLimit(1)
                .layoutPriority(-1)
            Picker("Layer", selection: layerSelection) {
                ForEach(ShortcutLayers.available, id: \.rawValue) { modifiers in
                    Text(ShortcutLayers.title(modifiers)).tag(modifiers)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show a modifier layer without holding the keys")
        }
    }

    private var layerSelection: Binding<KeyModifiers> {
        Binding(get: { layer }, set: { shortcuts.pin($0) })
    }

    /// Size and position remembered, by name.
    ///
    /// `setFrameAutosaveName` rather than trusting scene restoration: an
    /// unbundled `swift run` binary has no state-restoration file to write into,
    /// so the frame would be forgotten in exactly the configuration every agent
    /// and every developer on this project actually runs.
    /// Hands the window over, and with it the whole of the focus model.
    ///
    /// **The filter must not open holding the keyboard**, and must be escapable
    /// once it does. SwiftUI gives the `TextField` first responder as soon as
    /// the scene appears — measured in a running app, where the window's
    /// `firstResponder` is `_SystemTextFieldFieldEditor` (an `NSTextView`)
    /// before anything has been clicked, on *every* open and not merely the
    /// first. `ModifierMonitor` reads exactly that to decide a modifier press is
    /// text being typed rather than a layer request, so the header's promise —
    /// "Hold ⇧ ⌥ ⌘" — was dead from the instant the window appeared.
    ///
    /// Weakening that rule is the worse trade: it is what stops the whole
    /// keyboard strobing while you type a capital into the filter. So the focus
    /// is made a two-way state instead, in `ShortcutFocusMonitor`, which the
    /// controller owns because this view's `onAppear` runs once and the window
    /// is reopened all day.
    #if os(macOS)
    private func configure(_ window: NSWindow?) {
        shortcuts.adopt(window: window)
        guard let window else { return }
        _ = window.setFrameAutosaveName(ShortcutWindowController.windowID)
        window.isRestorable = true
    }
    #endif
}

#if os(macOS)

extension View {
    /// Hands the scene's `openWindow` to the controller.
    ///
    /// This is the whole of the plumbing behind `⌘/`. `openWindow` is an
    /// `EnvironmentValues` member and so only reachable from a `View`, while
    /// the thing that needs it — `ActionInvoker`'s table — is deliberately not
    /// a view: it is the single implementation of every action, reached
    /// identically from a menu item, a key press, and later a MIDI note.
    ///
    /// Applied to **both** scenes that can be showing when `⌘/` is pressed, so
    /// the key works whichever of them is key.
    public func openShortcutWindow(_ shortcuts: ShortcutWindowController) -> some View {
        modifier(ShortcutWindowOpener(shortcuts: shortcuts))
    }
}

private struct ShortcutWindowOpener: ViewModifier {
    let shortcuts: ShortcutWindowController
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            shortcuts.present = { openWindow(id: ShortcutWindowController.windowID) }
        }
    }
}

#endif  // os(macOS) — the scene opener
